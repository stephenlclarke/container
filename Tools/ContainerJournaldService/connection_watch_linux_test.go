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

//go:build linux

package main

import (
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestConnectionCloseCancelsBlockingOperation(t *testing.T) {
	t.Parallel()

	listener, err := net.Listen("unix", filepath.Join(t.TempDir(), "service.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	backend := &blockingServiceBackend{
		started:  make(chan struct{}),
		canceled: make(chan struct{}),
	}
	done := make(chan struct{})
	go func() {
		connection, acceptError := listener.Accept()
		if acceptError == nil {
			serveConnection(t.Context(), connection, newProtocolHandler(backend))
		}
		close(done)
	}()
	client, err := net.Dial("unix", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	sequence := uint64(1)
	sessionID := "reader-session"
	payload, err := json.Marshal(wireRequest{
		SchemaVersion:  wireSchemaVersion,
		OperationID:    testOperationID,
		Operation:      operationNextReader,
		SessionID:      &sessionID,
		ReaderSequence: &sequence,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := writePayloadFrame(client, payload); err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.started:
	case <-time.After(time.Second):
		t.Fatal("operation did not start")
	}
	_ = client.Close()
	select {
	case <-backend.canceled:
	case <-time.After(time.Second):
		t.Fatal("connection close did not cancel operation")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("connection handler did not stop")
	}
}

type blockingServiceBackend struct {
	recordingServiceBackend
	started  chan struct{}
	canceled chan struct{}
}

func (backend *blockingServiceBackend) nextReader(ctx context.Context, _ string, _ uint64) (readerEventWire, error) {
	close(backend.started)
	<-ctx.Done()
	close(backend.canceled)
	return readerEventWire{}, ctx.Err()
}
