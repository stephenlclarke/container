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
	"container/list"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"sync"
	"time"
)

const (
	defaultMaximumConnections          = 64
	maximumCompletedReplayOperations   = 4_096
	maximumCompletedReplayEncodedBytes = 16 * 1024 * 1024
	connectionWriteTimeout             = 30 * time.Second
)

type serviceBackend interface {
	generation() uint64
	openWriter(writerOpenWire) error
	write(context.Context, string, journalEntryWire) error
	flushWriter(context.Context, string, uint64) error
	closeWriter(context.Context, string, bool, uint64) error
	reclaimWriter(terminalReclaimWire) error
	openReader(context.Context, readerOpenWire) (uint64, error)
	nextReader(context.Context, string, uint64) (readerEventWire, error)
	cancelReader(string) error
	reclaimReader(terminalReclaimWire) error
}

type replayOperation struct {
	request      wireRequest
	ready        chan struct{}
	response     wireResponse
	requestBytes int
	encodedBytes int
	completed    bool
	orderElement *list.Element
}

type protocolHandler struct {
	mu                    sync.Mutex
	backend               serviceBackend
	operations            map[string]*replayOperation
	completedOrder        *list.List
	completedEncodedBytes int
}

func newProtocolHandler(backend serviceBackend) *protocolHandler {
	return &protocolHandler{
		backend:        backend,
		operations:     make(map[string]*replayOperation),
		completedOrder: list.New(),
	}
}

func (handler *protocolHandler) Handle(ctx context.Context, payload []byte) wireResponse {
	request, err := decodeWireRequest(payload)
	if err != nil {
		operationID := operationIDFromInvalidPayload(payload)
		if operationID == "" {
			operationID = "00000000-0000-0000-0000-000000000000"
		}
		return failureResponse(operationID, failureInvalidRequest)
	}

	handler.mu.Lock()
	if existing := handler.operations[request.OperationID]; existing != nil {
		if !reflect.DeepEqual(existing.request, request) {
			handler.mu.Unlock()
			return failureResponse(request.OperationID, failureIdempotencyConflict)
		}
		if existing.completed {
			response := existing.response
			handler.mu.Unlock()
			return response
		}
		ready := existing.ready
		handler.mu.Unlock()
		select {
		case <-ctx.Done():
			return failureResponse(request.OperationID, failureUnavailable)
		case <-ready:
			handler.mu.Lock()
			response := existing.response
			handler.mu.Unlock()
			return response
		}
	}
	operation := &replayOperation{
		request:      request,
		ready:        make(chan struct{}),
		requestBytes: len(payload),
	}
	handler.operations[request.OperationID] = operation
	handler.mu.Unlock()

	response := handler.execute(ctx, request)
	encoded, encodeError := json.Marshal(response)
	if encodeError != nil {
		response = failureResponse(request.OperationID, failureInternal)
		encoded, _ = json.Marshal(response)
	}

	handler.mu.Lock()
	operation.response = response
	operation.encodedBytes = operation.requestBytes + len(encoded)
	operation.completed = true
	operation.orderElement = handler.completedOrder.PushBack(request.OperationID)
	handler.completedEncodedBytes += operation.encodedBytes
	close(operation.ready)
	handler.evictCompletedLocked()
	handler.mu.Unlock()
	return response
}

func (handler *protocolHandler) execute(ctx context.Context, request wireRequest) wireResponse {
	response := acknowledgementResponse(request.OperationID)
	var err error
	switch request.Operation {
	case operationActiveSandboxGeneration:
		generation := handler.backend.generation()
		response.SandboxGeneration = &generation
	case operationOpenWriter:
		err = handler.backend.openWriter(*request.WriterOpen)
	case operationWrite:
		err = handler.backend.write(ctx, *request.SessionID, *request.Entry)
	case operationFlushWriter:
		err = handler.backend.flushWriter(ctx, *request.SessionID, *request.TimeoutNanoseconds)
	case operationCloseWriter:
		err = handler.backend.closeWriter(
			ctx,
			*request.SessionID,
			*request.Fenced,
			*request.TimeoutNanoseconds,
		)
	case operationReclaimWriter:
		err = handler.backend.reclaimWriter(*request.TerminalReclaim)
	case operationOpenReader:
		var sequence uint64
		sequence, err = handler.backend.openReader(ctx, *request.ReaderOpen)
		if err == nil {
			response.ReaderSequence = &sequence
		}
	case operationNextReader:
		var event readerEventWire
		event, err = handler.backend.nextReader(ctx, *request.SessionID, *request.ReaderSequence)
		if err == nil {
			response.ReaderEvent = &event
		}
	case operationCancelReader:
		err = handler.backend.cancelReader(*request.SessionID)
	case operationReclaimReader:
		err = handler.backend.reclaimReader(*request.TerminalReclaim)
	default:
		err = errors.New("unsupported operation")
	}
	if err != nil {
		return failureResponse(request.OperationID, failureForError(err))
	}
	return response
}

func (handler *protocolHandler) evictCompletedLocked() {
	for handler.completedOrder.Len() > maximumCompletedReplayOperations ||
		handler.completedEncodedBytes > maximumCompletedReplayEncodedBytes {
		oldest := handler.completedOrder.Front()
		if oldest == nil {
			return
		}
		operationID := oldest.Value.(string)
		operation := handler.operations[operationID]
		if operation == nil || !operation.completed {
			panic("in-flight operation entered completed replay order")
		}
		handler.completedEncodedBytes -= operation.encodedBytes
		delete(handler.operations, operationID)
		handler.completedOrder.Remove(oldest)
	}
}

func operationIDFromInvalidPayload(payload []byte) string {
	var envelope struct {
		OperationID string `json:"operationID"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil || !validUUID(envelope.OperationID) {
		return ""
	}
	return envelope.OperationID
}

func serveListener(ctx context.Context, listener net.Listener, handler *protocolHandler, maximumConnections int) error {
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
			var temporary interface{ Temporary() bool }
			if errors.As(err, &temporary) && temporary.Temporary() {
				continue
			}
			return err
		}
		select {
		case semaphore <- struct{}{}:
			connections.Add(1)
			go func() {
				defer connections.Done()
				defer func() { <-semaphore }()
				serveConnection(ctx, connection, handler)
			}()
		default:
			_ = connection.Close()
		}
	}
}

func serveConnection(ctx context.Context, connection net.Conn, handler *protocolHandler) {
	defer connection.Close()
	for {
		payload, err := readFrame(connection)
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				return
			}
			return
		}
		operationContext, cancelOperation := connectionOperationContext(ctx, connection)
		response := handler.Handle(operationContext, payload)
		cancelOperation()
		if err := connection.SetWriteDeadline(time.Now().Add(connectionWriteTimeout)); err != nil {
			return
		}
		if err := writeFrame(connection, response); err != nil {
			return
		}
		if err := connection.SetWriteDeadline(time.Time{}); err != nil {
			return
		}
	}
}

func protocolSnapshot(handler *protocolHandler) string {
	handler.mu.Lock()
	defer handler.mu.Unlock()
	return fmt.Sprintf(
		"operations=%d completed=%d encodedBytes=%d",
		len(handler.operations),
		handler.completedOrder.Len(),
		handler.completedEncodedBytes,
	)
}
