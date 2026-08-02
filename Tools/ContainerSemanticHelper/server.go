// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"runtime"
	"sync"
	"time"
)

const (
	maximumConcurrentRequests = 16
	maximumRequestTimeout     = 30 * time.Second
)

type semanticServer struct {
	connection  net.Conn
	engine      *semanticEngine
	writeMu     sync.Mutex
	activeMu    sync.Mutex
	active      map[uint64]context.CancelFunc
	concurrency chan struct{}
	waitGroup   sync.WaitGroup
}

func newSemanticServer(connection net.Conn) *semanticServer {
	return &semanticServer{
		connection:  connection,
		engine:      newSemanticEngine(),
		active:      make(map[uint64]context.CancelFunc),
		concurrency: make(chan struct{}, maximumConcurrentRequests),
	}
}

func (s *semanticServer) serve() error {
	defer func() {
		s.cancelAll()
		s.waitGroup.Wait()
	}()
	for {
		header, payload, err := readFrame(s.connection)
		if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("read semantic-helper frame: %w", err)
		}
		if header.kind != requestFrame || header.status != statusOK || header.flags != 0 || header.requestID == 0 {
			return errors.New("invalid semantic-helper request header")
		}
		if header.opcode == opCancel {
			if err := s.handleCancellation(header, payload); err != nil {
				return err
			}
			continue
		}
		if header.timeoutNanoseconds == 0 || header.timeoutNanoseconds > uint64(maximumRequestTimeout) {
			if err := s.writeError(
				header,
				statusInvalidRequest,
				"request timeout is outside the supported range",
			); err != nil {
				return err
			}
			continue
		}

		select {
		case s.concurrency <- struct{}{}:
		default:
			if err := s.writeError(
				header,
				statusInvalidRequest,
				"too many concurrent semantic-helper requests",
			); err != nil {
				return err
			}
			continue
		}

		ctx, cancel := context.WithTimeout(
			context.Background(),
			time.Duration(header.timeoutNanoseconds),
		)
		if !s.register(header.requestID, cancel) {
			cancel()
			<-s.concurrency
			if err := s.writeError(
				header,
				statusInvalidRequest,
				"duplicate active request identifier",
			); err != nil {
				return err
			}
			continue
		}

		s.waitGroup.Add(1)
		go s.handleRequest(ctx, cancel, header, payload)
	}
}

func (s *semanticServer) handleRequest(
	ctx context.Context,
	cancel context.CancelFunc,
	header frameHeader,
	payload []byte,
) {
	defer s.waitGroup.Done()
	defer func() { <-s.concurrency }()
	defer cancel()
	defer s.unregister(header.requestID)

	var response []byte
	var responseErr error
	func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				responseErr = &semanticError{
					status:  statusInternalFailure,
					message: fmt.Sprintf("semantic operation panic: %v", recovered),
				}
			}
		}()
		response, responseErr = s.dispatch(ctx, header.opcode, payload)
	}()

	if responseErr != nil {
		semantic := &semanticError{
			status:  statusInternalFailure,
			message: responseErr.Error(),
		}
		if errors.As(responseErr, &semantic) {
			_ = s.writeError(header, semantic.status, semantic.message)
			return
		}
		_ = s.writeError(header, statusInternalFailure, responseErr.Error())
		return
	}
	_ = s.writeResponse(header, statusOK, response)
}

