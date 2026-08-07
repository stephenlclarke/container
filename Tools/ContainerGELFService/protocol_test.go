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
	"encoding/json"
	"testing"
)

const testOperationID = "123e4567-e89b-42d3-a456-426614174000"

func TestDecodeWireRequestRejectsUnexpectedPayloadsAndFields(t *testing.T) {
	timeout := uint64(1_000_000)
	valid := wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        testOperationID,
		Operation:          operationOpen,
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: "12201"},
		TimeoutNanoseconds: &timeout,
	}
	payload, err := json.Marshal(valid)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	decoded, err := decodeWireRequest(payload)
	if err != nil || decoded.SchemaVersion != valid.SchemaVersion ||
		decoded.OperationID != valid.OperationID || decoded.Operation != valid.Operation ||
		decoded.Endpoint == nil || *decoded.Endpoint != *valid.Endpoint ||
		decoded.TimeoutNanoseconds == nil ||
		*decoded.TimeoutNanoseconds != *valid.TimeoutNanoseconds {
		t.Fatalf("decoded request = %#v, %v", decoded, err)
	}
	for _, invalid := range [][]byte{
		[]byte(`{"schemaVersion":1,"operationID":"123e4567-e89b-42d3-a456-426614174000","operation":"open","endpoint":{"host":"127.0.0.1","port":"12201"},"timeoutNanoseconds":1000000,"surprise":true}`),
		[]byte(`{"schemaVersion":1,"operationID":"123e4567-e89b-42d3-a456-426614174000","operation":"write","timeoutNanoseconds":1000000,"frame":"","endpoint":null}`),
		[]byte(`{"schemaVersion":1,"operationID":"123e4567-e89b-42d3-a456-426614174000","operation":"close","frame":"AQ=="}`),
	} {
		if _, err := decodeWireRequest(invalid); err == nil {
			t.Fatalf("invalid request succeeded: %s", invalid)
		}
	}
}

func TestDefaultIPv4GatewayUsesLinuxRouteByteOrder(t *testing.T) {
	routes := "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n" +
		"lo\t00000000\t0100007F\t0001\t0\t0\t0\t00000000\t0\t0\t0\n" +
		"eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n"
	gateway, err := defaultIPv4Gateway(routes)
	if err != nil || gateway != "192.168.1.1" {
		t.Fatalf("gateway = %q, %v", gateway, err)
	}
	if _, err := defaultIPv4Gateway("Iface\tDestination\tGateway\tFlags\neth0\t00000000\t0101A8C0\t0001\n"); err == nil {
		t.Fatal("route without gateway flag succeeded")
	}
}

func TestWireResponseFrameRoundTripsExactly(t *testing.T) {
	var encoded bytes.Buffer
	if err := writeFrame(&encoded, writeReceipt(testOperationID, 9)); err != nil {
		t.Fatalf("write response frame: %v", err)
	}
	payload, err := readFrame(&encoded)
	if err != nil {
		t.Fatalf("read response frame: %v", err)
	}
	var response wireResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.SchemaVersion != wireSchemaVersion || response.OperationID != testOperationID ||
		response.WrittenBytes == nil || *response.WrittenBytes != 9 || response.Failure != nil {
		t.Fatalf("response = %#v", response)
	}
}
