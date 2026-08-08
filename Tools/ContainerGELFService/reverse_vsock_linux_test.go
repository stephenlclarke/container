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
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/mdlayher/vsock"
)

func TestReverseVsockListenerDialsHostAndLimitsPendingConnections(t *testing.T) {
	var calls atomic.Int32
	var receivedContextID atomic.Uint32
	var receivedPort atomic.Uint32
	peers := make(chan net.Conn, 2)
	listener := newReverseVsockListener(21000, func(contextID uint32, port uint32) (net.Conn, error) {
		receivedContextID.Store(contextID)
		receivedPort.Store(port)
		calls.Add(1)
		server, client := net.Pipe()
		peers <- server
		return client, nil
	})
	defer listener.Close()

	first, err := listener.Accept()
	if err != nil {
		t.Fatalf("accept first reverse connection: %v", err)
	}
	defer first.Close()
	if calls.Load() != 1 {
		t.Fatalf("reverse dial count = %d, want 1", calls.Load())
	}
	if receivedContextID.Load() != vsock.Host || receivedPort.Load() != 21000 {
		t.Fatalf(
			"reverse VSOCK dial = (%d, %d)",
			receivedContextID.Load(),
			receivedPort.Load(),
		)
	}

	type accepted struct {
		connection net.Conn
		err        error
	}
	secondResult := make(chan accepted, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		secondResult <- accepted{connection: connection, err: acceptErr}
	}()
	select {
	case result := <-secondResult:
		if result.connection != nil {
			_ = result.connection.Close()
		}
		t.Fatalf("second reverse connection arrived before first closed: %v", result.err)
	case <-time.After(2 * reverseVsockRetryDelay):
	}
	if calls.Load() != 1 {
		t.Fatalf("reverse dial count while first active = %d, want 1", calls.Load())
	}

	if err := first.Close(); err != nil {
		t.Fatalf("close first reverse connection: %v", err)
	}
	select {
	case result := <-secondResult:
		if result.err != nil {
			t.Fatalf("accept second reverse connection: %v", result.err)
		}
		defer result.connection.Close()
	case <-time.After(time.Second):
		t.Fatal("second reverse connection did not arrive after first closed")
	}
	if calls.Load() != 2 {
		t.Fatalf("reverse dial count = %d, want 2", calls.Load())
	}
	for len(peers) > 0 {
		_ = (<-peers).Close()
	}
}

func TestReverseVsockListenerCloseUnblocksAConnectingAccept(t *testing.T) {
	attempted := make(chan struct{}, 1)
	listener := newReverseVsockListener(21000, func(uint32, uint32) (net.Conn, error) {
		select {
		case attempted <- struct{}{}:
		default:
		}
		return nil, errors.New("host listener is not ready")
	})
	done := make(chan error, 1)
	go func() {
		_, err := listener.Accept()
		done <- err
	}()
	select {
	case <-attempted:
	case <-time.After(time.Second):
		_ = listener.Close()
		t.Fatal("reverse listener did not attempt its host dial")
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close reverse listener: %v", err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("closed reverse listener accept error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("closing reverse listener did not unblock accept")
	}
}

func TestReverseVsockListenerReportsHostAddressAndRejectsAcceptAfterClose(t *testing.T) {
	listener := newReverseVsockListener(21000, func(uint32, uint32) (net.Conn, error) {
		return nil, errors.New("reverse dial should not run after close")
	})
	address, ok := listener.Addr().(*vsock.Addr)
	if !ok || address.ContextID != vsock.Host || address.Port != 21000 {
		t.Fatalf("reverse listener address = %#v", listener.Addr())
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close reverse listener: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("repeat close reverse listener: %v", err)
	}
	if _, err := listener.Accept(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("closed reverse listener accept error = %v", err)
	}
}
