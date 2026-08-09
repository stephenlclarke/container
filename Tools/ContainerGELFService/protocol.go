// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	wireSchemaVersion        = uint32(1)
	maximumWireFrameBytes    = 6 * 1024 * 1024
	maximumGELFTCPFrameBytes = 4 * 1024 * 1024
	maximumEndpointHostBytes = 1024
)

var uuidPattern = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`,
)

type wireOperation string

const (
	operationActiveSandboxGeneration wireOperation = "activeSandboxGeneration"
	operationOpen                    wireOperation = "open"
	operationWrite                   wireOperation = "write"
	operationClose                   wireOperation = "close"
)

type wireFailure string

const (
	failureInvalidRequest   wireFailure = "invalidRequest"
	failureConnectionFailed wireFailure = "connectionFailed"
	failureWriteFailed      wireFailure = "writeFailed"
	failureTimedOut         wireFailure = "timedOut"
	failureUnavailable      wireFailure = "unavailable"
	failureInternal         wireFailure = "internalFailure"
)

type endpoint struct {
	Host string `json:"host"`
	Port string `json:"port"`
}

func (endpoint endpoint) validate() error {
	if len(endpoint.Host) > maximumEndpointHostBytes {
		return errors.New("endpoint host is too long")
	}
	if endpoint.Port == "" || strings.Trim(endpoint.Port, "0123456789") != "" {
		return errors.New("endpoint port is not a decimal number")
	}
	port, err := strconv.ParseUint(endpoint.Port, 10, 16)
	if err != nil || port > 65535 {
		return errors.New("endpoint port is out of range")
	}
	return nil
}

func (endpoint endpoint) address() (string, error) {
	if err := endpoint.validate(); err != nil {
		return "", err
	}
	host, err := normalizedConnectHost(endpoint.Host)
	if err != nil {
		return "", err
	}
	return net.JoinHostPort(host, endpoint.Port), nil
}

type wireRequest struct {
	SchemaVersion      uint32        `json:"schemaVersion"`
	OperationID        string        `json:"operationID"`
	Operation          wireOperation `json:"operation"`
	Endpoint           *endpoint     `json:"endpoint,omitempty"`
	TimeoutNanoseconds *uint64       `json:"timeoutNanoseconds,omitempty"`
	Frame              []byte        `json:"frame,omitempty"`
}

func (request wireRequest) validate() error {
	if request.SchemaVersion != wireSchemaVersion || !uuidPattern.MatchString(request.OperationID) {
		return errors.New("invalid request envelope")
	}
	if request.OperationID != strings.ToLower(request.OperationID) {
		return errors.New("request operation ID is not lowercase")
	}
	switch request.Operation {
	case operationActiveSandboxGeneration, operationClose:
		if request.Endpoint != nil || request.TimeoutNanoseconds != nil || len(request.Frame) != 0 {
			return errors.New("operation must not include a payload")
		}
	case operationOpen:
		if request.Endpoint == nil || request.TimeoutNanoseconds == nil || len(request.Frame) != 0 {
			return errors.New("open payload is incomplete")
		}
		if _, err := durationFromNanoseconds(*request.TimeoutNanoseconds); err != nil {
			return err
		}
		return request.Endpoint.validate()
	case operationWrite:
		if request.Endpoint != nil || request.TimeoutNanoseconds == nil || len(request.Frame) == 0 ||
			len(request.Frame) > maximumGELFTCPFrameBytes {
			return errors.New("write payload is invalid")
		}
		_, err := durationFromNanoseconds(*request.TimeoutNanoseconds)
		return err
	default:
		return errors.New("unsupported operation")
	}
	return nil
}

type wireResponse struct {
	SchemaVersion     uint32       `json:"schemaVersion"`
	OperationID       string       `json:"operationID"`
	SandboxGeneration *uint64      `json:"sandboxGeneration,omitempty"`
	WrittenBytes      *int         `json:"writtenBytes,omitempty"`
	Failure           *wireFailure `json:"failure,omitempty"`
}

func acknowledgement(operationID string) wireResponse {
	return wireResponse{SchemaVersion: wireSchemaVersion, OperationID: operationID}
}

func failed(operationID string, failure wireFailure) wireResponse {
	return wireResponse{
		SchemaVersion: wireSchemaVersion,
		OperationID:   operationID,
		Failure:       &failure,
	}
}

func generation(operationID string, value uint64) wireResponse {
	return wireResponse{
		SchemaVersion:     wireSchemaVersion,
		OperationID:       operationID,
		SandboxGeneration: &value,
	}
}

func writeReceipt(operationID string, count int) wireResponse {
	return wireResponse{
		SchemaVersion: wireSchemaVersion,
		OperationID:   operationID,
		WrittenBytes:  &count,
	}
}

func decodeWireRequest(payload []byte) (wireRequest, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var request wireRequest
	if err := decoder.Decode(&request); err != nil {
		return wireRequest{}, err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return wireRequest{}, errors.New("wire request has trailing data")
	}
	if err := request.validate(); err != nil {
		return wireRequest{}, err
	}
	return request, nil
}

func operationIDFromInvalidPayload(payload []byte) string {
	var envelope struct {
		OperationID string `json:"operationID"`
	}
	if json.Unmarshal(payload, &envelope) == nil && uuidPattern.MatchString(envelope.OperationID) {
		return envelope.OperationID
	}
	return "00000000-0000-0000-0000-000000000000"
}

func readFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > maximumWireFrameBytes {
		return nil, fmt.Errorf("invalid wire frame length %d", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(writer io.Writer, value wireResponse) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(payload) == 0 || len(payload) > maximumWireFrameBytes {
		return errors.New("invalid encoded wire response")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	_, err = writer.Write(payload)
	return err
}

func durationFromNanoseconds(nanoseconds uint64) (time.Duration, error) {
	if nanoseconds == 0 || nanoseconds > uint64(1<<63-1) {
		return 0, errors.New("invalid timeout")
	}
	return time.Duration(nanoseconds), nil
}

func normalizedConnectHost(host string) (string, error) {
	if host == "" {
		return "localhost", nil
	}
	if !strings.EqualFold(host, "host.docker.internal") {
		return host, nil
	}
	routes, err := os.ReadFile("/proc/net/route")
	if err != nil {
		return "", fmt.Errorf("read default route: %w", err)
	}
	gateway, err := defaultIPv4Gateway(string(routes))
	if err != nil {
		return "", err
	}
	return gateway, nil
}

func defaultIPv4Gateway(routes string) (string, error) {
	for lineNumber, line := range strings.Split(routes, "\n") {
		fields := strings.Fields(line)
		if lineNumber == 0 || len(fields) < 4 || fields[1] != "00000000" {
			continue
		}
		flags, err := strconv.ParseUint(fields[3], 16, 32)
		if err != nil || flags&0x2 == 0 {
			continue
		}
		value, err := strconv.ParseUint(fields[2], 16, 32)
		if err != nil {
			continue
		}
		return net.IPv4(byte(value), byte(value>>8), byte(value>>16), byte(value>>24)).String(), nil
	}
	return "", errors.New("no IPv4 default gateway is available")
}
