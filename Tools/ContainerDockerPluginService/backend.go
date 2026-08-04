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
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
)

const (
	durableSchemaVersion     = uint32(1)
	maximumWriters           = 4_096
	maximumReaders           = 4_096
	maximumHistoryMigrations = 4_096
	maximumStateBytes        = 64 * 1024 * 1024
	sessionLockStripes       = 256
)

type durableStateStore interface {
	Load() ([]byte, error)
	Save([]byte) error
}

type tokenGenerator interface {
	Generate(int) ([]byte, error)
}

type cryptoTokenGenerator struct{}

func (cryptoTokenGenerator) Generate(count int) ([]byte, error) {
	if count <= 0 || count > maximumTokenBytes {
		return nil, errors.New("invalid token size")
	}
	value := make([]byte, count)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		return nil, err
	}
	return value, nil
}

type writerPhase string

const (
	writerClaimed   writerPhase = "claimed"
	writerStarting  writerPhase = "starting"
	writerActive    writerPhase = "active"
	writerUncertain writerPhase = "uncertain"
	writerFenced    writerPhase = "fenced"
	writerClosed    writerPhase = "closed"
)

type readerPhase string

const (
	readerClaimed   readerPhase = "claimed"
	readerStarting  readerPhase = "starting"
	readerActive    readerPhase = "active"
	readerEnded     readerPhase = "ended"
	readerCancelled readerPhase = "cancelled"
	readerUncertain readerPhase = "uncertain"
)

type writerState struct {
	Open               writerOpen         `json:"open"`
	Token              []byte             `json:"token"`
	Capabilities       pluginCapabilities `json:"capabilities"`
	CapabilitiesKnown  bool               `json:"capabilitiesKnown"`
	FIFOPath           string             `json:"fifoPath,omitempty"`
	Phase              writerPhase        `json:"phase"`
	FenceReceiptDigest string             `json:"fenceReceiptDigest"`
}

type writerProgress struct {
	NextSequence       uint64
	LastSequence       *uint64
	LastFrameDigest    string
	PendingSequence    *uint64
	PendingFrameDigest string
}

type readerState struct {
	Open                  readerOpen         `json:"open"`
	Token                 []byte             `json:"token"`
	Capabilities          pluginCapabilities `json:"capabilities"`
	CapabilitiesKnown     bool               `json:"capabilitiesKnown"`
	Phase                 readerPhase        `json:"phase"`
	NextSequence          uint64             `json:"nextSequence"`
	LastSequence          *uint64            `json:"lastSequence,omitempty"`
	LastFrame             []byte             `json:"lastFrame,omitempty"`
	LastEndOfStream       bool               `json:"lastEndOfStream"`
	TerminalOutcomeDigest string             `json:"terminalOutcomeDigest"`
}

type durableSnapshot struct {
	SchemaVersion     uint32                             `json:"schemaVersion"`
	Provider          serviceIdentity                    `json:"provider"`
	Writers           map[string]writerState             `json:"writers"`
	Readers           map[string]readerState             `json:"readers"`
	HistoryMigrations map[string]historyMigrationReceipt `json:"historyMigrations"`
}

type writerReceipt struct {
	Token        []byte
	Capabilities pluginCapabilities
	Sequence     uint64
}

type readerReceipt struct {
	Token        []byte
	Capabilities pluginCapabilities
	Sequence     uint64
}

type openObservation string

const (
	observationAbsent    openObservation = "absent"
	observationPrepared  openObservation = "prepared"
	observationConflict  openObservation = "conflict"
	observationUncertain openObservation = "uncertain"
)

type writerOpenObservation struct {
	Observation openObservation
	Receipt     *writerReceipt
}

type readerOpenObservation struct {
	Observation openObservation
	Receipt     *readerReceipt
}

type readerResult struct {
	Frame       []byte
	EndOfStream bool
}

type durableBackend struct {
	identity serviceIdentity
	store    durableStateStore
	plugin   loggingPlugin
	fifos    fifoFactory
	tokens   tokenGenerator

	mu             sync.Mutex
	snapshot       durableSnapshot
	persistenceOK  bool
	writerHandles  map[string]fifoHandle
	writerProgress map[string]writerProgress
	readerStreams  map[string]pluginReadStream
	stripes        [sessionLockStripes]sync.Mutex
}