func (s *semanticServer) dispatch(
	ctx context.Context,
	op opcode,
	payload []byte,
) ([]byte, error) {
	reader := newProtocolReader(payload)
	writer := &protocolWriter{}
	switch op {
	case opHello:
		if !reader.atEnd() {
			return nil, invalidPayload()
		}
		for _, value := range []string{
			helperVersion,
			runtime.Version(),
			mobyCommit,
			helperSourceDigest,
			oracleFixtureDigest,
		} {
			if err := writer.byteField([]byte(value)); err != nil {
				return nil, err
			}
		}
	case opRegexpBatch:
		pattern, err := reader.byteField(maximumRegexpBytes)
		if err != nil {
			return nil, invalidPayloadWithError(err)
		}
		candidates, err := reader.byteList(
			maximumCandidateCount,
			maximumCandidateBytes,
		)
		if err != nil || !reader.atEnd() {
			return nil, invalidPayloadWithError(err)
		}
		matches, err := s.engine.matchRegexpBatch(ctx, pattern, candidates)
		if err != nil {
			return nil, err
		}
		writer.uint32(uint32(len(matches)))
		for _, match := range matches {
			if match {
				writer.uint8(1)
			} else {
				writer.uint8(0)
			}
		}
	case opTemplateRender:
		format, info, err := decodeTemplateRequest(reader)
		if err != nil || !reader.atEnd() {
			return nil, invalidPayloadWithError(err)
		}
		output, err := s.engine.renderLogTemplate(ctx, format, info)
		if err != nil {
			return nil, err
		}
		if err := writer.byteField(output); err != nil {
			return nil, err
		}
	case opURLParse:
		source, err := reader.byteField(maximumByteFieldBytes)
		if err != nil || !reader.atEnd() {
			return nil, invalidPayloadWithError(err)
		}
		parsed, err := parseRawURL(source)
		if err != nil {
			return nil, err
		}
		username, password := "", ""
		passwordIsSet := false
		if parsed.User != nil {
			username = parsed.User.Username()
			password, passwordIsSet = parsed.User.Password()
		}
		for _, value := range []string{
			parsed.Scheme,
			parsed.Opaque,
			username,
			password,
			parsed.Host,
			parsed.Path,
			parsed.RawPath,
			parsed.RawQuery,
			parsed.Fragment,
			parsed.RawFragment,
			parsed.Hostname(),
			parsed.Port(),
		} {
			if err := writer.byteField([]byte(value)); err != nil {
				return nil, err
			}
		}
		writer.uint8(boolByte(passwordIsSet))
		writer.uint8(boolByte(parsed.ForceQuery))
	case opFluentdAddress:
		source, err := decodeSingleByteField(reader)
		if err != nil {
			return nil, err
		}
		address, err := parseFluentdAddress(string(source))
		if err != nil {
			return nil, parseSemanticError(err)
		}
		if err := writer.byteField([]byte(address.protocol)); err != nil {
			return nil, err
		}
		if err := writer.byteField([]byte(address.host)); err != nil {
			return nil, err
		}
		writer.uint16(address.port)
		if err := writer.byteField([]byte(address.path)); err != nil {
			return nil, err
		}
	case opGELFAddress:
		source, err := decodeSingleByteField(reader)
		if err != nil {
			return nil, err
		}
		address, err := parseGELFAddress(string(source))
		if err != nil {
			return nil, parseSemanticError(err)
		}
		if err := writer.byteField([]byte(address.scheme)); err != nil {
			return nil, err
		}
		if err := writer.byteField([]byte(address.host)); err != nil {
			return nil, err
		}
		host, port, err := resolveNetworkEndpoint(
			ctx,
			address.scheme,
			address.host,
		)
		if err != nil {
			return nil, parseSemanticError(err)
		}
		if err := writer.byteField([]byte(host)); err != nil {
			return nil, err
		}
		writer.uint16(port)
	case opSyslogAddress:
		source, err := decodeSingleByteField(reader)
		if err != nil {
			return nil, err
		}
		address, err := parseSyslogAddress(string(source))
		if err != nil {
			return nil, parseSemanticError(err)
		}
		if err := writer.byteField([]byte(address.protocol)); err != nil {
			return nil, err
		}
		if err := writer.byteField([]byte(address.address)); err != nil {
			return nil, err
		}
		host := ""
		port := uint16(0)
		if address.protocol == "udp" || address.protocol == "tcp" || address.protocol == "tcp+tls" {
			network := address.protocol
			if network == "tcp+tls" {
				network = "tcp"
			}
			host, port, err = resolveNetworkEndpoint(
				ctx,
				network,
				address.address,
			)
			if err != nil {
				return nil, parseSemanticError(err)
			}
		}
		if err := writer.byteField([]byte(host)); err != nil {
			return nil, err
		}
		writer.uint16(port)
	default:
		return nil, invalidPayload()
	}
	return writer.bytes, nil
}

