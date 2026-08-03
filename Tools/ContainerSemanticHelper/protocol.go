// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"encoding/binary"
	"errors"
	"io"
	"math"
)

const (
	protocolVersion        uint16 = 2
	headerBytes                   = 28
	maximumFrameBytes             = 16 * 1024 * 1024
	maximumByteFieldBytes         = 2 * 1024 * 1024
	maximumTemplateBytes          = 2 * 1024 * 1024
	maximumRegexpBytes            = 64 * 1024
	maximumCandidateBytes         = 64 * 1024
	maximumCandidateCount         = 4096
	maximumCollectionCount        = 4096
	maximumMapCount               = 1024
	maximumMapKeyBytes            = 4 * 1024
	maximumOutputBytes            = 2 * 1024 * 1024
	maximumErrorBytes             = 64 * 1024
)

var protocolMagic = [4]byte{'D', 'C', 'S', 'H'}

type frameKind uint8

const (
	requestFrame  frameKind = 1
	responseFrame frameKind = 2
)

type opcode uint8

const (
	opHello          opcode = 1
	opRegexpBatch    opcode = 2
	opTemplateRender opcode = 3
	opURLParse       opcode = 4
	opCancel         opcode = 5
	opFluentdAddress opcode = 6
	opGELFAddress    opcode = 7
	opSyslogAddress  opcode = 8
	opGCPStart       opcode = 9
	opGCPLog         opcode = 10
	opGCPFlush       opcode = 11
	opGCPClose       opcode = 12
)

type responseStatus uint16

const (
	statusOK               responseStatus = 0
	statusInvalidRequest   responseStatus = 1
	statusParseError       responseStatus = 2
	statusExecuteError     responseStatus = 3
	statusDeadlineExceeded responseStatus = 4
	statusCancelled        responseStatus = 5
	statusInternalFailure  responseStatus = 6
	statusOutputLimit      responseStatus = 7
)

type frameHeader struct {
	kind               frameKind
	opcode             opcode
	requestID          uint64
	timeoutNanoseconds uint64
	status             responseStatus
	flags              uint16
}

func readFrame(reader io.Reader) (frameHeader, []byte, error) {
	var lengthBytes [4]byte
	if _, err := io.ReadFull(reader, lengthBytes[:]); err != nil {
		return frameHeader{}, nil, err
	}
	frameLength := binary.BigEndian.Uint32(lengthBytes[:])
	if frameLength < headerBytes || frameLength > maximumFrameBytes {
		return frameHeader{}, nil, errors.New("invalid protocol frame length")
	}
	frame := make([]byte, frameLength)
	if _, err := io.ReadFull(reader, frame); err != nil {
		return frameHeader{}, nil, err
	}
	header, err := decodeHeader(frame[:headerBytes])
	if err != nil {
		return frameHeader{}, nil, err
	}
	return header, frame[headerBytes:], nil
}

func decodeHeader(source []byte) (frameHeader, error) {
	if len(source) != headerBytes || string(source[:4]) != string(protocolMagic[:]) {
		return frameHeader{}, errors.New("invalid protocol header")
	}
	if binary.BigEndian.Uint16(source[4:6]) != protocolVersion {
		return frameHeader{}, errors.New("unsupported protocol version")
	}
	kind := frameKind(source[6])
	if kind != requestFrame && kind != responseFrame {
		return frameHeader{}, errors.New("invalid protocol frame kind")
	}
	op := opcode(source[7])
	if op < opHello || op > opGCPClose {
		return frameHeader{}, errors.New("invalid protocol opcode")
	}
	return frameHeader{
		kind:               kind,
		opcode:             op,
		requestID:          binary.BigEndian.Uint64(source[8:16]),
		timeoutNanoseconds: binary.BigEndian.Uint64(source[16:24]),
		status:             responseStatus(binary.BigEndian.Uint16(source[24:26])),
		flags:              binary.BigEndian.Uint16(source[26:28]),
	}, nil
}