func loadDurableBackend(
	identity serviceIdentity,
	store durableStateStore,
	plugin loggingPlugin,
	fifos fifoFactory,
	tokens tokenGenerator,
) (*durableBackend, error) {
	if err := identity.validate(); err != nil {
		return nil, err
	}
	backend := &durableBackend{
		identity:       identity,
		store:          store,
		plugin:         plugin,
		fifos:          fifos,
		tokens:         tokens,
		persistenceOK:  true,
		writerHandles:  make(map[string]fifoHandle),
		writerProgress: make(map[string]writerProgress),
		readerStreams:  make(map[string]pluginReadStream),
	}
	data, err := store.Load()
	if err != nil {
		return nil, err
	}
	if data == nil {
		backend.snapshot = durableSnapshot{
			SchemaVersion:     durableSchemaVersion,
			Provider:          identity,
			Writers:           make(map[string]writerState),
			Readers:           make(map[string]readerState),
			HistoryMigrations: make(map[string]historyMigrationReceipt),
		}
		if err := backend.commit(backend.snapshot); err != nil {
			return nil, err
		}
		return backend, nil
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&backend.snapshot); err != nil {
		return nil, errCorruptState
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return nil, errCorruptState
	}
	changed := false
	if backend.snapshot.Provider.ContractDigest == "" &&
		backend.snapshot.Provider.ID == identity.ID &&
		backend.snapshot.Provider.Generation == identity.Generation &&
		backend.snapshot.Provider.SandboxGeneration == identity.SandboxGeneration {
		backend.snapshot.Provider.ContractDigest = identity.ContractDigest
		changed = true
	}
	if backend.snapshot.SchemaVersion != durableSchemaVersion ||
		backend.snapshot.Provider != identity || backend.snapshot.Writers == nil ||
		backend.snapshot.Readers == nil {
		return nil, errCorruptState
	}
	if backend.snapshot.HistoryMigrations == nil {
		backend.snapshot.HistoryMigrations = make(map[string]historyMigrationReceipt)
		changed = true
	}
	if err := backend.validateSnapshot(backend.snapshot); err != nil {
		return nil, err
	}
	for sessionID, writer := range backend.snapshot.Writers {
		if writer.Phase == writerStarting || writer.Phase == writerActive {
			writer.Phase = writerUncertain
			backend.snapshot.Writers[sessionID] = writer
			changed = true
		}
	}
	for sessionID, reader := range backend.snapshot.Readers {
		if reader.Phase == readerActive || reader.Phase == readerStarting {
			reader.Phase = readerUncertain
			backend.snapshot.Readers[sessionID] = reader
			changed = true
		}
	}
	if changed {
		if err := backend.commit(backend.snapshot); err != nil {
			return nil, err
		}
	}
	return backend, nil
}

func (backend *durableBackend) generation() uint64 {
	return backend.identity.SandboxGeneration
}