func decodeTemplateRequest(reader *protocolReader) ([]byte, dockerLogInfo, error) {
	format, err := reader.byteField(maximumTemplateBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	configuration, err := reader.stringMap()
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	containerID, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	containerName, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	entrypoint, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	argumentBytes, err := reader.byteList(maximumCollectionCount, maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	imageID, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	imageName, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	createdSeconds, err := reader.int64()
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	createdNanoseconds, err := reader.int32()
	if err != nil || createdNanoseconds < 0 || createdNanoseconds > 999_999_999 {
		return nil, dockerLogInfo{}, errors.New("invalid container creation nanoseconds")
	}
	environmentBytes, err := reader.byteList(maximumCollectionCount, maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	labels, err := reader.stringMap()
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	logPath, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	daemonName, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	hostname, err := reader.byteField(maximumByteFieldBytes)
	if err != nil {
		return nil, dockerLogInfo{}, err
	}
	return format, dockerLogInfo{
		Config:              configuration,
		ContainerID:         string(containerID),
		ContainerName:       string(containerName),
		ContainerEntrypoint: string(entrypoint),
		ContainerArgs:       byteStrings(argumentBytes),
		ContainerImageID:    string(imageID),
		ContainerImageName:  string(imageName),
		ContainerCreated:    time.Unix(createdSeconds, int64(createdNanoseconds)).UTC(),
		ContainerEnv:        byteStrings(environmentBytes),
		ContainerLabels:     labels,
		LogPath:             string(logPath),
		DaemonName:          string(daemonName),
		hostname:            string(hostname),
	}, nil
}

func decodeSingleByteField(reader *protocolReader) ([]byte, error) {
	value, err := reader.byteField(maximumByteFieldBytes)
	if err != nil || !reader.atEnd() {
		return nil, invalidPayloadWithError(err)
	}
	return value, nil
}

func byteStrings(values [][]byte) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		result = append(result, string(value))
	}
	return result
}

func boolByte(value bool) uint8 {
	if value {
		return 1
	}
	return 0
}

func parseSemanticError(err error) error {
	return &semanticError{status: statusParseError, message: err.Error()}
}

func invalidPayload() error {
	return &semanticError{
		status:  statusInvalidRequest,
		message: "invalid protocol payload",
	}
}

func invalidPayloadWithError(err error) error {
	if err == nil {
		return invalidPayload()
	}
	return &semanticError{
		status:  statusInvalidRequest,
		message: err.Error(),
	}
}

func (s *semanticServer) handleCancellation(header frameHeader, payload []byte) error {
	reader := newProtocolReader(payload)
	target, err := reader.uint64()
	if err != nil || !reader.atEnd() {
		return s.writeError(header, statusInvalidRequest, "invalid cancellation payload")
	}
	s.activeMu.Lock()
	cancel := s.active[target]
	s.activeMu.Unlock()
	if cancel != nil {
		cancel()
	}
	return s.writeResponse(header, statusOK, nil)
}

func (s *semanticServer) register(requestID uint64, cancel context.CancelFunc) bool {
	s.activeMu.Lock()
	defer s.activeMu.Unlock()
	if _, exists := s.active[requestID]; exists {
		return false
	}
	s.active[requestID] = cancel
	return true
}

func (s *semanticServer) unregister(requestID uint64) {
	s.activeMu.Lock()
	delete(s.active, requestID)
	s.activeMu.Unlock()
}

func (s *semanticServer) cancelAll() {
	s.activeMu.Lock()
	cancellations := make([]context.CancelFunc, 0, len(s.active))
	for _, cancel := range s.active {
		cancellations = append(cancellations, cancel)
	}
	s.activeMu.Unlock()
	for _, cancel := range cancellations {
		cancel()
	}
}

func (s *semanticServer) writeError(
	request frameHeader,
	status responseStatus,
	message string,
) error {
	if len(message) > maximumErrorBytes {
		status = statusInternalFailure
		message = "semantic-helper error exceeds protocol limit"
	}
	writer := &protocolWriter{}
	if err := writer.byteField([]byte(message)); err != nil {
		return err
	}
	return s.writeResponse(request, status, writer.bytes)
}

func (s *semanticServer) writeResponse(
	request frameHeader,
	status responseStatus,
	payload []byte,
) error {
	frame, err := encodeFrame(frameHeader{
		kind:      responseFrame,
		opcode:    request.opcode,
		requestID: request.requestID,
		status:    status,
	}, payload)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	for len(frame) > 0 {
		written, err := s.connection.Write(frame)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrUnexpectedEOF
		}
		frame = frame[written:]
	}
	return nil
}
