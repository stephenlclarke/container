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
	"io"
	"strings"
	"testing"
	"time"
)

func TestEndpointValidationAndAddressingRejectUnsafeValues(t *testing.T) {
	valid := endpoint{Host: "127.0.0.1", Port: "12201"}
	if err := valid.validate(); err != nil {
		t.Fatalf("valid endpoint rejected: %v", err)
	}
	address, err := valid.address()
	if err != nil || address != "127.0.0.1:12201" {
		t.Fatalf("address = %q, %v", address, err)
	}
	defaultAddress, err := (endpoint{Port: "12201"}).address()
	if err != nil || defaultAddress != "localhost:12201" {
		t.Fatalf("default address = %q, %v", defaultAddress, err)
	}
	for _, candidate := range []endpoint{
		{Host: strings.Repeat("a", maximumEndpointHostBytes+1), Port: "12201"},
		{Host: "localhost", Port: ""},
		{Host: "localhost", Port: "not-a-port"},
		{Host: "localhost", Port: "65536"},
		{Host: "localhost", Port: "-1"},
	} {
		if err := candidate.validate(); err == nil {
			t.Fatalf("unsafe endpoint validated: %#v", candidate)
		}
	}
}

func TestWireRequestValidationCoversEveryOperationAndPayloadBoundary(t *testing.T) {
	timeout := uint64(time.Second)
	validOpen := wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        testOperationID,
		Operation:          operationOpen,
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: "12201"},
		TimeoutNanoseconds: &timeout,
	}
	validWrite := wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        "123e4567-e89b-42d3-a456-426614174001",
		Operation:          operationWrite,
		TimeoutNanoseconds: &timeout,
		Frame:              []byte("frame\x00"),
	}
	validControl := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-42d3-a456-426614174002",
		Operation:     operationClose,
	}
	validGeneration := validControl
	validGeneration.Operation = operationActiveSandboxGeneration
	for _, request := range []wireRequest{validOpen, validWrite, validControl, validGeneration} {
		if err := request.validate(); err != nil {
			t.Fatalf("valid %q request rejected: %v", request.Operation, err)
		}
	}

	zero := uint64(0)
	for _, request := range []wireRequest{
		{SchemaVersion: 2, OperationID: testOperationID, Operation: operationClose},
		{SchemaVersion: wireSchemaVersion, OperationID: strings.ToUpper(testOperationID), Operation: operationClose},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: operationClose, Frame: []byte("unexpected")},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: operationOpen, TimeoutNanoseconds: &timeout},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: operationOpen, Endpoint: validOpen.Endpoint, TimeoutNanoseconds: &zero},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: operationWrite, TimeoutNanoseconds: &timeout},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: operationWrite, TimeoutNanoseconds: &timeout, Frame: make([]byte, maximumGELFTCPFrameBytes+1)},
		{SchemaVersion: wireSchemaVersion, OperationID: testOperationID, Operation: "surprise"},
	} {
		if err := request.validate(); err == nil {
			t.Fatalf("invalid %q request validated: %#v", request.Operation, request)
		}
	}
}

func TestWireCodecRejectsTrailingAndInvalidPayloadsWithSafeOperationIdentity(t *testing.T) {
	timeout := uint64(time.Second)
	request := wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        testOperationID,
		Operation:          operationOpen,
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: "12201"},
		TimeoutNanoseconds: &timeout,
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if _, err := decodeWireRequest(append(payload, []byte(" {}")...)); err == nil {
		t.Fatal("trailing wire request data succeeded")
	}
	if actual := operationIDFromInvalidPayload([]byte(`{"operationID":"` + testOperationID + `","surprise":true}`)); actual != testOperationID {
		t.Fatalf("preserved operation ID = %q", actual)
	}
	if actual := operationIDFromInvalidPayload([]byte(`{"operationID":"not-a-uuid"}`)); actual != "00000000-0000-0000-0000-000000000000" {
		t.Fatalf("fallback operation ID = %q", actual)
	}
}

func TestWireResponseHelpersAndFrameBoundaries(t *testing.T) {
	failure := failed(testOperationID, failureInternal)
	if failure.Failure == nil || *failure.Failure != failureInternal {
		t.Fatalf("failure helper = %#v", failure)
	}
	value := generation(testOperationID, 9)
	if value.SandboxGeneration == nil || *value.SandboxGeneration != 9 {
		t.Fatalf("generation helper = %#v", value)
	}
	if response := acknowledgement(testOperationID); response.SchemaVersion != wireSchemaVersion || response.OperationID != testOperationID {
		t.Fatalf("acknowledgement = %#v", response)
	}

	var invalidLength bytes.Buffer
	if err := binary.Write(&invalidLength, binary.BigEndian, uint32(0)); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := readFrame(&invalidLength); err == nil {
		t.Fatal("zero-length frame succeeded")
	}
	var oversized bytes.Buffer
	if err := binary.Write(&oversized, binary.BigEndian, uint32(maximumWireFrameBytes+1)); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := readFrame(&oversized); err == nil {
		t.Fatal("oversized frame succeeded")
	}
	if _, err := readFrame(bytes.NewReader([]byte{0, 0, 0})); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("short header error = %v", err)
	}
	var shortPayload bytes.Buffer
	if err := binary.Write(&shortPayload, binary.BigEndian, uint32(2)); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := shortPayload.Write([]byte("x")); err != nil {
		t.Fatalf("write short payload: %v", err)
	}
	if _, err := readFrame(&shortPayload); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("short payload error = %v", err)
	}

	writer := failingWireWriter{err: errors.New("write failed")}
	if err := writeFrame(&writer, acknowledgement(testOperationID)); !errors.Is(err, writer.err) {
		t.Fatalf("writeFrame error = %v", err)
	}
	payloadWriter := failingWireWriter{successfulWrites: 1, err: errors.New("payload write failed")}
	if err := writeFrame(&payloadWriter, acknowledgement(testOperationID)); !errors.Is(err, payloadWriter.err) {
		t.Fatalf("payload writeFrame error = %v", err)
	}
}

func TestDurationRejectsZeroAndOverflow(t *testing.T) {
	if duration, err := durationFromNanoseconds(1); err != nil || duration != time.Nanosecond {
		t.Fatalf("one-nanosecond duration = %v, %v", duration, err)
	}
	for _, value := range []uint64{0, uint64(1 << 63)} {
		if _, err := durationFromNanoseconds(value); err == nil {
			t.Fatalf("invalid duration succeeded: %d", value)
		}
	}
}

type failingWireWriter struct {
	successfulWrites int
	calls            int
	err              error
}

func (writer *failingWireWriter) Write(payload []byte) (int, error) {
	writer.calls++
	if writer.calls <= writer.successfulWrites {
		return len(payload), nil
	}
	return 0, writer.err
}
