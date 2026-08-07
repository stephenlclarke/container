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
	"errors"
	"net"
	"sync"
	"time"
)

const connectionWriteTimeout = 30 * time.Second

type connectionSession struct {
	sandboxGeneration uint64
	remote            net.Conn
}

func serveListener(
	ctx context.Context,
	listener net.Listener,
	sandboxGeneration uint64,
	maximumConnections int,
) error {
	if maximumConnections <= 0 {
		return errors.New("maximum connections must be positive")
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	semaphore := make(chan struct{}, maximumConnections)
	var connections sync.WaitGroup
	defer connections.Wait()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		select {
		case semaphore <- struct{}{}:
			connections.Add(1)
			go func() {
				defer connections.Done()
				defer func() { <-semaphore }()
				serveConnection(ctx, connection, sandboxGeneration)
			}()
		default:
			_ = connection.Close()
		}
	}
}

func serveConnection(ctx context.Context, connection net.Conn, sandboxGeneration uint64) {
	defer connection.Close()
	session := connectionSession{sandboxGeneration: sandboxGeneration}
	defer session.closeRemote()
	for {
		payload, err := readFrame(connection)
		if err != nil || ctx.Err() != nil {
			return
		}
		response := session.handle(ctx, payload)
		if err := connection.SetWriteDeadline(time.Now().Add(connectionWriteTimeout)); err != nil {
			return
		}
		err = writeFrame(connection, response)
		clearErr := connection.SetWriteDeadline(time.Time{})
		if err != nil || clearErr != nil {
			return
		}
	}
}

func (session *connectionSession) handle(ctx context.Context, payload []byte) wireResponse {
	request, err := decodeWireRequest(payload)
	if err != nil {
		return failed(operationIDFromInvalidPayload(payload), failureInvalidRequest)
	}
	return session.handleRequest(ctx, request)
}

func (session *connectionSession) handleRequest(
	ctx context.Context,
	request wireRequest,
) wireResponse {
	switch request.Operation {
	case operationActiveSandboxGeneration:
		return generation(request.OperationID, session.sandboxGeneration)
	case operationOpen:
		return session.open(ctx, request)
	case operationWrite:
		return session.write(request)
	case operationClose:
		session.closeRemote()
		return acknowledgement(request.OperationID)
	default:
		return failed(request.OperationID, failureInvalidRequest)
	}
}

func (session *connectionSession) open(
	parent context.Context,
	request wireRequest,
) wireResponse {
	// A replacement open is explicit: it never preserves a stale connection.
	session.closeRemote()
	address, err := request.Endpoint.address()
	if err != nil {
		return failed(request.OperationID, failureInvalidRequest)
	}
	timeout, err := durationFromNanoseconds(*request.TimeoutNanoseconds)
	if err != nil {
		return failed(request.OperationID, failureInvalidRequest)
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	connection, err := (&net.Dialer{}).DialContext(ctx, "tcp", address)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || isTimeout(err) {
			return failed(request.OperationID, failureTimedOut)
		}
		return failed(request.OperationID, failureConnectionFailed)
	}
	session.remote = connection
	return acknowledgement(request.OperationID)
}

func (session *connectionSession) write(request wireRequest) wireResponse {
	if session.remote == nil {
		return failed(request.OperationID, failureUnavailable)
	}
	timeout, err := durationFromNanoseconds(*request.TimeoutNanoseconds)
	if err != nil {
		return failed(request.OperationID, failureInvalidRequest)
	}
	if err := session.remote.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		session.closeRemote()
		return failed(request.OperationID, failureInternal)
	}
	written, writeErr := session.remote.Write(request.Frame)
	clearErr := session.remote.SetWriteDeadline(time.Time{})
	if writeErr == nil && clearErr == nil && written == len(request.Frame) {
		return writeReceipt(request.OperationID, written)
	}
	session.closeRemote()
	if isTimeout(writeErr) || isTimeout(clearErr) {
		return failed(request.OperationID, failureTimedOut)
	}
	return failed(request.OperationID, failureWriteFailed)
}

func (session *connectionSession) closeRemote() {
	if session.remote == nil {
		return
	}
	remote := session.remote
	session.remote = nil
	_ = remote.Close()
}

func isTimeout(err error) bool {
	var networkError net.Error
	return err != nil && errors.As(err, &networkError) && networkError.Timeout()
}
