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
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"testing"
	"time"
)

func TestAuthenticationMatchesSwiftFixture(t *testing.T) {
	payload := []byte(`{"operation":"activeSandboxGeneration","operationID":"123e4567-e89b-12d3-a456-426614174000","schemaVersion":1,"authentication":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}`)
	canonical, err := canonicalUnauthenticatedRequest(payload)
	if err != nil {
		t.Fatalf("canonical request: %v", err)
	}
	mac := hmac.New(sha256.New, testAuthenticationKey())
	_, _ = mac.Write(canonical)
	if got := hex.EncodeToString(mac.Sum(nil)); got != "97dea1d206ae8a20fe40a00b63c6398aca7026ad6e443945799898b6d34965ff" {
		t.Fatalf("fixture HMAC = %s", got)
	}
}

func TestProtocolReplayReturnsOneWriterEffect(t *testing.T) {
	plugin := newFakePlugin(true)
	fifos := newFakeFIFOFactory()
	backend := newTestBackend(t, &memoryStateStore{}, plugin, fifos)
	handler := newProtocolHandler(backend, testAuthenticationKey())
	request := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-12d3-a456-426614174000",
		Operation:     operationStartWriter,
		WriterOpen:    pointer(testWriterOpen(true)),
	}
	payload := authenticatedWireJSON(t, request)

	first := handler.Handle(context.Background(), payload)
	replay := handler.Handle(context.Background(), payload)
	if first.Failure != nil || replay.Failure != nil {
		t.Fatalf("start responses = %#v, %#v", first, replay)
	}
	if !sameToken(first.Token, replay.Token) {
		t.Fatal("operation replay changed effect token")
	}
	if plugin.logicalStartCount() != 1 || fifos.openCallCount() != 1 {
		t.Fatalf(
			"replay effects = plugin %d, FIFO %d; want one each",
			plugin.logicalStartCount(),
			fifos.openCallCount(),
		)
	}

	conflict := request
	conflictingOpen := *request.WriterOpen
	conflictingOpen.Request.SemanticRequestDigest = "sha256:conflict"
	conflict.WriterOpen = &conflictingOpen
	response := handler.Handle(context.Background(), authenticatedWireJSON(t, conflict))
	if response.Failure == nil || *response.Failure != failureIdempotencyConflict {
		t.Fatalf("conflicting operation response = %#v", response)
	}
	if plugin.logicalStartCount() != 1 || fifos.openCallCount() != 1 {
		t.Fatal("conflicting operation created a second effect")
	}
}

