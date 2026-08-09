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
	"context"
	"encoding/binary"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"
)

func TestProtocolHandlerJoinsAndReplaysSemanticRequest(t *testing.T) {
	t.Parallel()

	backend := &recordingServiceBackend{generationValue: 13, generationStarted: make(chan struct{})}
	handler := newProtocolHandler(backend)
	request := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationActiveSandboxGeneration,
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	const callers = 16
	responses := make(chan wireResponse, callers)
	for range callers {
		go func() {
			responses <- handler.Handle(t.Context(), payload)
		}()
	}
	<-backend.generationStarted
	backend.releaseGeneration()
	for range callers {
		response := <-responses
		if response.SandboxGeneration == nil || *response.SandboxGeneration != 13 || response.Failure != nil {
			t.Fatalf("unexpected response: %#v", response)
		}
	}
	if backend.generationCalls != 1 {
		t.Fatalf("generation calls = %d, want 1", backend.generationCalls)
	}

	semanticReplay := []byte(`{ "operation": "activeSandboxGeneration", "operationID": "` +
		testOperationID + `", "schemaVersion": 2 }`)
	response := handler.Handle(t.Context(), semanticReplay)
	if response.SandboxGeneration == nil || *response.SandboxGeneration != 13 || response.Failure != nil {
		t.Fatalf("semantic replay failed: %#v", response)
	}
	if backend.generationCalls != 1 {
		t.Fatalf("semantic replay repeated effect: %d", backend.generationCalls)
	}
}

func TestProtocolHandlerRejectsOperationIdentityConflict(t *testing.T) {
	t.Parallel()

	backend := &recordingServiceBackend{generationValue: 13}
	handler := newProtocolHandler(backend)
	first, err := json.Marshal(wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationActiveSandboxGeneration,
	})
	if err != nil {
		t.Fatal(err)
	}
	if response := handler.Handle(t.Context(), first); response.Failure != nil {
		t.Fatalf("initial response failed: %#v", response)
	}
	sessionID := "missing-session"
	second, err := json.Marshal(wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationCancelReader,
		SessionID:     &sessionID,
	})
	if err != nil {
		t.Fatal(err)
	}
	response := handler.Handle(t.Context(), second)
	if response.Failure == nil || *response.Failure != failureIdempotencyConflict {
		t.Fatalf("conflict response = %#v", response)
	}
}

func TestCompletedReplayBudgetIncludesRetainedRequest(t *testing.T) {
	t.Parallel()

	handler := newProtocolHandler(&recordingServiceBackend{generationValue: 13})
	payload, err := json.Marshal(wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationActiveSandboxGeneration,
	})
	if err != nil {
		t.Fatal(err)
	}
	if response := handler.Handle(t.Context(), payload); response.Failure != nil {
		t.Fatalf("response failed: %#v", response)
	}

	handler.mu.Lock()
	operation := handler.operations[testOperationID]
	accountedBytes := handler.completedEncodedBytes
	handler.mu.Unlock()
	if operation == nil || operation.requestBytes != len(payload) {
		t.Fatalf("retained request bytes = %#v, want %d", operation, len(payload))
	}
	if accountedBytes <= len(payload) {
		t.Fatalf("accounted bytes = %d, want request plus response", accountedBytes)
	}
}

func TestPersistentFramedConnection(t *testing.T) {
	t.Parallel()

	client, server := net.Pipe()
	ctx := t.Context()
	handler := newProtocolHandler(&recordingServiceBackend{generationValue: 17})
	done := make(chan struct{})
	go func() {
		serveConnection(ctx, server, handler)
		close(done)
	}()
	for index := 0; index < 2; index++ {
		request := wireRequest{
			SchemaVersion: wireSchemaVersion,
			OperationID:   []string{testOperationID, "123e4567-e89b-12d3-a456-426614174001"}[index],
			Operation:     operationActiveSandboxGeneration,
		}
		payload, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		if err := writePayloadFrame(client, payload); err != nil {
			t.Fatal(err)
		}
		responsePayload, err := readFrame(client)
		if err != nil {
			t.Fatal(err)
		}
		var response wireResponse
		if err := json.Unmarshal(responsePayload, &response); err != nil {
			t.Fatal(err)
		}
		if response.OperationID != request.OperationID || response.SandboxGeneration == nil || *response.SandboxGeneration != 17 {
			t.Fatalf("response = %#v", response)
		}
	}
	_ = client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("connection did not stop")
	}
}

func writePayloadFrame(connection net.Conn, payload []byte) error {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if err := writeAll(connection, header[:]); err != nil {
		return err
	}
	return writeAll(connection, payload)
}

type recordingServiceBackend struct {
	mu                sync.Mutex
	generationValue   uint64
	generationCalls   int
	generationStarted chan struct{}
	generationRelease chan struct{}
	startOnce         sync.Once
	releaseOnce       sync.Once
}

func (backend *recordingServiceBackend) generation() uint64 {
	backend.mu.Lock()
	backend.generationCalls++
	started := backend.generationStarted
	release := backend.generationRelease
	if started != nil && release == nil {
		release = make(chan struct{})
		backend.generationRelease = release
	}
	backend.mu.Unlock()
	if started != nil {
		backend.startOnce.Do(func() { close(started) })
		<-release
	}
	return backend.generationValue
}

func (backend *recordingServiceBackend) releaseGeneration() {
	backend.mu.Lock()
	release := backend.generationRelease
	backend.mu.Unlock()
	if release != nil {
		backend.releaseOnce.Do(func() { close(release) })
	}
}

func (*recordingServiceBackend) openWriter(writerOpenWire) error { return nil }
func (*recordingServiceBackend) write(context.Context, string, journalEntryWire) error {
	return nil
}
func (*recordingServiceBackend) flushWriter(context.Context, string, uint64) error { return nil }
func (*recordingServiceBackend) closeWriter(context.Context, string, bool, uint64) error {
	return nil
}
func (*recordingServiceBackend) reclaimWriter(terminalReclaimWire) error { return nil }
func (*recordingServiceBackend) openReader(context.Context, readerOpenWire) (uint64, error) {
	return 1, nil
}
func (*recordingServiceBackend) nextReader(context.Context, string, uint64) (readerEventWire, error) {
	return readerEventWire{Kind: "endOfStream"}, nil
}
func (*recordingServiceBackend) cancelReader(string) error               { return nil }
func (*recordingServiceBackend) reclaimReader(terminalReclaimWire) error { return nil }