func (backend *durableBackend) migrateHistory(
	ctx context.Context,
	request historyMigrationRequest,
) (historyMigrationReceipt, error) {
	if err := request.validate(backend.identity); err != nil {
		return historyMigrationReceipt{}, err
	}
	key := historyMigrationKey(request)
	lock := backend.sessionLock(key)
	lock.Lock()
	defer lock.Unlock()

	backend.mu.Lock()
	if !backend.persistenceOK {
		backend.mu.Unlock()
		return historyMigrationReceipt{}, errUnavailable
	}
	if existing, found := backend.snapshot.HistoryMigrations[key]; found {
		backend.mu.Unlock()
		if !reflect.DeepEqual(existing.Request, request) {
			return historyMigrationReceipt{}, errIdempotencyConflict
		}
		return existing, nil
	}
	if len(backend.snapshot.HistoryMigrations) >= maximumHistoryMigrations {
		backend.mu.Unlock()
		return historyMigrationReceipt{}, errUnavailable
	}
	backend.mu.Unlock()

	capabilities, err := backend.plugin.Capabilities(ctx)
	if err != nil {
		return historyMigrationReceipt{}, err
	}
	if !capabilities.ReadLogs {
		return historyMigrationReceipt{}, errCapabilityMismatch
	}
	receipt := historyMigrationReceipt{
		SchemaVersion:         serviceSchemaVersion,
		Request:               request,
		ProviderOutcomeDigest: historyMigrationOutcomeDigest(request),
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	candidate := cloneSnapshot(backend.snapshot)
	candidate.HistoryMigrations[key] = receipt
	if err := backend.commitLocked(candidate); err != nil {
		return historyMigrationReceipt{}, err
	}
	return receipt, nil
}

func (backend *durableBackend) reclaimGeneration(
	request providerGenerationReclaim,
) error {
	if err := request.validate(backend.identity); err != nil {
		return err
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if !backend.persistenceOK {
		return errUnavailable
	}
	if len(backend.snapshot.Writers) != 0 || len(backend.snapshot.Readers) != 0 {
		return errInvalidFence
	}
	return nil
}

func (backend *durableBackend) openWriter(ctx context.Context, open writerOpen) (writerReceipt, error) {
	if err := open.validate(backend.identity); err != nil {
		return writerReceipt{}, err
	}
	lock := backend.sessionLock(open.Request.SessionID)
	lock.Lock()
	defer lock.Unlock()

	backend.mu.Lock()
	if !backend.persistenceOK {
		backend.mu.Unlock()
		return writerReceipt{}, errUnavailable
	}
	existing, found := backend.snapshot.Writers[open.Request.SessionID]
	if found && !reflect.DeepEqual(existing.Open, open) {
		backend.mu.Unlock()
		return writerReceipt{}, errIdempotencyConflict
	}
	progress, hasProgress := backend.writerProgress[open.Request.SessionID]
	if found && existing.Phase == writerActive && hasProgress && progress.PendingSequence == nil &&
		backend.writerHandles[open.Request.SessionID] != nil {
		receipt := writerReceipt{
			Token:        append([]byte(nil), existing.Token...),
			Capabilities: existing.Capabilities,
			Sequence:     progress.NextSequence,
		}
		backend.mu.Unlock()
		return receipt, nil
	}
	if !found {
		if len(backend.snapshot.Writers) >= maximumWriters {
			backend.mu.Unlock()
			return writerReceipt{}, errUnavailable
		}
		token, err := backend.tokens.Generate(32)
		if err != nil {
			backend.mu.Unlock()
			return writerReceipt{}, err
		}
		existing = writerState{
			Open:               open,
			Token:              token,
			Phase:              writerClaimed,
			FenceReceiptDigest: stableDigest("writer-fence", open.Request.SessionID, open.Request.SemanticRequestDigest),
		}
		candidate := cloneSnapshot(backend.snapshot)
		candidate.Writers[open.Request.SessionID] = existing
		if err := backend.commitLocked(candidate); err != nil {
			backend.mu.Unlock()
			return writerReceipt{}, err
		}
	}
	if existing.Phase == writerFenced || existing.Phase == writerClosed {
		receipt := writerReceipt{
			Token: append([]byte(nil), existing.Token...), Capabilities: existing.Capabilities,
			Sequence: 1,
		}
		backend.mu.Unlock()
		return receipt, nil
	}
	if existing.Phase == writerStarting || existing.Phase == writerUncertain {
		backend.mu.Unlock()
		return writerReceipt{}, errUnavailable
	}
	if existing.Phase == writerActive {
		if !hasProgress || progress.PendingSequence != nil {
			backend.mu.Unlock()
			return writerReceipt{}, errUnavailable
		}
		backend.mu.Unlock()
		if _, err := backend.writerHandle(open.Request.SessionID, open.Request.ProviderGeneration); err != nil {
			return writerReceipt{}, err
		}
		return writerReceipt{
			Token: append([]byte(nil), existing.Token...), Capabilities: existing.Capabilities,
			Sequence: progress.NextSequence,
		}, nil
	}
	backend.mu.Unlock()

	capabilities := existing.Capabilities
	if !existing.CapabilitiesKnown {
		resolved, err := backend.plugin.Capabilities(ctx)
		if err != nil {
			// Docker treats a failed optional capability handshake as legacy
			// write-only behavior.
			resolved = pluginCapabilities{ReadLogs: false}
		}
		if resolved.ReadLogs != open.ExpectedReadLogs {
			if err := backend.discardUneffectedWriter(open.Request.SessionID); err != nil {
				return writerReceipt{}, err
			}
			return writerReceipt{}, errCapabilityMismatch
		}
		capabilities = resolved
		if err := backend.updateWriter(open.Request.SessionID, func(writer *writerState) error {
			writer.Capabilities = resolved
			writer.CapabilitiesKnown = true
			return nil
		}); err != nil {
			return writerReceipt{}, err
		}
	}

	handle, err := backend.writerHandle(open.Request.SessionID, open.Request.ProviderGeneration)
	if err != nil {
		return writerReceipt{}, err
	}
	if err := backend.updateWriter(open.Request.SessionID, func(writer *writerState) error {
		if writer.FIFOPath != "" && writer.FIFOPath != handle.Path() {
			return errCorruptState
		}
		writer.FIFOPath = handle.Path()
		writer.Phase = writerStarting
		return nil
	}); err != nil {
		return writerReceipt{}, err
	}
	if err := backend.plugin.StartLogging(ctx, handle.Path(), open.Info); err != nil {
		return writerReceipt{}, err
	}
	if err := backend.updateWriter(open.Request.SessionID, func(writer *writerState) error {
		writer.Phase = writerActive
		return nil
	}); err != nil {
		return writerReceipt{}, err
	}
	backend.mu.Lock()
	backend.writerProgress[open.Request.SessionID] = writerProgress{NextSequence: 1}
	backend.mu.Unlock()
	return writerReceipt{
		Token: append([]byte(nil), existing.Token...), Capabilities: capabilities, Sequence: 1,
	}, nil
}

func (backend *durableBackend) reconcileWriterOpen(request writerStart) (writerOpenObservation, error) {
	if err := request.validate(backend.identity); err != nil {
		return writerOpenObservation{}, err
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	for _, writer := range backend.snapshot.Writers {
		comparison := compareWriterRequest(writer.Open.Request, request)
		switch comparison {
		case observationPrepared:
			progress, hasProgress := backend.writerProgress[writer.Open.Request.SessionID]
			if writer.Phase == writerClaimed || writer.Phase == writerStarting ||
				writer.Phase == writerUncertain || !hasProgress || progress.PendingSequence != nil {
				return writerOpenObservation{Observation: observationUncertain}, nil
			}
			return writerOpenObservation{
				Observation: observationPrepared,
				Receipt: &writerReceipt{
					Token:        append([]byte(nil), writer.Token...),
					Capabilities: writer.Capabilities,
					Sequence:     progress.NextSequence,
				},
			}, nil
		case observationConflict:
			return writerOpenObservation{Observation: observationConflict}, nil
		}
	}
	return writerOpenObservation{Observation: observationAbsent}, nil
}

func (backend *durableBackend) writeWriter(
	ctx context.Context,
	sessionID string,
	token []byte,
	sequence uint64,
	frame []byte,
) error {
	if !validIdentifier(sessionID) || sequence == 0 || len(frame) == 0 || len(frame) > maximumLogFrameBytes {
		return errInvalidFence
	}
	lock := backend.sessionLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	writer, err := backend.writerForToken(sessionID, token)
	if err != nil {
		return err
	}
	if writer.Phase != writerActive {
		return errInvalidFence
	}
	digest := stableDigest("writer-frame", string(frame))
	backend.mu.Lock()
	progress, found := backend.writerProgress[sessionID]
	if !found {
		backend.mu.Unlock()
		return errUnavailable
	}
	if progress.LastSequence != nil && *progress.LastSequence == sequence {
		backend.mu.Unlock()
		if progress.LastFrameDigest != digest {
			return errIdempotencyConflict
		}
		return nil
	}
	if progress.NextSequence != sequence {
		backend.mu.Unlock()
		return errInvalidFence
	}
	if progress.PendingSequence != nil {
		backend.mu.Unlock()
		if *progress.PendingSequence == sequence && progress.PendingFrameDigest == digest {
			return errUnavailable
		}
		return errIdempotencyConflict
	}
	progress.PendingSequence = &sequence
	progress.PendingFrameDigest = digest
	backend.writerProgress[sessionID] = progress
	backend.mu.Unlock()
	handle, err := backend.writerHandle(sessionID, writer.Open.Request.ProviderGeneration)
	if err != nil {
		return err
	}
	if err := handle.Write(ctx, frame); err != nil {
		return err
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	progress, found = backend.writerProgress[sessionID]
	if !found || progress.PendingSequence == nil || *progress.PendingSequence != sequence ||
		progress.PendingFrameDigest != digest || progress.NextSequence != sequence {
		return errCorruptState
	}
	if progress.NextSequence == ^uint64(0) {
		return errUnavailable
	}
	progress.LastSequence = &sequence
	progress.LastFrameDigest = digest
	progress.PendingSequence = nil
	progress.PendingFrameDigest = ""
	progress.NextSequence++
	backend.writerProgress[sessionID] = progress
	return nil
}

func (backend *durableBackend) flushWriter(sessionID string, token []byte) error {
	writer, err := backend.writerForToken(sessionID, token)
	if err != nil {
		return err
	}
	if writer.Phase != writerActive {
		return errInvalidFence
	}
	backend.mu.Lock()
	progress, hasProgress := backend.writerProgress[sessionID]
	backend.mu.Unlock()
	if !hasProgress || progress.PendingSequence != nil {
		return errUnavailable
	}
	// Each FIFO write is fully awaited, and the wire client serializes calls.
	// Observing this operation is therefore the complete service-side barrier.
	return nil
}

func (backend *durableBackend) finishWriter(ctx context.Context, sessionID string, token []byte, fenced bool) error {
	if !validIdentifier(sessionID) {
		return errInvalidFence
	}
	lock := backend.sessionLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	writer, err := backend.writerForToken(sessionID, token)
	if err != nil {
		return err
	}
	if writer.Phase == writerClosed || writer.Phase == writerFenced {
		return nil
	}
	handle, err := backend.writerHandle(sessionID, writer.Open.Request.ProviderGeneration)
	if err != nil {
		return err
	}
	if fenced {
		if err := handle.RevokeAndRemove(); err != nil {
			return err
		}
		if err := backend.updateWriter(sessionID, func(state *writerState) error {
			state.Phase = writerFenced
			return nil
		}); err != nil {
			return err
		}
		_ = backend.plugin.StopLogging(ctx, writer.FIFOPath)
		backend.mu.Lock()
		delete(backend.writerProgress, sessionID)
		backend.mu.Unlock()
		return nil
	}
	backend.mu.Lock()
	progress, hasProgress := backend.writerProgress[sessionID]
	backend.mu.Unlock()
	if !hasProgress || progress.PendingSequence != nil {
		return errUnavailable
	}
	if err := backend.plugin.StopLogging(ctx, writer.FIFOPath); err != nil {
		return err
	}
	if err := handle.CloseAndRemove(); err != nil {
		return err
	}
	return backend.updateWriter(sessionID, func(state *writerState) error {
		state.Phase = writerClosed
		return nil
	})
}

func (backend *durableBackend) writerObservation(call writerCall) (string, string, error) {
	writer, err := backend.validateWriterCall(call)
	if err != nil {
		return "", "", err
	}
	switch writer.Phase {
	case writerActive:
		backend.mu.Lock()
		progress, found := backend.writerProgress[call.SessionID]
		backend.mu.Unlock()
		if !found || progress.PendingSequence != nil {
			return "uncertain", "", nil
		}
		return "active", "", nil
	case writerClaimed, writerStarting, writerUncertain:
		return "uncertain", "", nil
	case writerFenced:
		return "writerFenced", writer.FenceReceiptDigest, nil
	case writerClosed:
		return "closed", "", nil
	default:
		return "", "", errCorruptState
	}
}

func (backend *durableBackend) openReader(ctx context.Context, open readerOpen) (readerReceipt, error) {
	if err := open.validate(backend.identity); err != nil {
		return readerReceipt{}, err
	}
	sessionID := open.Request.ReaderSessionID
	lock := backend.sessionLock(sessionID)
	lock.Lock()
	defer lock.Unlock()

	backend.mu.Lock()
	existing, found := backend.snapshot.Readers[sessionID]
	if found && !reflect.DeepEqual(existing.Open, open) {
		backend.mu.Unlock()
		return readerReceipt{}, errIdempotencyConflict
	}
	if found {
		if existing.Phase == readerUncertain || existing.Phase == readerStarting {
			backend.mu.Unlock()
			return readerReceipt{}, errUnavailable
		}
		if existing.Phase != readerClaimed {
			receipt := readerReceipt{
				Token: append([]byte(nil), existing.Token...), Capabilities: existing.Capabilities,
				Sequence: existing.NextSequence,
			}
			backend.mu.Unlock()
			return receipt, nil
		}
	} else {
		if len(backend.snapshot.Readers) >= maximumReaders {
			backend.mu.Unlock()
			return readerReceipt{}, errUnavailable
		}
		token, err := backend.tokens.Generate(32)
		if err != nil {
			backend.mu.Unlock()
			return readerReceipt{}, err
		}
		existing = readerState{
			Open: open, Token: token, Phase: readerClaimed, NextSequence: 1,
			TerminalOutcomeDigest: stableDigest("reader-terminal", sessionID, open.Request.SemanticRequestDigest),
		}
		candidate := cloneSnapshot(backend.snapshot)
		candidate.Readers[sessionID] = existing
		if err := backend.commitLocked(candidate); err != nil {
			backend.mu.Unlock()
			return readerReceipt{}, err
		}
	}
	backend.mu.Unlock()

	capabilities, err := backend.plugin.Capabilities(ctx)
	if err != nil || !capabilities.ReadLogs {
		if err := backend.discardUneffectedReader(sessionID); err != nil {
			return readerReceipt{}, err
		}
		return readerReceipt{}, errCapabilityMismatch
	}
	if err := backend.updateReader(sessionID, func(reader *readerState) error {
		reader.Capabilities = capabilities
		reader.CapabilitiesKnown = true
		reader.Phase = readerStarting
		return nil
	}); err != nil {
		return readerReceipt{}, err
	}
	stream, err := openPluginReadStream(ctx, backend.plugin, open.PluginRequest)
	if err != nil {
		return readerReceipt{}, err
	}
	backend.mu.Lock()
	backend.readerStreams[sessionID] = stream
	backend.mu.Unlock()
	if err := backend.updateReader(sessionID, func(reader *readerState) error {
		reader.Phase = readerActive
		return nil
	}); err != nil {
		_ = stream.Close()
		return readerReceipt{}, err
	}
	return readerReceipt{
		Token: append([]byte(nil), existing.Token...), Capabilities: capabilities, Sequence: 1,
	}, nil
}

func (backend *durableBackend) reconcileReaderOpen(request readerStart) (readerOpenObservation, error) {
	if err := request.validate(backend.identity); err != nil {
		return readerOpenObservation{}, err
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	for _, reader := range backend.snapshot.Readers {
		if sameReaderScope(reader.Open.Request, request) {
			if !reflect.DeepEqual(reader.Open.Request, request) {
				return readerOpenObservation{Observation: observationConflict}, nil
			}
			if reader.Phase == readerClaimed || reader.Phase == readerStarting || reader.Phase == readerUncertain {
				return readerOpenObservation{Observation: observationUncertain}, nil
			}
			return readerOpenObservation{
				Observation: observationPrepared,
				Receipt: &readerReceipt{
					Token: append([]byte(nil), reader.Token...), Capabilities: reader.Capabilities,
					Sequence: reader.NextSequence,
				},
			}, nil
		}
	}
	return readerOpenObservation{Observation: observationAbsent}, nil
}

func (backend *durableBackend) nextReader(ctx context.Context, sessionID string, token []byte, sequence uint64) (readerResult, error) {
	if !validIdentifier(sessionID) || sequence == 0 {
		return readerResult{}, errInvalidFence
	}
	lock := backend.sessionLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	reader, stream, err := backend.readerForToken(sessionID, token)
	if err != nil {
		return readerResult{}, err
	}
	if reader.LastSequence != nil && *reader.LastSequence == sequence {
		return readerResult{Frame: append([]byte(nil), reader.LastFrame...), EndOfStream: reader.LastEndOfStream}, nil
	}
	if reader.Phase != readerActive || reader.NextSequence != sequence || stream == nil {
		return readerResult{}, errUnavailable
	}
	frame, err := stream.Next(ctx)
	end := errors.Is(err, io.EOF)
	if err != nil && !end {
		return readerResult{}, err
	}
	if err := backend.updateReader(sessionID, func(state *readerState) error {
		state.LastSequence = &sequence
		state.LastFrame = append([]byte(nil), frame...)
		state.LastEndOfStream = end
		if end {
			state.Phase = readerEnded
		} else {
			state.NextSequence++
		}
		return nil
	}); err != nil {
		return readerResult{}, err
	}
	return readerResult{Frame: frame, EndOfStream: end}, nil
}

func (backend *durableBackend) closeReader(sessionID string, token []byte) error {
	lock := backend.sessionLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	reader, stream, err := backend.readerForToken(sessionID, token)
	if err != nil {
		return err
	}
	if reader.Phase == readerCancelled || reader.Phase == readerEnded {
		return nil
	}
	if stream != nil {
		_ = stream.Close()
	}
	return backend.updateReader(sessionID, func(state *readerState) error {
		state.Phase = readerCancelled
		return nil
	})
}

func (backend *durableBackend) readerObservation(call readerCall) (string, string, error) {
	reader, _, err := backend.validateReaderCall(call)
	if err != nil {
		return "", "", err
	}
	switch reader.Phase {
	case readerActive:
		return "active", "", nil
	case readerClaimed, readerUncertain:
		return "uncertain", "", nil
	case readerEnded, readerCancelled:
		return "closed", reader.TerminalOutcomeDigest, nil
	default:
		return "", "", errCorruptState
	}
}

func (backend *durableBackend) reclaim(request terminalReclaim) error {
	if request.SchemaVersion != serviceSchemaVersion ||
		request.ProviderID != backend.identity.ID ||
		request.ProviderGeneration != backend.identity.Generation ||
		!validIdentifier(request.EffectID) {
		return errInvalidFence
	}
	lock := backend.sessionLock(request.EffectID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	defer backend.mu.Unlock()
	candidate := cloneSnapshot(backend.snapshot)
	switch request.Kind {
	case "writerCandidate", "writerSession", "detachedCleanup":
		writer, found := candidate.Writers[request.EffectID]
		if !found {
			return nil
		}
		if writer.Phase != writerClosed && writer.Phase != writerFenced {
			return errInvalidFence
		}
		delete(candidate.Writers, request.EffectID)
		delete(backend.writerHandles, request.EffectID)
		delete(backend.writerProgress, request.EffectID)
	case "readerCandidate", "readerSession":
		reader, found := candidate.Readers[request.EffectID]
		if !found {
			return nil
		}
		if reader.Phase != readerEnded && reader.Phase != readerCancelled && reader.Phase != readerUncertain {
			return errInvalidFence
		}
		delete(candidate.Readers, request.EffectID)
		delete(backend.readerStreams, request.EffectID)
	default:
		return errInvalidFence
	}
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) updateWriter(sessionID string, update func(*writerState) error) error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	writer, found := backend.snapshot.Writers[sessionID]
	if !found {
		return errUnknownSession
	}
	if err := update(&writer); err != nil {
		return err
	}
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Writers[sessionID] = writer
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) updateReader(sessionID string, update func(*readerState) error) error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	reader, found := backend.snapshot.Readers[sessionID]
	if !found {
		return errUnknownSession
	}
	if err := update(&reader); err != nil {
		return err
	}
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Readers[sessionID] = reader
	return backend.commitLocked(candidate)
}

// A definitive pre-effect rejection can release its durable claim. An
// uncertain transport or plugin outcome deliberately cannot use these paths.
func (backend *durableBackend) discardUneffectedWriter(sessionID string) error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	writer, found := backend.snapshot.Writers[sessionID]
	if !found {
		return nil
	}
	if writer.Phase != writerClaimed || writer.FIFOPath != "" {
		return errInvalidFence
	}
	candidate := cloneSnapshot(backend.snapshot)
	delete(candidate.Writers, sessionID)
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) discardUneffectedReader(sessionID string) error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	reader, found := backend.snapshot.Readers[sessionID]
	if !found {
		return nil
	}
	if reader.Phase != readerClaimed || backend.readerStreams[sessionID] != nil {
		return errInvalidFence
	}
	candidate := cloneSnapshot(backend.snapshot)
	delete(candidate.Readers, sessionID)
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) writerForToken(sessionID string, token []byte) (writerState, error) {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	writer, found := backend.snapshot.Writers[sessionID]
	if !found {
		return writerState{}, errUnknownSession
	}
	if !sameToken(writer.Token, token) {
		return writerState{}, errInvalidToken
	}
	return writer, nil
}

func (backend *durableBackend) readerForToken(sessionID string, token []byte) (readerState, pluginReadStream, error) {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	reader, found := backend.snapshot.Readers[sessionID]
	if !found {
		return readerState{}, nil, errUnknownSession
	}
	if !sameToken(reader.Token, token) {
		return readerState{}, nil, errInvalidToken
	}
	return reader, backend.readerStreams[sessionID], nil
}

func (backend *durableBackend) writerHandle(sessionID string, generation uint64) (fifoHandle, error) {
	backend.mu.Lock()
	if handle := backend.writerHandles[sessionID]; handle != nil {
		backend.mu.Unlock()
		return handle, nil
	}
	backend.mu.Unlock()
	handle, err := backend.fifos.Open(sessionID, generation)
	if err != nil {
		return nil, err
	}
	backend.mu.Lock()
	if existing := backend.writerHandles[sessionID]; existing != nil {
		backend.mu.Unlock()
		_ = handle.CloseAndRemove()
		return existing, nil
	}
	backend.writerHandles[sessionID] = handle
	backend.mu.Unlock()
	return handle, nil
}

func (backend *durableBackend) validateWriterCall(call writerCall) (writerState, error) {
	if call.SchemaVersion != serviceSchemaVersion || call.ProviderID != backend.identity.ID ||
		call.ProviderGeneration != backend.identity.Generation || !validIdentifier(call.SessionID) {
		return writerState{}, errInvalidFence
	}
	writer, err := backend.writerForToken(call.SessionID, call.Token)
	if err != nil {
		return writerState{}, err
	}
	request := writer.Open.Request
	if call.ContainerID != request.ContainerID || call.LeaseGeneration != request.LeaseGeneration ||
		call.Fence.ProcessGeneration != request.CandidateProcessGeneration ||
		call.Fence.ActiveSandboxGeneration == nil ||
		*call.Fence.ActiveSandboxGeneration != *request.CandidateSandboxGeneration {
		return writerState{}, errInvalidFence
	}
	if call.Fence.Kind == "candidate" {
		if call.Fence.OperationGeneration == nil || *call.Fence.OperationGeneration != request.OperationGeneration {
			return writerState{}, errInvalidFence
		}
	} else if call.Fence.Kind != "active" || call.Fence.OperationGeneration != nil {
		return writerState{}, errInvalidFence
	}
	return writer, nil
}

func (backend *durableBackend) validateReaderCall(call readerCall) (readerState, pluginReadStream, error) {
	if call.SchemaVersion != serviceSchemaVersion || call.ProviderID != backend.identity.ID ||
		call.ProviderGeneration != backend.identity.Generation || !validIdentifier(call.ReaderSessionID) {
		return readerState{}, nil, errInvalidFence
	}
	reader, stream, err := backend.readerForToken(call.ReaderSessionID, call.Token)
	if err != nil {
		return readerState{}, nil, err
	}
	request := reader.Open.Request
	if call.ContainerID != request.ContainerID || call.LeaseGeneration != request.LeaseGeneration ||
		!reflect.DeepEqual(call.Source, request.Source) {
		return readerState{}, nil, errInvalidFence
	}
	return reader, stream, nil
}

func (backend *durableBackend) commit(snapshot durableSnapshot) error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	return backend.commitLocked(snapshot)
}

func (backend *durableBackend) commitLocked(snapshot durableSnapshot) error {
	if !backend.persistenceOK {
		return errUnavailable
	}
	if err := backend.validateSnapshot(snapshot); err != nil {
		backend.persistenceOK = false
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil || len(data) > maximumStateBytes {
		backend.persistenceOK = false
		return errCorruptState
	}
	if err := backend.store.Save(data); err != nil {
		backend.persistenceOK = false
		return err
	}
	backend.snapshot = snapshot
	return nil
}

func (backend *durableBackend) validateSnapshot(snapshot durableSnapshot) error {
	if snapshot.SchemaVersion != durableSchemaVersion || snapshot.Provider != backend.identity ||
		len(snapshot.Writers) > maximumWriters || len(snapshot.Readers) > maximumReaders ||
		snapshot.HistoryMigrations == nil || len(snapshot.HistoryMigrations) > maximumHistoryMigrations {
		return errCorruptState
	}
	for sessionID, writer := range snapshot.Writers {
		if writer.Open.Request.SessionID != sessionID || writer.Open.validate(backend.identity) != nil ||
			len(writer.Token) == 0 || len(writer.Token) > maximumTokenBytes ||
			writer.FenceReceiptDigest == "" {
			return errCorruptState
		}
		switch writer.Phase {
		case writerClaimed, writerStarting, writerActive, writerUncertain, writerFenced, writerClosed:
		default:
			return errCorruptState
		}
		if writer.Phase != writerClaimed && (!writer.CapabilitiesKnown || writer.FIFOPath == "") {
			return errCorruptState
		}
	}
	for sessionID, reader := range snapshot.Readers {
		if reader.Open.Request.ReaderSessionID != sessionID || reader.Open.validate(backend.identity) != nil ||
			len(reader.Token) == 0 || len(reader.Token) > maximumTokenBytes || reader.NextSequence == 0 ||
			reader.TerminalOutcomeDigest == "" || (reader.LastSequence == nil) != (len(reader.LastFrame) == 0 && !reader.LastEndOfStream) {
			return errCorruptState
		}
		switch reader.Phase {
		case readerClaimed, readerStarting, readerActive, readerEnded, readerCancelled, readerUncertain:
		default:
			return errCorruptState
		}
	}
	for key, receipt := range snapshot.HistoryMigrations {
		if receipt.SchemaVersion != serviceSchemaVersion ||
			receipt.Request.validate(backend.identity) != nil ||
			key != historyMigrationKey(receipt.Request) ||
			receipt.ProviderOutcomeDigest != historyMigrationOutcomeDigest(receipt.Request) {
			return errCorruptState
		}
	}
	return nil
}

func (backend *durableBackend) sessionLock(sessionID string) *sync.Mutex {
	digest := sha256.Sum256([]byte(sessionID))
	return &backend.stripes[int(digest[0])]
}

func compareWriterRequest(existing, request writerStart) openObservation {
	sameScope := existing.OperationGeneration == request.OperationGeneration &&
		existing.IdempotencyKey == request.IdempotencyKey && existing.ContainerID == request.ContainerID &&
		existing.LeaseGeneration == request.LeaseGeneration && existing.ProviderID == request.ProviderID &&
		existing.ProviderGeneration == request.ProviderGeneration
	if !sameScope {
		return observationAbsent
	}
	if reflect.DeepEqual(existing, request) {
		return observationPrepared
	}
	return observationConflict
}

func sameReaderScope(left, right readerStart) bool {
	return left.OperationGeneration == right.OperationGeneration && left.IdempotencyKey == right.IdempotencyKey &&
		left.ContainerID == right.ContainerID && left.LeaseGeneration == right.LeaseGeneration &&
		left.ProviderID == right.ProviderID && left.ProviderGeneration == right.ProviderGeneration
}

func sameToken(left, right []byte) bool {
	return len(left) == len(right) && subtle.ConstantTimeCompare(left, right) == 1
}

func stableDigest(domain string, values ...string) string {
	material := strings.Join(append([]string{domain}, values...), "\x00")
	digest := sha256.Sum256([]byte(material))
	return "sha256:" + hex.EncodeToString(digest[:])
}

func historyMigrationKey(request historyMigrationRequest) string {
	return stableDigest(
		"provider-history-migration-scope-v1",
		request.ContainerID,
		fmt.Sprint(request.TargetLeaseGeneration),
		request.ProviderID,
		fmt.Sprint(request.TargetProviderGeneration),
	)
}

func historyMigrationOutcomeDigest(request historyMigrationRequest) string {
	return stableDigest(
		"provider-history-migration-outcome-v1",
		request.ContainerID,
		fmt.Sprint(request.SourceLeaseGeneration),
		fmt.Sprint(request.TargetLeaseGeneration),
		request.ProviderID,
		fmt.Sprint(request.SourceProviderGeneration),
		fmt.Sprint(request.TargetProviderGeneration),
		request.ContractDigest,
		request.TerminalHistoryDigest,
	)
}

func cloneSnapshot(snapshot durableSnapshot) durableSnapshot {
	clone := snapshot
	clone.Writers = make(map[string]writerState, len(snapshot.Writers))
	for key, value := range snapshot.Writers {
		clone.Writers[key] = value
	}
	clone.Readers = make(map[string]readerState, len(snapshot.Readers))
	for key, value := range snapshot.Readers {
		clone.Readers[key] = value
	}
	clone.HistoryMigrations = make(
		map[string]historyMigrationReceipt,
		len(snapshot.HistoryMigrations),
	)
	for key, value := range snapshot.HistoryMigrations {
		clone.HistoryMigrations[key] = value
	}
	return clone
}

type fileStateStore struct {
	path string
}

func newFileStateStore(path string) (*fileStateStore, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) == string(filepath.Separator) {
		return nil, fmt.Errorf("unsafe state path: %q", path)
	}
	return &fileStateStore{path: filepath.Clean(path)}, nil
}

func (store *fileStateStore) Load() ([]byte, error) {
	if err := rejectSymlinkComponents(filepath.Dir(store.path)); err != nil {
		return nil, err
	}
	info, err := os.Lstat(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&0o077 != 0 || info.Size() > maximumStateBytes {
		return nil, errCorruptState
	}
	file, err := os.Open(store.path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maximumStateBytes+1))
	if err != nil || len(data) > maximumStateBytes {
		return nil, errCorruptState
	}
	return data, nil
}

func (store *fileStateStore) Save(data []byte) error {
	if len(data) > maximumStateBytes {
		return errCorruptState
	}
	parent := filepath.Dir(store.path)
	if err := os.MkdirAll(parent, 0o700); err != nil {
		return err
	}
	if err := rejectSymlinkComponents(parent); err != nil {
		return err
	}
	if err := os.Chmod(parent, 0o700); err != nil {
		return err
	}
	if info, err := os.Lstat(store.path); err == nil {
		if !info.Mode().IsRegular() {
			return errCorruptState
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temporary, err := os.CreateTemp(parent, ".docker-plugin-state-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, store.path); err != nil {
		return err
	}
	removeTemporary = false
	directory, err := os.Open(parent)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func rejectSymlinkComponents(path string) error {
	clean := filepath.Clean(path)
	volume := filepath.VolumeName(clean)
	remainder := strings.TrimPrefix(clean, volume)
	current := volume + string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(remainder, string(filepath.Separator)), string(filepath.Separator)) {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errCorruptState
		}
	}
	return nil
}