func TestProtocolHandlerDrivesCompleteWriterAndReaderLifecycles(t *testing.T) {
	plugin := newFakePlugin(true)
	plugin.readFrames = [][]byte{{0, 0, 0, 1, 0x2a}}
	backend := newTestBackend(t, &memoryStateStore{}, plugin, newFakeFIFOFactory())
	handler := newProtocolHandler(backend, testAuthenticationKey())
	operationSequence := uint64(0)
	call := func(request wireRequest) wireResponse {
		t.Helper()
		operationSequence++
		request.SchemaVersion = wireSchemaVersion
		request.OperationID = fmt.Sprintf("00000000-0000-4000-8000-%012x", operationSequence)
		response := handler.Handle(context.Background(), authenticatedWireJSON(t, request))
		if response.Failure != nil {
			t.Fatalf("%s response = %#v", request.Operation, response)
		}
		return response
	}

	generation := call(wireRequest{Operation: operationActiveSandboxGeneration})
	if generation.SandboxGeneration == nil || *generation.SandboxGeneration != testServiceIdentity().SandboxGeneration {
		t.Fatalf("sandbox generation response = %#v", generation)
	}

	closedWriter := namedWriterOpen("writer-close", true)
	closedReceipt := call(wireRequest{Operation: operationStartWriter, WriterOpen: &closedWriter})
	assertReceipt(t, closedReceipt, true, 1)
	reconciledWriter := call(wireRequest{
		Operation:   operationReconcileWriterOpen,
		WriterStart: &closedWriter.Request,
	})
	if reconciledWriter.OpenObservation == nil || *reconciledWriter.OpenObservation != observationPrepared ||
		!sameToken(reconciledWriter.Token, closedReceipt.Token) {
		t.Fatalf("writer open reconciliation = %#v", reconciledWriter)
	}
	writerSequence := uint64(1)
	frame := []byte{0, 0, 0, 1, 1}
	call(wireRequest{
		Operation: operationWriteWriter,
		SessionID: &closedWriter.Request.SessionID,
		Token:     closedReceipt.Token,
		Sequence:  &writerSequence,
		Frame:     frame,
	})
	call(wireRequest{
		Operation: operationFlushWriter,
		SessionID: &closedWriter.Request.SessionID,
		Token:     closedReceipt.Token,
	})
	closedCall := testWriterCall(closedWriter.Request, closedReceipt.Token)
	activeWriter := call(wireRequest{Operation: operationReconcileWriter, WriterCall: &closedCall})
	assertWriterObservation(t, activeWriter, "active", false)
	closed := call(wireRequest{Operation: operationCloseWriter, WriterCall: &closedCall})
	assertWriterObservation(t, closed, "closed", false)
	reclaimTerminal(t, call, "writerSession", closedWriter.Request.SessionID)

	finishedWriter := namedWriterOpen("writer-finish", true)
	finishedReceipt := call(wireRequest{Operation: operationStartWriter, WriterOpen: &finishedWriter})
	finished := false
	call(wireRequest{
		Operation: operationFinishWriter,
		SessionID: &finishedWriter.Request.SessionID,
		Token:     finishedReceipt.Token,
		Fenced:    &finished,
	})
	finishedCall := testWriterCall(finishedWriter.Request, finishedReceipt.Token)
	finishedObservation := call(wireRequest{Operation: operationReconcileWriter, WriterCall: &finishedCall})
	assertWriterObservation(t, finishedObservation, "closed", false)
	reclaimTerminal(t, call, "writerCandidate", finishedWriter.Request.SessionID)

	fencedWriter := namedWriterOpen("writer-fence", true)
	fencedReceipt := call(wireRequest{Operation: operationStartWriter, WriterOpen: &fencedWriter})
	fencedCall := testWriterCall(fencedWriter.Request, fencedReceipt.Token)
	fenced := call(wireRequest{Operation: operationFenceWriter, WriterCall: &fencedCall})
	assertWriterObservation(t, fenced, "writerFenced", true)
	reclaimTerminal(t, call, "detachedCleanup", fencedWriter.Request.SessionID)

	endedReader := namedReaderOpen("reader-ended")
	readerReceipt := call(wireRequest{Operation: operationOpenReader, ReaderOpen: &endedReader})
	assertReceipt(t, readerReceipt, true, 1)
	reconciledReader := call(wireRequest{
		Operation:   operationReconcileReaderOpen,
		ReaderStart: &endedReader.Request,
	})
	if reconciledReader.OpenObservation == nil || *reconciledReader.OpenObservation != observationPrepared ||
		!sameToken(reconciledReader.Token, readerReceipt.Token) {
		t.Fatalf("reader open reconciliation = %#v", reconciledReader)
	}
	readerSequence := uint64(1)
	readerFrame := call(wireRequest{
		Operation: operationNextReader,
		SessionID: &endedReader.Request.ReaderSessionID,
		Token:     readerReceipt.Token,
		Sequence:  &readerSequence,
	})
	if readerFrame.EndOfStream == nil || *readerFrame.EndOfStream || !bytes.Equal(readerFrame.Frame, plugin.readFrames[0]) {
		t.Fatalf("reader frame response = %#v", readerFrame)
	}
	readerSequence++
	readerEnd := call(wireRequest{
		Operation: operationNextReader,
		SessionID: &endedReader.Request.ReaderSessionID,
		Token:     readerReceipt.Token,
		Sequence:  &readerSequence,
	})
	if readerEnd.EndOfStream == nil || !*readerEnd.EndOfStream || len(readerEnd.Frame) != 0 {
		t.Fatalf("reader end response = %#v", readerEnd)
	}
	endedCall := testReaderCall(endedReader.Request, readerReceipt.Token)
	endedObservation := call(wireRequest{Operation: operationReconcileReader, ReaderCall: &endedCall})
	assertReaderObservation(t, endedObservation, "closed", true)
	closedReader := call(wireRequest{Operation: operationCloseReader, ReaderCall: &endedCall})
	assertReaderObservation(t, closedReader, "closed", true)
	reclaimTerminal(t, call, "readerSession", endedReader.Request.ReaderSessionID)

	cancelledReader := namedReaderOpen("reader-cancelled")
	cancelledReceipt := call(wireRequest{Operation: operationOpenReader, ReaderOpen: &cancelledReader})
	call(wireRequest{
		Operation: operationCancelReader,
		SessionID: &cancelledReader.Request.ReaderSessionID,
		Token:     cancelledReceipt.Token,
	})
	cancelledCall := testReaderCall(cancelledReader.Request, cancelledReceipt.Token)
	cancelledObservation := call(wireRequest{Operation: operationReconcileReader, ReaderCall: &cancelledCall})
	assertReaderObservation(t, cancelledObservation, "closed", true)
	reclaimTerminal(t, call, "readerCandidate", cancelledReader.Request.ReaderSessionID)

	if backend.snapshot.Writers == nil || len(backend.snapshot.Writers) != 0 ||
		backend.snapshot.Readers == nil || len(backend.snapshot.Readers) != 0 {
		t.Fatalf("terminal effects were not reclaimed: %#v", backend.snapshot)
	}
}