func encodeFrame(header frameHeader, payload []byte) ([]byte, error) {
	frameLength := headerBytes + len(payload)
	if frameLength > maximumFrameBytes {
		return nil, errors.New("protocol response exceeds frame limit")
	}
	frame := make([]byte, 4+frameLength)
	binary.BigEndian.PutUint32(frame[:4], uint32(frameLength))
	copy(frame[4:8], protocolMagic[:])
	binary.BigEndian.PutUint16(frame[8:10], protocolVersion)
	frame[10] = byte(header.kind)
	frame[11] = byte(header.opcode)
	binary.BigEndian.PutUint64(frame[12:20], header.requestID)
	binary.BigEndian.PutUint64(frame[20:28], header.timeoutNanoseconds)
	binary.BigEndian.PutUint16(frame[28:30], uint16(header.status))
	binary.BigEndian.PutUint16(frame[30:32], header.flags)
	copy(frame[32:], payload)
	return frame, nil
}

type protocolReader struct {
	bytes []byte
	index int
}

func newProtocolReader(source []byte) *protocolReader {
	return &protocolReader{bytes: source}
}

func (r *protocolReader) atEnd() bool {
	return r.index == len(r.bytes)
}

func (r *protocolReader) read(count int) ([]byte, error) {
	if count < 0 || r.index > len(r.bytes)-count {
		return nil, errors.New("truncated protocol payload")
	}
	result := r.bytes[r.index : r.index+count]
	r.index += count
	return result, nil
}

func (r *protocolReader) uint8() (uint8, error) {
	value, err := r.read(1)
	if err != nil {
		return 0, err
	}
	return value[0], nil
}

func (r *protocolReader) uint32() (uint32, error) {
	value, err := r.read(4)
	if err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(value), nil
}

func (r *protocolReader) uint64() (uint64, error) {
	value, err := r.read(8)
	if err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint64(value), nil
}

func (r *protocolReader) int32() (int32, error) {
	value, err := r.uint32()
	return int32(value), err
}

func (r *protocolReader) int64() (int64, error) {
	value, err := r.uint64()
	return int64(value), err
}

func (r *protocolReader) byteField(maximum int) ([]byte, error) {
	count, err := r.uint32()
	if err != nil {
		return nil, err
	}
	if count > uint32(maximum) {
		return nil, errors.New("protocol byte field exceeds limit")
	}
	return r.read(int(count))
}

func (r *protocolReader) byteList(maximumCount, maximumValue int) ([][]byte, error) {
	count, err := r.uint32()
	if err != nil {
		return nil, err
	}
	if count > uint32(maximumCount) {
		return nil, errors.New("protocol list exceeds limit")
	}
	result := make([][]byte, 0, count)
	for range count {
		value, err := r.byteField(maximumValue)
		if err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, nil
}

func (r *protocolReader) stringMap() (map[string]string, error) {
	count, err := r.uint32()
	if err != nil {
		return nil, err
	}
	if count > maximumMapCount {
		return nil, errors.New("protocol map exceeds limit")
	}
	result := make(map[string]string, count)
	for range count {
		keyBytes, err := r.byteField(maximumMapKeyBytes)
		if err != nil {
			return nil, err
		}
		value, err := r.byteField(maximumByteFieldBytes)
		if err != nil {
			return nil, err
		}
		key := string(keyBytes)
		if _, exists := result[key]; exists {
			return nil, errors.New("duplicate protocol map key")
		}
		result[key] = string(value)
	}
	return result, nil
}

type protocolWriter struct {
	bytes []byte
}

func (w *protocolWriter) uint8(value uint8) {
	w.bytes = append(w.bytes, value)
}

func (w *protocolWriter) uint16(value uint16) {
	var encoded [2]byte
	binary.BigEndian.PutUint16(encoded[:], value)
	w.bytes = append(w.bytes, encoded[:]...)
}

func (w *protocolWriter) uint32(value uint32) {
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], value)
	w.bytes = append(w.bytes, encoded[:]...)
}

func (w *protocolWriter) uint64(value uint64) {
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], value)
	w.bytes = append(w.bytes, encoded[:]...)
}

func (w *protocolWriter) int32(value int32) {
	w.uint32(uint32(value))
}

func (w *protocolWriter) int64(value int64) {
	w.uint64(uint64(value))
}

func (w *protocolWriter) byteField(value []byte) error {
	if len(value) > maximumByteFieldBytes || len(value) > math.MaxUint32 {
		return errors.New("protocol byte field exceeds limit")
	}
	w.uint32(uint32(len(value)))
	w.bytes = append(w.bytes, value...)
	return nil
}
