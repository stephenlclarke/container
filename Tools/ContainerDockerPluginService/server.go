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
	"net"
	"reflect"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	defaultMaximumConnections          = 64
	maximumCompletedReplayOperations   = 4_096
	maximumCompletedReplayEncodedBytes = 64 * 1024 * 1024
	connectionWriteTimeout             = 30 * time.Second
	connectionWatchInterval            = 100 * time.Millisecond
)

type replayOperation struct {
	request      wireRequest
	ready        chan struct{}
	response     wireResponse
	encodedBytes int
	completed    bool
	order        *list.Element
}

type protocolHandler struct {
	mu                    sync.Mutex
	backend               *durableBackend
	operations            map[string]*replayOperation
	completedOrder        *list.List
	completedEncodedBytes int
	authenticationKey     []byte
}

func newProtocolHandler(backend *durableBackend, authenticationKey []byte) *protocolHandler {
	return &protocolHandler{
		backend:           backend,
		operations:        make(map[string]*replayOperation),
		completedOrder:    list.New(),
		authenticationKey: append([]byte(nil), authenticationKey...),
	}
}

func (handler *protocolHandler) Handle(ctx context.Context, payload []byte) wireResponse {
	return handler.handle(ctx, ctx, payload)
}

func (handler *protocolHandler) handle(
	serviceContext context.Context,
	connectionContext context.Context,
	payload []byte,
) wireResponse {
	request, err := decodeWireRequest(payload, handler.backend.identity, handler.authenticationKey)
	if err != nil {
		return failed(operationIDFromInvalidPayload(payload), failureInvalidRequest)
	}
	handler.mu.Lock()
	if existing := handler.operations[request.OperationID]; existing != nil {
		if !reflect.DeepEqual(existing.request, request) {
			handler.mu.Unlock()
			return failed(request.OperationID, failureIdempotencyConflict)
		}
		if existing.completed {
			response := existing.response
			handler.mu.Unlock()
			return response
		}
		ready := existing.ready
		handler.mu.Unlock()
		select {
		case <-connectionContext.Done():
			return failed(request.OperationID, failureUnavailable)
		case <-ready:
			handler.mu.Lock()
			response := existing.response
			handler.mu.Unlock()
			return response
		}
	}
	operation := &replayOperation{request: request, ready: make(chan struct{})}
	handler.operations[request.OperationID] = operation
	handler.mu.Unlock()

	operationContext := serviceContext
	if request.Operation == operationNextReader {
		operationContext = connectionContext
	}
	response := handler.execute(operationContext, request)
	encoded, encodeErr := json.Marshal(response)
	if encodeErr != nil {
		response = failed(request.OperationID, failureInternal)
		encoded, _ = json.Marshal(response)
	}
	handler.mu.Lock()
	operation.response = response
	operation.encodedBytes = len(payload) + len(encoded)
	operation.completed = true
	operation.order = handler.completedOrder.PushBack(request.OperationID)
	handler.completedEncodedBytes += operation.encodedBytes
	close(operation.ready)
	handler.evictCompletedLocked()
	handler.mu.Unlock()
	return response
}

func (handler *protocolHandler) execute(ctx context.Context, request wireRequest) wireResponse {
	response := acknowledgement(request.OperationID)
	var err error
	switch request.Operation {
	case operationActiveSandboxGeneration:
		generation := handler.backend.generation()
		response.SandboxGeneration = &generation
	case operationMigrateHistory:
		var receipt historyMigrationReceipt
		receipt, err = handler.backend.migrateHistory(ctx, *request.HistoryMigration)
		if err == nil {
			response.HistoryMigrationReceipt = &receipt
		}
	case operationReclaimGeneration:
		err = handler.backend.reclaimGeneration(*request.GenerationReclaim)
	case operationStartWriter:
		var receipt writerReceipt
		receipt, err = handler.backend.openWriter(ctx, *request.WriterOpen)
		if err == nil {
			response.Token = receipt.Token
			response.Capabilities = &receipt.Capabilities
			response.Sequence = &receipt.Sequence
		}
	case operationReconcileWriterOpen:
		var observation writerOpenObservation
		observation, err = handler.backend.reconcileWriterOpen(*request.WriterStart)
		if err == nil {
			response.OpenObservation = &observation.Observation
			if observation.Receipt != nil {
				response.Token = observation.Receipt.Token
				response.Capabilities = &observation.Receipt.Capabilities
				response.Sequence = &observation.Receipt.Sequence
			}
		}
	case operationWriteWriter:
		err = handler.backend.writeWriter(
			ctx,
			*request.SessionID,
			request.Token,
			*request.Sequence,
			request.Frame,
		)
	case operationFlushWriter:
		err = handler.backend.flushWriter(*request.SessionID, request.Token)
	case operationFinishWriter:
		err = handler.backend.finishWriter(ctx, *request.SessionID, request.Token, *request.Fenced)
	case operationReconcileWriter:
		response.WriterObservation, response.FenceReceiptDigest, err = writerObservation(handler.backend, *request.WriterCall)
	case operationFenceWriter:
		response.WriterObservation, response.FenceReceiptDigest, err = writerObservation(handler.backend, *request.WriterCall)
		if err == nil && *response.WriterObservation != "absent" {
			err = handler.backend.finishWriter(ctx, request.WriterCall.SessionID, request.WriterCall.Token, true)
		}
		if err == nil && *response.WriterObservation != "absent" {
			response.WriterObservation, response.FenceReceiptDigest, err = writerObservation(handler.backend, *request.WriterCall)
		}
	case operationCloseWriter:
		response.WriterObservation, response.FenceReceiptDigest, err = writerObservation(handler.backend, *request.WriterCall)
		if err == nil && *response.WriterObservation != "absent" {
			err = handler.backend.finishWriter(ctx, request.WriterCall.SessionID, request.WriterCall.Token, false)
		}
		if err == nil && *response.WriterObservation != "absent" {
			response.WriterObservation, response.FenceReceiptDigest, err = writerObservation(handler.backend, *request.WriterCall)
		}
	case operationOpenReader:
		var receipt readerReceipt
		receipt, err = handler.backend.openReader(ctx, *request.ReaderOpen)
		if err == nil {
			response.Token = receipt.Token
			response.Capabilities = &receipt.Capabilities
			response.Sequence = &receipt.Sequence
		}
	case operationReconcileReaderOpen:
		var observation readerOpenObservation
		observation, err = handler.backend.reconcileReaderOpen(*request.ReaderStart)
		if err == nil {
			response.OpenObservation = &observation.Observation
			if observation.Receipt != nil {
				response.Token = observation.Receipt.Token
				response.Capabilities = &observation.Receipt.Capabilities
				response.Sequence = &observation.Receipt.Sequence
			}
		}
	case operationNextReader:
		var result readerResult
		result, err = handler.backend.nextReader(ctx, *request.SessionID, request.Token, *request.Sequence)
		if err == nil {
			response.Frame = result.Frame
			response.EndOfStream = &result.EndOfStream
		}
	case operationCancelReader:
		err = handler.backend.closeReader(*request.SessionID, request.Token)
	case operationReconcileReader:
		response.ReaderObservation, response.TerminalDigest, err = readerObservation(handler.backend, *request.ReaderCall)
	case operationCloseReader:
		response.ReaderObservation, response.TerminalDigest, err = readerObservation(handler.backend, *request.ReaderCall)
		if err == nil && *response.ReaderObservation != "absent" {
			err = handler.backend.closeReader(request.ReaderCall.ReaderSessionID, request.ReaderCall.Token)
		}
		if err == nil && *response.ReaderObservation != "absent" {
			response.ReaderObservation, response.TerminalDigest, err = readerObservation(handler.backend, *request.ReaderCall)
		}
	case operationReclaimTerminalEffect:
		err = handler.backend.reclaim(*request.Reclaim)
	default:
		err = errors.New("unsupported operation")
	}
	if err != nil {
		return failed(request.OperationID, failureForError(err))
	}
	return response
}