func TestProtocolRejectsUnknownAndOversizedPayloadsWithoutEffects(t *testing.T) {
	plugin := newFakePlugin(false)
	fifos := newFakeFIFOFactory()
	handler := newProtocolHandler(
		newTestBackend(t, &memoryStateStore{}, plugin, fifos),
		testAuthenticationKey(),
	)
	unknown := []byte(`{
		"schemaVersion":1,
		"operationID":"123e4567-e89b-12d3-a456-426614174000",
		"operation":"activeSandboxGeneration",
		"unknown":true
	}`)
	response := handler.Handle(context.Background(), unknown)
	if response.Failure == nil || *response.Failure != failureInvalidRequest {
		t.Fatalf("unknown field response = %#v", response)
	}
	if plugin.startCallCount() != 0 || fifos.openCallCount() != 0 {
		t.Fatal("invalid envelope reached an effect boundary")
	}

	oversized := make([]byte, maximumWireFrameBytes+1)
	if _, err := decodeWireRequest(oversized, testServiceIdentity(), testAuthenticationKey()); err == nil {
		t.Fatal("oversized payload decoded")
	}
}

func namedWriterOpen(sessionID string, readLogs bool) writerOpen {
	open := testWriterOpen(readLogs)
	open.Request.IdempotencyKey = sessionID + "-operation"
	open.Request.SemanticRequestDigest = "sha256:" + sessionID
	open.Request.SessionID = sessionID
	return open
}

func namedReaderOpen(sessionID string) readerOpen {
	open := testReaderOpen()
	open.Request.IdempotencyKey = sessionID + "-operation"
	open.Request.SemanticRequestDigest = "sha256:" + sessionID
	open.Request.ReaderSessionID = sessionID
	return open
}

func testReaderCall(request readerStart, token []byte) readerCall {
	return readerCall{
		SchemaVersion:      serviceSchemaVersion,
		ReaderSessionID:    request.ReaderSessionID,
		ContainerID:        request.ContainerID,
		LeaseGeneration:    request.LeaseGeneration,
		ProviderID:         request.ProviderID,
		ProviderGeneration: request.ProviderGeneration,
		Source:             append(json.RawMessage(nil), request.Source...),
		Token:              append([]byte(nil), token...),
	}
}

