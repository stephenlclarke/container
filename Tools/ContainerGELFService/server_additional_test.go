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
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestConnectionSessionHandlesControlAndInvalidWireOperations(t *testing.T) {
	session := connectionSession{sandboxGeneration: 11}
	invalid := session.handle(context.Background(), []byte(`{"operationID":"`+testOperationID+`","surprise":true}`))
	if invalid.Failure == nil || *invalid.Failure != failureInvalidRequest || invalid.OperationID != testOperationID {
		t.Fatalf("invalid response = %#v", invalid)
	}
	generationResponse := session.handleRequest(context.Background(), wireRequest{
		OperationID: testOperationID,
		Operation:   operationActiveSandboxGeneration,
	})
	if generationResponse.SandboxGeneration == nil || *generationResponse.SandboxGeneration != 11 {
		t.Fatalf("generation response = %#v", generationResponse)
	}
	remote := &controlledConnection{}
	session.remote = remote
	closeResponse := session.handleRequest(context.Background(), wireRequest{
		OperationID: "123e4567-e89b-42d3-a456-426614174003",
		Operation:   operationClose,
	})
	if closeResponse.Failure != nil || session.remote != nil || remote.closeCount != 1 {
		t.Fatalf("close response = %#v, closeCount = %d", closeResponse, remote.closeCount)
	}
	unsupported := session.handleRequest(context.Background(), wireRequest{
		OperationID: testOperationID,
		Operation:   "unexpected",
	})
	if unsupported.Failure == nil || *unsupported.Failure != failureInvalidRequest {
		t.Fatalf("unsupported response = %#v", unsupported)
	}
}

func TestConnectionSessionOpenReplacesStaleConnectionAndClassifiesFailures(t *testing.T) {
	timeout := uint64(time.Second)
	session := connectionSession{}
	invalid := session.open(context.Background(), wireRequest{
		OperationID:        testOperationID,
		Endpoint:           &endpoint{Host: "localhost", Port: "not-a-port"},
		TimeoutNanoseconds: &timeout,
	})
	if invalid.Failure == nil || *invalid.Failure != failureInvalidRequest {
		t.Fatalf("invalid open response = %#v", invalid)
	}

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	connectionFailure := session.open(cancelled, wireRequest{
		OperationID:        "123e4567-e89b-42d3-a456-426614174004",
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: "12201"},
		TimeoutNanoseconds: &timeout,
	})
	if connectionFailure.Failure == nil || *connectionFailure.Failure != failureConnectionFailed {
		t.Fatalf("cancelled open response = %#v", connectionFailure)
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- connection
		}
	}()
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatalf("split listener address: %v", err)
	}
	stale := &controlledConnection{}
	session.remote = stale
	opened := session.open(context.Background(), wireRequest{
		OperationID:        "123e4567-e89b-42d3-a456-426614174005",
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: port},
		TimeoutNanoseconds: &timeout,
	})
	if opened.Failure != nil || session.remote == nil || stale.closeCount != 1 {
		t.Fatalf("open response = %#v, stale closeCount = %d", opened, stale.closeCount)
	}
	select {
	case connection := <-accepted:
		_ = connection.Close()
	case <-time.After(time.Second):
		t.Fatal("replacement connection was not accepted")
	}
	session.closeRemote()
}

func TestConnectionSessionWriteClassifiesEveryTransportOutcome(t *testing.T) {
	timeout := uint64(time.Second)
	zero := uint64(0)
	tests := []struct {
		name          string
		remote        *controlledConnection
		timeout       *uint64
		wantFailure   *wireFailure
		wantPersisted bool
	}{
		{name: "unavailable", wantFailure: failurePointer(failureUnavailable)},
		{name: "invalid timeout", remote: &controlledConnection{}, timeout: &zero, wantFailure: failurePointer(failureInvalidRequest), wantPersisted: true},
		{name: "deadline setup", remote: &controlledConnection{deadlineErrors: []error{errors.New("deadline")}}, wantFailure: failurePointer(failureInternal)},
		{name: "write failure", remote: &controlledConnection{writeError: errors.New("write")}, wantFailure: failurePointer(failureWriteFailed)},
		{name: "partial write", remote: &controlledConnection{writeCount: 1}, wantFailure: failurePointer(failureWriteFailed)},
		{name: "write timeout", remote: &controlledConnection{writeError: timeoutNetworkError{}}, wantFailure: failurePointer(failureTimedOut)},
		{name: "clear deadline failure", remote: &controlledConnection{deadlineErrors: []error{nil, errors.New("clear deadline")}}, wantFailure: failurePointer(failureWriteFailed)},
		{name: "clear deadline timeout", remote: &controlledConnection{deadlineErrors: []error{nil, timeoutNetworkError{}}}, wantFailure: failurePointer(failureTimedOut)},
		{name: "success", remote: &controlledConnection{}, wantPersisted: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var session connectionSession
			if test.remote != nil {
				session.remote = test.remote
			}
			requestTimeout := test.timeout
			if requestTimeout == nil {
				requestTimeout = &timeout
			}
			response := session.write(wireRequest{
				OperationID:        testOperationID,
				TimeoutNanoseconds: requestTimeout,
				Frame:              []byte("payload\x00"),
			})
			if test.wantFailure != nil {
				if response.Failure == nil || *response.Failure != *test.wantFailure {
					t.Fatalf("response = %#v, want failure %q", response, *test.wantFailure)
				}
			} else if response.WrittenBytes == nil || *response.WrittenBytes != len("payload\x00") {
				t.Fatalf("success response = %#v", response)
			}
			if (session.remote != nil) != test.wantPersisted {
				t.Fatalf("remote persisted = %t, want %t", session.remote != nil, test.wantPersisted)
			}
			if test.remote != nil && !test.wantPersisted && test.remote.closeCount != 1 {
				t.Fatalf("remote closeCount = %d", test.remote.closeCount)
			}
		})
	}
}

