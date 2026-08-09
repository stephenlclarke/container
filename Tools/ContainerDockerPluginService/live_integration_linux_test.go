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
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestLiveUnixPluginFIFOAndReadLogs(t *testing.T) {
	root := t.TempDir()
	plugin := newLivePluginFixture(t, filepath.Join(root, "plugin.sock"), true)
	defer plugin.Close(t)
	client, err := newUnixHTTPLoggingPlugin(plugin.socketPath)
	if err != nil {
		t.Fatalf("new plugin client: %v", err)
	}
	fifos, err := newLinuxFIFOFactory(filepath.Join(root, "fifos"))
	if err != nil {
		t.Fatalf("new FIFO factory: %v", err)
	}
	store, err := newFileStateStore(filepath.Join(root, "state", "state.json"))
	if err != nil {
		t.Fatalf("new state store: %v", err)
	}
	backend, err := loadDurableBackend(
		testServiceIdentity(),
		store,
		client,
		fifos,
		fixedTokenGenerator{},
	)
	if err != nil {
		t.Fatalf("load backend: %v", err)
	}

	open := testWriterOpen(true)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	frame := []byte{0, 0, 0, 5, 0x0a, 0x03, 'o', 'n', 'e'}
	if err := backend.writeWriter(context.Background(), open.Request.SessionID, receipt.Token, 1, frame); err != nil {
		t.Fatalf("write FIFO frame: %v", err)
	}
	select {
	case received := <-plugin.frames:
		if string(received) != string(frame) {
			t.Fatalf("FIFO frame = %x, want %x", received, frame)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("plugin did not receive FIFO frame")
	}
	if err := backend.finishWriter(context.Background(), open.Request.SessionID, receipt.Token, false); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	if got := plugin.takeStopPathPresence(t); !got {
		t.Fatal("graceful StopLogging ran after FIFO removal")
	}

	fencedOpen := testWriterOpen(true)
	fencedOpen.Request.SessionID = "writer-session-fenced"
	fencedOpen.Request.IdempotencyKey = "writer-operation-fenced"
	fencedReceipt, err := backend.openWriter(context.Background(), fencedOpen)
	if err != nil {
		t.Fatalf("open fenced writer: %v", err)
	}
	if err := backend.finishWriter(
		context.Background(),
		fencedOpen.Request.SessionID,
		fencedReceipt.Token,
		true,
	); err != nil {
		t.Fatalf("fence writer: %v", err)
	}
	if got := plugin.takeStopPathPresence(t); got {
		t.Fatal("authoritative fence did not revoke FIFO before StopLogging")
	}

	readerOpen := testReaderOpen()
	readerReceipt, err := backend.openReader(context.Background(), readerOpen)
	if err != nil {
		t.Fatalf("open reader: %v", err)
	}
	result, err := backend.nextReader(
		context.Background(),
		readerOpen.Request.ReaderSessionID,
		readerReceipt.Token,
		1,
	)
	if err != nil {
		t.Fatalf("next reader: %v", err)
	}
	if string(result.Frame) != string(plugin.readFrame) || result.EndOfStream {
		t.Fatalf("reader result = %#v, want frame", result)
	}
	end, err := backend.nextReader(
		context.Background(),
		readerOpen.Request.ReaderSessionID,
		readerReceipt.Token,
		2,
	)
	if err != nil || !end.EndOfStream {
		t.Fatalf("reader end = %#v, %v", end, err)
	}

	stateInfo, err := os.Stat(filepath.Join(root, "state", "state.json"))
	if err != nil {
		t.Fatalf("state file: %v", err)
	}
	if stateInfo.Mode().Perm() != 0o600 {
		t.Fatalf("state mode = %o, want 600", stateInfo.Mode().Perm())
	}
}

func TestLiveWriteOnlyUnixPluginNeverOpensReadLogs(t *testing.T) {
	root := t.TempDir()
	plugin := newLivePluginFixture(t, filepath.Join(root, "plugin.sock"), false)
	defer plugin.Close(t)
	client, err := newUnixHTTPLoggingPlugin(plugin.socketPath)
	if err != nil {
		t.Fatalf("new plugin client: %v", err)
	}
	fifos, err := newLinuxFIFOFactory(filepath.Join(root, "fifos"))
	if err != nil {
		t.Fatalf("new FIFO factory: %v", err)
	}
	store, err := newFileStateStore(filepath.Join(root, "state", "state.json"))
	if err != nil {
		t.Fatalf("new state store: %v", err)
	}
	backend, err := loadDurableBackend(
		testServiceIdentity(),
		store,
		client,
		fifos,
		fixedTokenGenerator{},
	)
	if err != nil {
		t.Fatalf("load backend: %v", err)
	}

	open := testWriterOpen(false)
	receipt, err := backend.openWriter(context.Background(), open)
	if err != nil {
		t.Fatalf("open writer: %v", err)
	}
	if receipt.Capabilities.ReadLogs {
		t.Fatal("write-only plugin advertised ReadLogs")
	}
	if err := backend.finishWriter(context.Background(), open.Request.SessionID, receipt.Token, false); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	if _, err := backend.openReader(context.Background(), testReaderOpen()); !errors.Is(err, errCapabilityMismatch) {
		t.Fatalf("open reader error = %v, want capability mismatch", err)
	}
	select {
	case <-plugin.readLogCalls:
		t.Fatal("write-only plugin received ReadLogs")
	default:
	}
}

func TestLiveBlockedFIFOWriteObservesCancellation(t *testing.T) {
	factory, err := newLinuxFIFOFactory(filepath.Join(t.TempDir(), "fifos"))
	if err != nil {
		t.Fatalf("new FIFO factory: %v", err)
	}
	handle, err := factory.Open("blocked-writer", 7)
	if err != nil {
		t.Fatalf("open FIFO: %v", err)
	}
	defer handle.RevokeAndRemove()
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.AfterFunc(50*time.Millisecond, cancel)
	defer timer.Stop()
	started := time.Now()
	err = handle.Write(ctx, make([]byte, 1024*1024))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("blocked write error = %v, want cancellation", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("blocked write cancellation took %s", elapsed)
	}
}

func TestLiveConnectionWatchCancelsWhenPeerCloses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptError := listener.Accept()
		if acceptError == nil {
			accepted <- connection
		}
	}()
	client, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server := <-accepted
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	monitorConnectionClosure(ctx, cancel, server)
	if err := client.Close(); err != nil {
		t.Fatalf("close peer: %v", err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("connection watch did not cancel after peer close")
	}
}