func assertReceipt(t *testing.T, response wireResponse, readLogs bool, sequence uint64) {
	t.Helper()
	if len(response.Token) == 0 || response.Capabilities == nil || response.Capabilities.ReadLogs != readLogs ||
		response.Sequence == nil || *response.Sequence != sequence {
		t.Fatalf("receipt response = %#v", response)
	}
}

func assertWriterObservation(t *testing.T, response wireResponse, observation string, hasDigest bool) {
	t.Helper()
	if response.WriterObservation == nil || *response.WriterObservation != observation ||
		(response.FenceReceiptDigest != nil) != hasDigest {
		t.Fatalf("writer observation response = %#v", response)
	}
}

func assertReaderObservation(t *testing.T, response wireResponse, observation string, hasDigest bool) {
	t.Helper()
	if response.ReaderObservation == nil || *response.ReaderObservation != observation ||
		(response.TerminalDigest != nil) != hasDigest {
		t.Fatalf("reader observation response = %#v", response)
	}
}

func reclaimTerminal(t *testing.T, call func(wireRequest) wireResponse, kind string, sessionID string) {
	t.Helper()
	reclaim := terminalReclaim{
		SchemaVersion:      serviceSchemaVersion,
		Kind:               kind,
		EffectID:           sessionID,
		ProviderID:         testServiceIdentity().ID,
		ProviderGeneration: testServiceIdentity().Generation,
	}
	call(wireRequest{Operation: operationReclaimTerminalEffect, Reclaim: &reclaim})
}

func TestProtocolRejectsUnauthenticatedEffects(t *testing.T) {
	plugin := newFakePlugin(true)
	fifos := newFakeFIFOFactory()
	handler := newProtocolHandler(
		newTestBackend(t, &memoryStateStore{}, plugin, fifos),
		testAuthenticationKey(),
	)
	request := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-12d3-a456-426614174000",
		Operation:     operationStartWriter,
		WriterOpen:    pointer(testWriterOpen(true)),
	}
	for _, payload := range [][]byte{
		mustWireJSON(t, request),
		func() []byte {
			signed := authenticatedWireRequest(t, request)
			signed.Authentication[0] ^= 0xff
			return mustWireJSON(t, signed)
		}(),
	} {
		response := handler.Handle(context.Background(), payload)
		if response.Failure == nil || *response.Failure != failureInvalidRequest {
			t.Fatalf("unauthenticated response = %#v", response)
		}
	}
	if plugin.startCallCount() != 0 || fifos.openCallCount() != 0 {
		t.Fatal("unauthenticated request reached an effect boundary")
	}
}

func TestProtocolReplayLedgerEvictsOldestCompletedOperation(t *testing.T) {
	handler := newProtocolHandler(
		newTestBackend(t, &memoryStateStore{}, newFakePlugin(false), newFakeFIFOFactory()),
		testAuthenticationKey(),
	)
	for sequence := uint64(1); sequence <= maximumCompletedReplayOperations+1; sequence++ {
		request := wireRequest{
			SchemaVersion: wireSchemaVersion,
			OperationID:   fmt.Sprintf("00000000-0000-4000-8000-%012x", sequence),
			Operation:     operationActiveSandboxGeneration,
		}
		response := handler.Handle(context.Background(), authenticatedWireJSON(t, request))
		if response.Failure != nil {
			t.Fatalf("generation operation %d = %#v", sequence, response)
		}
	}
	handler.mu.Lock()
	defer handler.mu.Unlock()
	if len(handler.operations) != maximumCompletedReplayOperations ||
		handler.completedOrder.Len() != maximumCompletedReplayOperations {
		t.Fatalf(
			"replay ledger size = %d/%d, want %d",
			len(handler.operations),
			handler.completedOrder.Len(),
			maximumCompletedReplayOperations,
		)
	}
	if handler.operations["00000000-0000-4000-8000-000000000001"] != nil {
		t.Fatal("oldest completed operation was not evicted")
	}
}

