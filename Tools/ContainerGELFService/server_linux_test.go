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
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestConnectionSessionDoesNotReconnectAfterLinuxTCPReset(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	resetReady := make(chan struct{})
	serverErrors := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			serverErrors <- err
			return
		}
		defer connection.Close()
		buffer := make([]byte, 6)
		if _, err := connection.Read(buffer); err != nil {
			serverErrors <- err
			return
		}
		tcp, ok := connection.(*net.TCPConn)
		if !ok {
			serverErrors <- errors.New("accepted connection is not TCP")
			return
		}
		raw, err := tcp.SyscallConn()
		if err != nil {
			serverErrors <- err
			return
		}
		if err := raw.Control(func(descriptor uintptr) {
			_ = syscall.SetsockoptLinger(
				int(descriptor),
				syscall.SOL_SOCKET,
				syscall.SO_LINGER,
				&syscall.Linger{Onoff: 1, Linger: 0},
			)
		}); err != nil {
			serverErrors <- err
			return
		}
		close(resetReady)
	}()

	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatalf("split listener address: %v", err)
	}
	timeout := uint64(time.Second)
	session := connectionSession{sandboxGeneration: 1}
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
	frame := []byte("first\x00")
	first := session.handleRequest(context.Background(), wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        "123e4567-e89b-42d3-a456-426614174001",
		Operation:          operationWrite,
		TimeoutNanoseconds: &timeout,
		Frame:              frame,
	})
	if first.Failure != nil {
		t.Fatalf("first write response = %#v", first)
	}
	select {
	case <-resetReady:
	case err := <-serverErrors:
		t.Fatalf("reset server: %v", err)
	case <-time.After(time.Second):
		t.Fatal("reset server did not receive first frame")
	}

	var failure *wireFailure
	for sequence := 2; sequence <= 16; sequence++ {
		response := session.handleRequest(context.Background(), wireRequest{
			SchemaVersion:      wireSchemaVersion,
			OperationID:        operationIDForLinuxResetTest(sequence),
			Operation:          operationWrite,
			TimeoutNanoseconds: &timeout,
			Frame:              []byte("retry\x00"),
		})
		if response.Failure != nil {
			failure = response.Failure
			break
		}
	}
	if failure == nil || *failure != failureWriteFailed {
		t.Fatalf("reset write failure = %v", failure)
	}
	if session.remote != nil {
		t.Fatal("service retained a reset remote connection")
	}

	response := session.handleRequest(context.Background(), wireRequest{
		SchemaVersion:      wireSchemaVersion,
		OperationID:        "123e4567-e89b-42d3-a456-426614174099",
		Operation:          operationWrite,
		TimeoutNanoseconds: &timeout,
		Frame:              []byte("after-reset\x00"),
	})
	if response.Failure == nil || *response.Failure != failureUnavailable {
		t.Fatalf("post-reset response = %#v", response)
	}
}

func TestOpenServiceUnixListenerIsPrivateAndCleanupIsExact(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "control.sock")
	listener, cleanup, err := openServiceListener(uint32(defaultServicePort), path, false)
	if err != nil {
		t.Fatalf("open Unix listener: %v", err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 || info.Mode().Perm() != 0o600 {
		cleanup()
		t.Fatalf("Unix listener mode = %v, %v", info, err)
	}
	cleanup()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("listener cleanup left socket: %v", err)
	}
	_ = listener

	regularPath := filepath.Join(root, "regular")
	if err := os.WriteFile(regularPath, []byte("preserve"), 0o600); err != nil {
		t.Fatalf("write regular path: %v", err)
	}
	if _, _, err := openServiceListener(uint32(defaultServicePort), regularPath, false); err == nil {
		t.Fatal("listener replaced a regular file")
	}
}

func operationIDForLinuxResetTest(sequence int) string {
	return fmt.Sprintf("123e4567-e89b-42d3-a456-%012d", sequence)
}