type livePluginFixture struct {
	socketPath       string
	listener         net.Listener
	server           *http.Server
	readLogsCapable  bool
	frames           chan []byte
	readFrame        []byte
	readLogCalls     chan struct{}
	stopPathPresence chan bool

	mu      sync.Mutex
	readers map[string]*os.File
}

func newLivePluginFixture(t *testing.T, socketPath string, readLogs bool) *livePluginFixture {
	t.Helper()
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen plugin socket: %v", err)
	}
	fixture := &livePluginFixture{
		socketPath:       socketPath,
		listener:         listener,
		readLogsCapable:  readLogs,
		frames:           make(chan []byte, 2),
		readFrame:        []byte{0, 0, 0, 1, 0x2a},
		readLogCalls:     make(chan struct{}, 1),
		stopPathPresence: make(chan bool, 2),
		readers:          make(map[string]*os.File),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/LogDriver.Capabilities", fixture.capabilities)
	mux.HandleFunc("/LogDriver.StartLogging", fixture.startLogging)
	mux.HandleFunc("/LogDriver.StopLogging", fixture.stopLogging)
	mux.HandleFunc("/LogDriver.ReadLogs", fixture.readLogs)
	fixture.server = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		_ = fixture.server.Serve(listener)
	}()
	return fixture
}

func (fixture *livePluginFixture) capabilities(response http.ResponseWriter, _ *http.Request) {
	writePluginJSON(response, map[string]any{
		"Cap": map[string]bool{"ReadLogs": fixture.readLogsCapable},
		"Err": "",
	})
}

func (fixture *livePluginFixture) startLogging(response http.ResponseWriter, request *http.Request) {
	var input struct {
		File string          `json:"File"`
		Info json.RawMessage `json:"Info"`
	}
	if decodeBoundedPluginRequest(request, &input) != nil || input.File == "" || len(input.Info) == 0 {
		http.Error(response, "invalid", http.StatusBadRequest)
		return
	}
	reader, err := os.OpenFile(input.File, os.O_RDONLY, 0)
	if err != nil {
		http.Error(response, "unavailable", http.StatusInternalServerError)
		return
	}
	fixture.mu.Lock()
	fixture.readers[input.File] = reader
	fixture.mu.Unlock()
	go func() {
		header := make([]byte, 4)
		if _, err := io.ReadFull(reader, header); err != nil {
			return
		}
		length := int(header[0])<<24 | int(header[1])<<16 | int(header[2])<<8 | int(header[3])
		if length <= 0 || length > maximumLogFrameBytes {
			return
		}
		frame := make([]byte, 4+length)
		copy(frame, header)
		if _, err := io.ReadFull(reader, frame[4:]); err == nil {
			fixture.frames <- frame
		}
	}()
	writePluginJSON(response, map[string]string{"Err": ""})
}

func (fixture *livePluginFixture) stopLogging(response http.ResponseWriter, request *http.Request) {
	var input struct {
		File string `json:"File"`
	}
	if decodeBoundedPluginRequest(request, &input) != nil || input.File == "" {
		http.Error(response, "invalid", http.StatusBadRequest)
		return
	}
	_, err := os.Lstat(input.File)
	fixture.stopPathPresence <- err == nil
	fixture.mu.Lock()
	reader := fixture.readers[input.File]
	delete(fixture.readers, input.File)
	fixture.mu.Unlock()
	if reader != nil {
		_ = reader.Close()
	}
	writePluginJSON(response, map[string]string{"Err": ""})
}

func (fixture *livePluginFixture) readLogs(response http.ResponseWriter, request *http.Request) {
	select {
	case fixture.readLogCalls <- struct{}{}:
	default:
	}
	var input map[string]json.RawMessage
	if decodeBoundedPluginRequest(request, &input) != nil || input["Info"] == nil || input["Config"] == nil {
		http.Error(response, "invalid", http.StatusBadRequest)
		return
	}
	response.Header().Set("Content-Type", "application/octet-stream")
	_, _ = response.Write(fixture.readFrame)
}

func (fixture *livePluginFixture) takeStopPathPresence(t *testing.T) bool {
	t.Helper()
	select {
	case value := <-fixture.stopPathPresence:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("plugin did not receive StopLogging")
		return false
	}
}

func (fixture *livePluginFixture) Close(t *testing.T) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := fixture.server.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		t.Errorf("shutdown plugin: %v", err)
	}
	fixture.mu.Lock()
	defer fixture.mu.Unlock()
	for _, reader := range fixture.readers {
		_ = reader.Close()
	}
}

func decodeBoundedPluginRequest(request *http.Request, output any) error {
	defer request.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(request.Body, maximumPluginRequestBytes+1))
	return decoder.Decode(output)
}

func writePluginJSON(response http.ResponseWriter, value any) {
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(value)
}