func writerObservation(backend *durableBackend, call writerCall) (*string, *string, error) {
	observation, digest, err := backend.writerObservation(call)
	if err != nil {
		return nil, nil, err
	}
	var digestPointer *string
	if digest != "" {
		digestPointer = &digest
	}
	return &observation, digestPointer, nil
}

func readerObservation(backend *durableBackend, call readerCall) (*string, *string, error) {
	observation, digest, err := backend.readerObservation(call)
	if err != nil {
		return nil, nil, err
	}
	var digestPointer *string
	if digest != "" {
		digestPointer = &digest
	}
	return &observation, digestPointer, nil
}

func failureForError(err error) wireFailure {
	switch {
	case errors.Is(err, errGenerationMismatch):
		return failureGenerationMismatch
	case errors.Is(err, errIdempotencyConflict):
		return failureIdempotencyConflict
	case errors.Is(err, errInvalidToken):
		return failureInvalidToken
	case errors.Is(err, errInvalidFence):
		return failureInvalidFence
	case errors.Is(err, errCapabilityMismatch):
		return failureCapabilityMismatch
	case errors.Is(err, errPluginRequestRejected):
		return failurePluginRejected
	case errors.Is(err, errUnknownSession):
		return failureUnknownSession
	case errors.Is(err, errUnavailable), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return failureUnavailable
	default:
		return failureInternal
	}
}

func operationIDFromInvalidPayload(payload []byte) string {
	var envelope struct {
		OperationID string `json:"operationID"`
	}
	if err := json.Unmarshal(payload, &envelope); err == nil && uuidPattern.MatchString(envelope.OperationID) {
		return envelope.OperationID
	}
	return "00000000-0000-0000-0000-000000000000"
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
			panic("in-flight operation entered completed order")
		}
		handler.completedEncodedBytes -= operation.encodedBytes
		delete(handler.operations, operationID)
		handler.completedOrder.Remove(oldest)
	}
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
	connectionContext, cancel := context.WithCancel(ctx)
	defer cancel()
	monitorConnectionClosure(connectionContext, cancel, connection)
	for {
		if connectionContext.Err() != nil {
			return
		}
		payload, err := readFrame(connection)
		if err != nil {
			return
		}
		if connectionContext.Err() != nil {
			return
		}
		response := handler.handle(ctx, connectionContext, payload)
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

func monitorConnectionClosure(
	ctx context.Context,
	cancel context.CancelFunc,
	connection net.Conn,
) {
	syscallConnection, ok := connection.(syscall.Conn)
	if !ok {
		return
	}
	raw, err := syscallConnection.SyscallConn()
	if err != nil {
		cancel()
		return
	}
	go func() {
		ticker := time.NewTicker(connectionWatchInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				disconnected := false
				err := raw.Control(func(descriptor uintptr) {
					poll := []unix.PollFd{{
						Fd:     int32(descriptor),
						Events: unix.POLLERR | unix.POLLHUP,
					}}
					if _, pollError := unix.Poll(poll, 0); pollError != nil ||
						poll[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
						disconnected = true
					}
				})
				if err != nil || disconnected {
					cancel()
					return
				}
			}
		}
	}()
}
