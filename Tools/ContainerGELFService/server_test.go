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
	"io"
	"net"
	"testing"
)

func TestConnectionSessionRelaysOneExactGELFFrame(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	captured := make(chan []byte, 1)
	acceptErrors := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			acceptErrors <- err
			return
		}
		defer connection.Close()
		frame := make([]byte, 10)
		_, err = io.ReadFull(connection, frame)
		if err != nil {
			acceptErrors <- err
			return
		}
		captured <- frame
	}()

	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatalf("split listener address: %v", err)
	}
	timeout := uint64(1_000_000_000)
	session := connectionSession{sandboxGeneration: 7}
	open := session.handleRequest(context.Background(), wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        testOperationID,
		Operation:          operationOpen,
		Endpoint:           &endpoint{Host: "127.0.0.1", Port: port},
		TimeoutNanoseconds: &timeout,
	})
	if open.Failure != nil {
		t.Fatalf("open response = %#v", open)
	}
	frame := []byte{'{', '"', 'x', '"', '}', 0, 1, 2, 3, 4}
	write := session.handleRequest(context.Background(), wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        "123e4567-e89b-42d3-a456-426614174001",
		Operation:          operationWrite,
		TimeoutNanoseconds: &timeout,
		Frame:              frame,
	})
	if write.Failure != nil || write.WrittenBytes == nil || *write.WrittenBytes != len(frame) {
		t.Fatalf("write response = %#v", write)
	}
	select {
	case actual := <-captured:
		if string(actual) != string(frame) {
			t.Fatalf("captured frame = %v, want %v", actual, frame)
		}
	case err := <-acceptErrors:
		t.Fatalf("receiver: %v", err)
	}
	closeResponse := session.handleRequest(context.Background(), wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   "123e4567-e89b-42d3-a456-426614174002",
		Operation:     operationClose,
	})
	if closeResponse.Failure != nil || session.remote != nil {
		t.Fatalf("close response = %#v, remote = %v", closeResponse, session.remote)
	}
}