func TestServeConnectionWritesProtocolResponsesAndCleansUp(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan struct{})
	go func() {
		serveConnection(context.Background(), server, 17)
		close(done)
	}()

	if err := writeRawWireFrame(client, []byte(`{"operationID":"`+testOperationID+`","surprise":true}`)); err != nil {
		t.Fatalf("write invalid wire payload: %v", err)
	}
	payload, err := readFrame(client)
	if err != nil {
		t.Fatalf("read invalid wire response: %v", err)
	}
	var invalid wireResponse
	if err := json.Unmarshal(payload, &invalid); err != nil {
		t.Fatalf("decode invalid response: %v", err)
	}
	if invalid.Failure == nil || *invalid.Failure != failureInvalidRequest {
		t.Fatalf("invalid response = %#v", invalid)
	}

	generationRequest := wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-42d3-a456-426614174006",
		Operation:     operationActiveSandboxGeneration,
	}
	generationPayload, err := json.Marshal(generationRequest)
	if err != nil {
		t.Fatalf("marshal generation request: %v", err)
	}
	if err := writeRawWireFrame(client, generationPayload); err != nil {
		t.Fatalf("write encoded generation request: %v", err)
	}
	responsePayload, err := readFrame(client)
	if err != nil {
		t.Fatalf("read generation response: %v", err)
	}
	var response wireResponse
	if err := json.Unmarshal(responsePayload, &response); err != nil {
		t.Fatalf("decode generation response: %v", err)
	}
	if response.SandboxGeneration == nil || *response.SandboxGeneration != 17 {
		t.Fatalf("generation response = %#v", response)
	}
	_ = client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("serveConnection did not return after peer close")
	}
}

func TestServeListenerValidatesLimitsAndReturnsOnCancellation(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	if err := serveListener(context.Background(), listener, 1, 0); err == nil {
		t.Fatal("non-positive connection limit succeeded")
	}
	_ = listener.Close()

	listener, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serveListener(ctx, listener, 1, 1) }()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		cancel()
		t.Fatalf("dial listener: %v", err)
	}
	_ = client.Close()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("cancelled listener error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("serveListener did not stop after cancellation")
	}

	sentinel := errors.New("accept failed")
	errorContext, errorCancel := context.WithCancel(context.Background())
	if err := serveListener(errorContext, failingListener{err: sentinel}, 1, 1); !errors.Is(err, sentinel) {
		errorCancel()
		t.Fatalf("accept failure = %v", err)
	}
	errorCancel()
}

func TestIsTimeoutRecognizesOnlyNetworkTimeouts(t *testing.T) {
	if !isTimeout(timeoutNetworkError{}) {
		t.Fatal("network timeout was not recognized")
	}
	if isTimeout(errors.New("ordinary error")) || isTimeout(nil) {
		t.Fatal("non-timeout was recognized as timeout")
	}
}

func failurePointer(value wireFailure) *wireFailure {
	return &value
}

func writeRawWireFrame(writer io.Writer, payload []byte) error {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	_, err := writer.Write(payload)
	return err
}

type controlledConnection struct {
	writeError     error
	writeCount     int
	deadlineErrors []error
	closeCount     int
}

func (connection *controlledConnection) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (connection *controlledConnection) Write(payload []byte) (int, error) {
	if connection.writeError != nil {
		return 0, connection.writeError
	}
	if connection.writeCount > 0 {
		return connection.writeCount, nil
	}
	return len(payload), nil
}

func (connection *controlledConnection) Close() error {
	connection.closeCount += 1
	return nil
}

func (connection *controlledConnection) LocalAddr() net.Addr { return controlledAddress("local") }

func (connection *controlledConnection) RemoteAddr() net.Addr { return controlledAddress("remote") }

func (connection *controlledConnection) SetDeadline(time.Time) error { return nil }

func (connection *controlledConnection) SetReadDeadline(time.Time) error { return nil }

func (connection *controlledConnection) SetWriteDeadline(time.Time) error {
	if len(connection.deadlineErrors) == 0 {
		return nil
	}
	err := connection.deadlineErrors[0]
	connection.deadlineErrors = connection.deadlineErrors[1:]
	return err
}

type controlledAddress string

func (address controlledAddress) Network() string { return "test" }

func (address controlledAddress) String() string { return string(address) }

type timeoutNetworkError struct{}

func (timeoutNetworkError) Error() string { return "timeout" }

func (timeoutNetworkError) Timeout() bool { return true }

func (timeoutNetworkError) Temporary() bool { return true }

type failingListener struct {
	err error
}

func (listener failingListener) Accept() (net.Conn, error) { return nil, listener.err }

func (failingListener) Close() error { return nil }

func (failingListener) Addr() net.Addr { return controlledAddress("listener") }
