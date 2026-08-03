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
	"strings"
	"testing"
	"time"
)

const testOperationID = "123e4567-e89b-12d3-a456-426614174000"

func TestFrameAndBinaryEntryRoundTrip(t *testing.T) {
	t.Parallel()

	sessionID := "writer-session"
	request := validWriteRequest(sessionID)
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeWireRequest(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded.Entry.Message, []byte{0x00, 0xff, '\n'}) {
		t.Fatalf("binary message changed: %x", decoded.Entry.Message)
	}

	response := acknowledgementResponse(request.OperationID)
	var framed bytes.Buffer
	if err := writeFrame(&framed, response); err != nil {
		t.Fatal(err)
	}
	responsePayload, err := readFrame(&framed)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip wireResponse
	if err := json.Unmarshal(responsePayload, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip != response {
		t.Fatalf("response changed: %#v", roundTrip)
	}
}

func TestRequestValidationRejectsUnknownAndConflictingPayloads(t *testing.T) {
	t.Parallel()

	unknown := []byte(`{"schemaVersion":1,"operationID":"` + testOperationID +
		`","operation":"activeSandboxGeneration","unexpected":true}`)
	if _, err := decodeWireRequest(unknown); err == nil {
		t.Fatal("unknown key accepted")
	}

	request := validWriteRequest("writer-session")
	zero := uint64(0)
	request.ReaderSequence = &zero
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeWireRequest(payload); err == nil {
		t.Fatal("conflicting operation payload accepted")
	}

	request = validWriteRequest("writer-session")
	request.Entry.Fields["_TRUSTED"] = "forbidden"
	payload, err = json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeWireRequest(payload); err == nil {
		t.Fatal("trusted journal field accepted")
	}
}

func TestReaderAndSwiftDateValidation(t *testing.T) {
	t.Parallel()

	tail := 100
	since := float64(0)
	until := float64(1.25)
	request := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationOpenReader,
		ReaderOpen: &readerOpenWire{
			SchemaVersion:         1,
			OperationGeneration:   1,
			IdempotencyKey:        "reader-operation",
			SemanticRequestDigest: "sha256:reader",
			ReaderSessionID:       "reader-session",
			ContainerID:           strings.Repeat("a", 64),
			LeaseGeneration:       2,
			ProviderID:            "com.apple.container.logging.providers.journald",
			ProviderGeneration:    3,
			Source: readerSourceWire{
				Kind: "stopped-container",
			},
			Read: readRequestWire{
				SchemaVersion: 1,
				Stdout:        true,
				Stderr:        true,
				Follow:        false,
				Tail:          &tail,
				Since:         &since,
				Until:         &until,
			},
		},
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeWireRequest(payload); err != nil {
		t.Fatal(err)
	}

	want := time.Date(2001, time.January, 1, 0, 0, 1, 250_000_000, time.UTC)
	if got := swiftDate(&until); got == nil || !got.Equal(want) {
		t.Fatalf("Swift date = %v, want %v", got, want)
	}
}

func TestFrameBounds(t *testing.T) {
	t.Parallel()

	if _, err := readFrame(bytes.NewReader([]byte{0, 0, 0, 0})); err == nil {
		t.Fatal("empty frame accepted")
	}
	header := []byte{0, 0x10, 0, 1}
	if _, err := readFrame(bytes.NewReader(header)); err == nil {
		t.Fatal("oversized frame accepted")
	}
}

func validWriteRequest(sessionID string) wireRequest {
	return wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationWrite,
		SessionID:     &sessionID,
		Entry: &journalEntryWire{
			SchemaVersion: 1,
			Message:       []byte{0x00, 0xff, '\n'},
			Priority:      6,
			Fields: map[string]string{
				"CONTAINER_ID_FULL":     strings.Repeat("a", 64),
				"CONTAINER_LOG_EPOCH":   "epoch-1",
				"CONTAINER_LOG_ORDINAL": "1",
			},
			SecondsSinceUnixEpoch: 1_700_000_000,
			Nanoseconds:           123,
			ProcessGeneration:     4,
		},
	}
}
