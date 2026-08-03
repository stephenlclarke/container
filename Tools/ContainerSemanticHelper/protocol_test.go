// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"testing"
	"time"
)

func TestFrameRoundTrip(t *testing.T) {
	expected := frameHeader{
		kind: requestFrame, opcode: opRegexpBatch, requestID: 42,
		timeoutNanoseconds: uint64(time.Second), status: statusOK,
	}
	frame, err := encodeFrame(expected, []byte("payload"))
	if err != nil {
		t.Fatal(err)
	}
	actual, payload, err := readFrame(bytes.NewReader(frame))
	if err != nil {
		t.Fatal(err)
	}
	if actual != expected || string(payload) != "payload" {
		t.Fatalf("got %+v/%q, want %+v/payload", actual, payload, expected)
	}
}

func TestFrameRejectsInvalidBoundsAndHeaders(t *testing.T) {
	for name, frame := range map[string][]byte{
		"short": {0, 0, 0, headerBytes - 1},
		"oversize": func() []byte {
			value := make([]byte, 4)
			binary.BigEndian.PutUint32(value, maximumFrameBytes+1)
			return value
		}(),
	} {
		t.Run(name, func(t *testing.T) {
			if _, _, err := readFrame(bytes.NewReader(frame)); err == nil {
				t.Fatal("invalid frame must fail")
			}
		})
	}

	valid, err := encodeFrame(frameHeader{kind: requestFrame, opcode: opHello, requestID: 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	header := bytes.Clone(valid[4:])
	header[0] = 'X'
	if _, err := decodeHeader(header); err == nil {
		t.Fatal("invalid magic must fail")
	}
	header = bytes.Clone(valid[4:])
	header[7] = 255
	if _, err := decodeHeader(header); err == nil {
		t.Fatal("invalid opcode must fail")
	}
}

func TestProtocolFieldsAndLimits(t *testing.T) {
	writer := &protocolWriter{}
	writer.uint8(7)
	writer.uint16(8)
	writer.uint32(9)
	if err := writer.byteField([]byte{0xff, 0x00}); err != nil {
		t.Fatal(err)
	}
	reader := newProtocolReader(writer.bytes)
	if value, _ := reader.uint8(); value != 7 {
		t.Fatalf("uint8 = %d", value)
	}
	if raw, err := reader.read(2); err != nil || binary.BigEndian.Uint16(raw) != 8 {
		t.Fatalf("uint16 = %v/%v", raw, err)
	}
	if value, _ := reader.uint32(); value != 9 {
		t.Fatalf("uint32 = %d", value)
	}
	if value, err := reader.byteField(2); err != nil || !bytes.Equal(value, []byte{0xff, 0x00}) {
		t.Fatalf("byte field = %v/%v", value, err)
	}
	if !reader.atEnd() {
		t.Fatal("reader did not consume payload")
	}
	if _, err := reader.read(1); err == nil {
		t.Fatal("truncated read must fail")
	}
}

func TestDispatchHandshakeAndRemoteErrors(t *testing.T) {
	server := newSemanticServer(nil)
	hello, err := server.dispatch(context.Background(), opHello, nil)
	if err != nil {
		t.Fatal(err)
	}
	reader := newProtocolReader(hello)
	for index := 0; index < 6; index++ {
		if _, err := reader.byteField(256); err != nil {
			t.Fatal(err)
		}
	}
	if !reader.atEnd() {
		t.Fatal("hello response has trailing bytes")
	}

	request := &protocolWriter{}
	if err := request.byteField([]byte("a(?=b)")); err != nil {
		t.Fatal(err)
	}
	request.uint32(0)
	_, err = server.dispatch(context.Background(), opRegexpBatch, request.bytes)
	if err == nil {
		t.Fatal("invalid regexp must fail")
	}
	if _, err := server.dispatch(context.Background(), opcode(255), nil); err == nil {
		t.Fatal("unknown operation must fail")
	}
}

func TestLRUBounds(t *testing.T) {
	cache := newLRUCache[string](2, 5)
	cache.put("one", "1", 2)
	cache.put("two", "2", 2)
	if _, found := cache.get("one"); !found {
		t.Fatal("expected cache hit")
	}
	cache.put("three", "3", 2)
	if _, found := cache.get("two"); found {
		t.Fatal("least-recently-used entry was not evicted")
	}
	if count, weight := cache.counts(); count != 2 || weight != 4 {
		t.Fatalf("counts = %d/%d", count, weight)
	}
	cache.put("one", "updated", 5)
	if count, weight := cache.counts(); count != 1 || weight != 5 {
		t.Fatalf("updated counts = %d/%d", count, weight)
	}
}