func TestServeListenerProcessesAuthenticatedFramesAndStopsWithContext(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	handler := newProtocolHandler(
		newTestBackend(t, &memoryStateStore{}, newFakePlugin(false), newFakeFIFOFactory()),
		testAuthenticationKey(),
	)
	done := make(chan error, 1)
	go func() {
		done <- serveListener(ctx, listener, handler, 1)
	}()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		cancel()
		t.Fatalf("dial: %v", err)
	}
	request := authenticatedWireRequest(t, wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-42d3-a456-426614174001",
		Operation:     operationActiveSandboxGeneration,
	})
	if err := writeFrame(client, request); err != nil {
		_ = client.Close()
		cancel()
		t.Fatalf("write request: %v", err)
	}
	payload, err := readFrame(client)
	if err != nil {
		_ = client.Close()
		cancel()
		t.Fatalf("read response: %v", err)
	}
	var response wireResponse
	if err := json.Unmarshal(payload, &response); err != nil {
		_ = client.Close()
		cancel()
		t.Fatalf("decode response: %v", err)
	}
	if response.Failure != nil || response.SandboxGeneration == nil ||
		*response.SandboxGeneration != testServiceIdentity().SandboxGeneration {
		t.Fatalf("generation response = %#v", response)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("close client: %v", err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve listener: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("listener did not stop with context cancellation")
	}
}

func TestFailureMappingPreservesPublicFailureClasses(t *testing.T) {
	tests := []struct {
		err  error
		want wireFailure
	}{
		{errGenerationMismatch, failureGenerationMismatch},
		{errIdempotencyConflict, failureIdempotencyConflict},
		{errInvalidToken, failureInvalidToken},
		{errInvalidFence, failureInvalidFence},
		{errCapabilityMismatch, failureCapabilityMismatch},
		{errUnknownSession, failureUnknownSession},
		{errUnavailable, failureUnavailable},
		{context.Canceled, failureUnavailable},
		{context.DeadlineExceeded, failureUnavailable},
		{fmt.Errorf("private backend failure"), failureInternal},
	}
	for _, test := range tests {
		if got := failureForError(test.err); got != test.want {
			t.Errorf("failureForError(%v) = %q, want %q", test.err, got, test.want)
		}
	}
}

func TestWireFrameRoundTripAndLimit(t *testing.T) {
	request := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-12d3-a456-426614174000",
		Operation:     operationActiveSandboxGeneration,
	}
	request = authenticatedWireRequest(t, request)
	var frame bytes.Buffer
	if err := writeFrame(&frame, request); err != nil {
		t.Fatalf("write frame: %v", err)
	}
	payload, err := readFrame(&frame)
	if err != nil {
		t.Fatalf("read frame: %v", err)
	}
	decoded, err := decodeWireRequest(payload, testServiceIdentity(), testAuthenticationKey())
	if err != nil {
		t.Fatalf("decode frame: %v", err)
	}
	if decoded.OperationID != request.OperationID || decoded.Operation != request.Operation {
		t.Fatalf("decoded request = %#v", decoded)
	}
}

func pointer[T any](value T) *T {
	return &value
}

func mustWireJSON(t *testing.T, value any) []byte {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal wire value: %v", err)
	}
	return payload
}

func testAuthenticationKey() []byte {
	return bytes.Repeat([]byte{0x5a}, sha256.Size)
}

func authenticatedWireJSON(t *testing.T, request wireRequest) []byte {
	t.Helper()
	return mustWireJSON(t, authenticatedWireRequest(t, request))
}

func authenticatedWireRequest(t *testing.T, request wireRequest) wireRequest {
	t.Helper()
	request.Authentication = make([]byte, sha256.Size)
	canonical, err := canonicalUnauthenticatedRequest(mustWireJSON(t, request))
	if err != nil {
		t.Fatalf("canonical request: %v", err)
	}
	mac := hmac.New(sha256.New, testAuthenticationKey())
	_, _ = mac.Write(canonical)
	request.Authentication = mac.Sum(nil)
	return request
}
