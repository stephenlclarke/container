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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	durableSchemaVersion = uint32(2)
	maximumWriters       = 4_096
	maximumReaders       = 4_096
	maximumStateBytes    = 64 * 1024 * 1024
	sessionLockStripes   = 256
)

var (
	errGenerationMismatch  = errors.New("generation mismatch")
	errIdempotencyConflict = errors.New("idempotency conflict")
	errUnknownSession      = errors.New("unknown session")
	errDeadlineExceeded    = errors.New("deadline exceeded")
	errUnavailable         = errors.New("service unavailable")
	errCorruptState        = errors.New("corrupt durable state")
	errReaderCancelled     = errors.New("reader cancelled")
)

type journalEntryIdentity struct {
	SessionID string `json:"sessionID"`
	Epoch     string `json:"epoch"`
	Ordinal   uint64 `json:"ordinal"`
}

type appendDisposition int

const (
	appended appendDisposition = iota
	alreadyPresent
)

type journalReadResult struct {
	Event      readerEventWire
	Checkpoint []byte
}

type journalAdapter interface {
	Append(context.Context, journalEntryIdentity, journalEntryWire) (appendDisposition, error)
	Flush(context.Context) error
	PrepareReader(context.Context, readerOpenWire) ([]byte, error)
	Read(context.Context, readerOpenWire, uint64, []byte) (journalReadResult, error)
	CancelReader(string)
	Close() error
}

type durableStateStore interface {
	Load() ([]byte, error)
	Save([]byte) error
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
	if !info.Mode().IsRegular() || info.Size() > maximumStateBytes {
		return nil, errCorruptState
	}
	file, err := os.Open(store.path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maximumStateBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maximumStateBytes {
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
	if err := ensurePrivateDirectoryMode(parent); err != nil {
		return err
	}
	if info, err := os.Lstat(store.path); err == nil {
		if !info.Mode().IsRegular() {
			return errCorruptState
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	temporary, err := os.CreateTemp(parent, ".journald-state-*")
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
	if err := ensurePrivateOpenFileMode(temporary, 0o600); err != nil {
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

func ensurePrivateDirectoryMode(path string) error {
	return ensurePrivateDirectoryModeWith(path, os.Chmod)
}

func ensurePrivateDirectoryModeWith(
	path string,
	chmod func(string, os.FileMode) error,
) error {
	_ = chmod(path, 0o700)
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 ||
		info.Mode().Perm() != 0o700 {
		return errCorruptState
	}
	return nil
}

func ensurePrivateOpenFileMode(file *os.File, mode os.FileMode) error {
	return ensurePrivateOpenFileModeWith(file, mode, file.Chmod)
}

func ensurePrivateOpenFileModeWith(
	file *os.File,
	mode os.FileMode,
	chmod func(os.FileMode) error,
) error {
	_ = chmod(mode)
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		return errCorruptState
	}
	return nil
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

type writerPhase string

const (
	writerActive writerPhase = "active"
	writerFenced writerPhase = "fenced"
	writerClosed writerPhase = "closed"
)

type readerPhase string

const (
	readerActive    readerPhase = "active"
	readerEnded     readerPhase = "ended"
	readerCancelled readerPhase = "cancelled"
)

type pendingEntry struct {
	Identity journalEntryIdentity `json:"identity"`
	Entry    journalEntryWire     `json:"entry"`
}

type writerState struct {
	Open          writerOpenWire `json:"open"`
	Phase         writerPhase    `json:"phase"`
	CloseFenced   *bool          `json:"closeFenced,omitempty"`
	NextOrdinal   uint64         `json:"nextOrdinal"`
	Pending       *pendingEntry  `json:"pending,omitempty"`
	LastCommitted *pendingEntry  `json:"lastCommitted,omitempty"`
}

type readerState struct {
	Open         readerOpenWire   `json:"open"`
	Phase        readerPhase      `json:"phase"`
	NextSequence uint64           `json:"nextSequence"`
	Checkpoint   []byte           `json:"checkpoint,omitempty"`
	LastSequence *uint64          `json:"lastSequence,omitempty"`
	LastEvent    *readerEventWire `json:"lastEvent,omitempty"`
}

type durableSnapshot struct {
	SchemaVersion     uint32                 `json:"schemaVersion"`
	SandboxGeneration uint64                 `json:"sandboxGeneration"`
	Writers           map[string]writerState `json:"writers"`
	Readers           map[string]readerState `json:"readers"`
}

type durableBackend struct {
	mu                sync.Mutex
	sandboxGeneration uint64
	store             durableStateStore
	journal           journalAdapter
	snapshot          durableSnapshot
	persistenceFailed bool
	writerLocks       [sessionLockStripes]sync.Mutex
	readerLocks       [sessionLockStripes]sync.Mutex
}

func loadDurableBackend(generation uint64, store durableStateStore, journal journalAdapter) (*durableBackend, error) {
	if generation == 0 {
		return nil, errGenerationMismatch
	}
	data, err := store.Load()
	if err != nil {
		return nil, err
	}
	var snapshot durableSnapshot
	if data == nil {
		snapshot = durableSnapshot{
			SchemaVersion:     durableSchemaVersion,
			SandboxGeneration: generation,
			Writers:           make(map[string]writerState),
			Readers:           make(map[string]readerState),
		}
		encoded, err := encodeSnapshot(snapshot)
		if err != nil {
			return nil, err
		}
		if err := store.Save(encoded); err != nil {
			return nil, err
		}
	} else {
		decoder := json.NewDecoder(strings.NewReader(string(data)))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&snapshot); err != nil {
			return nil, errCorruptState
		}
		if err := requireJSONEnd(decoder); err != nil {
			return nil, errCorruptState
		}
		if snapshot.SchemaVersion != durableSchemaVersion {
			return nil, errCorruptState
		}
		if err := validateSnapshot(snapshot); err != nil {
			return nil, err
		}
		if snapshot.SandboxGeneration != generation {
			snapshot = durableSnapshot{
				SchemaVersion:     durableSchemaVersion,
				SandboxGeneration: generation,
				Writers:           make(map[string]writerState),
				Readers:           make(map[string]readerState),
			}
			encoded, err := encodeSnapshot(snapshot)
			if err != nil {
				return nil, err
			}
			if err := store.Save(encoded); err != nil {
				return nil, err
			}
		}
	}
	return &durableBackend{
		sandboxGeneration: generation,
		store:             store,
		journal:           journal,
		snapshot:          snapshot,
	}, nil
}

func (backend *durableBackend) generation() uint64 {
	return backend.sandboxGeneration
}

func (backend *durableBackend) openWriter(open writerOpenWire) error {
	lock := backend.writerLock(open.Request.SessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return err
	}
	if open.Request.CandidateSandboxGeneration == nil ||
		*open.Request.CandidateSandboxGeneration != backend.sandboxGeneration {
		return errGenerationMismatch
	}
	if existing, ok := backend.snapshot.Writers[open.Request.SessionID]; ok {
		if !reflect.DeepEqual(existing.Open, open) {
			return errIdempotencyConflict
		}
		return nil
	}
	if len(backend.snapshot.Writers) >= maximumWriters {
		return errUnavailable
	}
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Writers[open.Request.SessionID] = writerState{
		Open:        open,
		Phase:       writerActive,
		NextOrdinal: 1,
	}
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) write(ctx context.Context, sessionID string, entry journalEntryWire) error {
	lock := backend.writerLock(sessionID)
	lock.Lock()
	defer lock.Unlock()

	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return err
	}
	writer, ok := backend.snapshot.Writers[sessionID]
	if !ok {
		backend.mu.Unlock()
		return errUnknownSession
	}
	if writer.Phase != writerActive {
		backend.mu.Unlock()
		return errGenerationMismatch
	}
	identity, err := entryIdentity(sessionID, entry, writer.Open)
	if err != nil {
		backend.mu.Unlock()
		return err
	}
	pending := pendingEntry{Identity: identity, Entry: entry}
	if writer.LastCommitted != nil && identity.Ordinal == writer.LastCommitted.Identity.Ordinal {
		if !reflect.DeepEqual(*writer.LastCommitted, pending) {
			backend.mu.Unlock()
			return errIdempotencyConflict
		}
		backend.mu.Unlock()
		return nil
	}
	if writer.Pending != nil {
		if !reflect.DeepEqual(*writer.Pending, pending) {
			backend.mu.Unlock()
			return errIdempotencyConflict
		}
	} else {
		if identity.Ordinal != writer.NextOrdinal {
			backend.mu.Unlock()
			return errIdempotencyConflict
		}
		writer.Pending = &pending
		candidate := cloneSnapshot(backend.snapshot)
		candidate.Writers[sessionID] = writer
		if err := backend.commitLocked(candidate); err != nil {
			backend.mu.Unlock()
			return err
		}
	}
	backend.mu.Unlock()

	if _, err := backend.journal.Append(ctx, identity, entry); err != nil {
		return err
	}

	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return err
	}
	writer, ok = backend.snapshot.Writers[sessionID]
	if !ok || writer.Pending == nil || !reflect.DeepEqual(*writer.Pending, pending) {
		return errCorruptState
	}
	if identity.Ordinal == ^uint64(0) {
		return errIdempotencyConflict
	}
	writer.Pending = nil
	writer.LastCommitted = &pending
	writer.NextOrdinal = identity.Ordinal + 1
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Writers[sessionID] = writer
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) flushWriter(ctx context.Context, sessionID string, timeout uint64) error {
	lock := backend.writerLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return err
	}
	writer, ok := backend.snapshot.Writers[sessionID]
	backend.mu.Unlock()
	if !ok {
		return errUnknownSession
	}
	if writer.Phase != writerActive || writer.Pending != nil {
		return errGenerationMismatch
	}
	flushContext, cancel := context.WithTimeout(ctx, nanosecondDuration(timeout))
	defer cancel()
	if err := backend.journal.Flush(flushContext); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return errDeadlineExceeded
		}
		return err
	}
	return nil
}

func (backend *durableBackend) closeWriter(ctx context.Context, sessionID string, fenced bool, timeout uint64) error {
	lock := backend.writerLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return err
	}
	writer, ok := backend.snapshot.Writers[sessionID]
	if !ok {
		backend.mu.Unlock()
		return errUnknownSession
	}
	if writer.Pending != nil {
		backend.mu.Unlock()
		return errIdempotencyConflict
	}
	if writer.Phase == writerClosed {
		if writer.CloseFenced == nil || *writer.CloseFenced != fenced {
			backend.mu.Unlock()
			return errIdempotencyConflict
		}
		backend.mu.Unlock()
		return nil
	}
	if writer.CloseFenced != nil && *writer.CloseFenced != fenced {
		backend.mu.Unlock()
		return errIdempotencyConflict
	}
	if writer.CloseFenced == nil {
		writer.Phase = writerFenced
		writer.CloseFenced = boolPointer(fenced)
		candidate := cloneSnapshot(backend.snapshot)
		candidate.Writers[sessionID] = writer
		if err := backend.commitLocked(candidate); err != nil {
			backend.mu.Unlock()
			return err
		}
	}
	backend.mu.Unlock()

	flushContext, cancel := context.WithTimeout(ctx, nanosecondDuration(timeout))
	defer cancel()
	if err := backend.journal.Flush(flushContext); err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return errDeadlineExceeded
		}
		return err
	}

	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return err
	}
	writer = backend.snapshot.Writers[sessionID]
	writer.Phase = writerClosed
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Writers[sessionID] = writer
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) reclaimWriter(reclaim terminalReclaimWire) error {
	lock := backend.writerLock(reclaim.SessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return err
	}
	writer, ok := backend.snapshot.Writers[reclaim.SessionID]
	if !ok {
		return nil
	}
	if writer.Phase != writerClosed || writer.Pending != nil ||
		writer.Open.Request.ProviderID != reclaim.ProviderID ||
		writer.Open.Request.ProviderGeneration != reclaim.ProviderGeneration ||
		writer.Open.Request.CandidateSandboxGeneration == nil ||
		*writer.Open.Request.CandidateSandboxGeneration != backend.sandboxGeneration {
		return errGenerationMismatch
	}
	candidate := cloneSnapshot(backend.snapshot)
	delete(candidate.Writers, reclaim.SessionID)
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) openReader(ctx context.Context, open readerOpenWire) (uint64, error) {
	lock := backend.readerLock(open.ReaderSessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return 0, err
	}
	if existing, ok := backend.snapshot.Readers[open.ReaderSessionID]; ok {
		if !reflect.DeepEqual(existing.Open, open) {
			backend.mu.Unlock()
			return 0, errIdempotencyConflict
		}
		backend.mu.Unlock()
		return existing.NextSequence, nil
	}
	if err := backend.validateNewReaderSourceLocked(open); err != nil {
		backend.mu.Unlock()
		return 0, err
	}
	if len(backend.snapshot.Readers) >= maximumReaders {
		backend.mu.Unlock()
		return 0, errUnavailable
	}
	backend.mu.Unlock()

	checkpoint, err := backend.journal.PrepareReader(ctx, open)
	if err != nil {
		return 0, err
	}
	if len(checkpoint) > maximumReaderCheckpoint {
		return 0, errCorruptState
	}

	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return 0, err
	}
	if existing, ok := backend.snapshot.Readers[open.ReaderSessionID]; ok {
		if !reflect.DeepEqual(existing.Open, open) {
			return 0, errIdempotencyConflict
		}
		return existing.NextSequence, nil
	}
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Readers[open.ReaderSessionID] = readerState{
		Open:         open,
		Phase:        readerActive,
		NextSequence: 1,
		Checkpoint:   cloneBytes(checkpoint),
	}
	if err := backend.commitLocked(candidate); err != nil {
		return 0, err
	}
	return 1, nil
}

func (backend *durableBackend) nextReader(ctx context.Context, sessionID string, sequence uint64) (readerEventWire, error) {
	lock := backend.readerLock(sessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return readerEventWire{}, err
	}
	reader, ok := backend.snapshot.Readers[sessionID]
	if !ok {
		backend.mu.Unlock()
		return readerEventWire{}, errUnknownSession
	}
	if reader.LastSequence != nil && *reader.LastSequence == sequence && reader.LastEvent != nil {
		event := *reader.LastEvent
		backend.mu.Unlock()
		return event, nil
	}
	if reader.Phase != readerActive || reader.NextSequence != sequence {
		backend.mu.Unlock()
		return readerEventWire{}, errIdempotencyConflict
	}
	checkpoint := cloneBytes(reader.Checkpoint)
	open := reader.Open
	backend.mu.Unlock()

	result, err := backend.journal.Read(ctx, open, sequence, checkpoint)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, errReaderCancelled) {
			return readerEventWire{}, errReaderCancelled
		}
		return readerEventWire{}, err
	}
	if len(result.Checkpoint) > maximumReaderCheckpoint {
		return readerEventWire{}, errCorruptState
	}

	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return readerEventWire{}, err
	}
	current, ok := backend.snapshot.Readers[sessionID]
	if !ok {
		return readerEventWire{}, errUnknownSession
	}
	if current.Phase == readerCancelled {
		return readerEventWire{}, errReaderCancelled
	}
	if current.LastSequence != nil && *current.LastSequence == sequence && current.LastEvent != nil {
		return *current.LastEvent, nil
	}
	if current.Phase != readerActive || current.NextSequence != sequence ||
		!bytesEqual(current.Checkpoint, checkpoint) {
		return readerEventWire{}, errIdempotencyConflict
	}
	current.LastSequence = uint64Pointer(sequence)
	current.LastEvent = &result.Event
	switch result.Event.Kind {
	case "record":
		if result.Event.Record == nil || len(result.Checkpoint) == 0 || bytesEqual(result.Checkpoint, checkpoint) || sequence == ^uint64(0) {
			return readerEventWire{}, errCorruptState
		}
		current.Checkpoint = cloneBytes(result.Checkpoint)
		current.NextSequence = sequence + 1
	case "endOfStream":
		if result.Event.Record != nil || !bytesEqual(result.Checkpoint, checkpoint) {
			return readerEventWire{}, errCorruptState
		}
		current.Phase = readerEnded
	default:
		return readerEventWire{}, errCorruptState
	}
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Readers[sessionID] = current
	if err := backend.commitLocked(candidate); err != nil {
		return readerEventWire{}, err
	}
	return result.Event, nil
}

func (backend *durableBackend) cancelReader(sessionID string) error {
	backend.mu.Lock()
	if err := backend.requireHealthyLocked(); err != nil {
		backend.mu.Unlock()
		return err
	}
	reader, ok := backend.snapshot.Readers[sessionID]
	if !ok {
		backend.mu.Unlock()
		return errUnknownSession
	}
	if reader.Phase != readerActive {
		backend.mu.Unlock()
		return nil
	}
	reader.Phase = readerCancelled
	candidate := cloneSnapshot(backend.snapshot)
	candidate.Readers[sessionID] = reader
	if err := backend.commitLocked(candidate); err != nil {
		backend.mu.Unlock()
		return err
	}
	backend.mu.Unlock()
	backend.journal.CancelReader(sessionID)
	return nil
}

func (backend *durableBackend) reclaimReader(reclaim terminalReclaimWire) error {
	lock := backend.readerLock(reclaim.SessionID)
	lock.Lock()
	defer lock.Unlock()
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if err := backend.requireHealthyLocked(); err != nil {
		return err
	}
	reader, ok := backend.snapshot.Readers[reclaim.SessionID]
	if !ok {
		return nil
	}
	if (reader.Phase != readerEnded && reader.Phase != readerCancelled) ||
		reader.Open.ProviderID != reclaim.ProviderID ||
		reader.Open.ProviderGeneration != reclaim.ProviderGeneration {
		return errGenerationMismatch
	}
	candidate := cloneSnapshot(backend.snapshot)
	delete(candidate.Readers, reclaim.SessionID)
	return backend.commitLocked(candidate)
}

func (backend *durableBackend) validateNewReaderSourceLocked(open readerOpenWire) error {
	if open.Source.Kind != "active-writer" {
		return nil
	}
	if open.Source.ActiveSandboxGeneration == nil ||
		*open.Source.ActiveSandboxGeneration != backend.sandboxGeneration ||
		open.Source.SessionID == nil || open.Source.WriterProviderID == nil ||
		open.Source.WriterProviderGeneration == nil || open.Source.ActiveProcessGeneration == nil {
		return errGenerationMismatch
	}
	writer, ok := backend.snapshot.Writers[*open.Source.SessionID]
	if !ok || writer.Phase != writerActive ||
		writer.Open.Request.ContainerID != open.ContainerID ||
		writer.Open.Request.LeaseGeneration != open.LeaseGeneration ||
		writer.Open.Request.ProviderID != *open.Source.WriterProviderID ||
		writer.Open.Request.ProviderGeneration != *open.Source.WriterProviderGeneration ||
		writer.Open.Request.CandidateProcessGeneration != *open.Source.ActiveProcessGeneration {
		return errGenerationMismatch
	}
	return nil
}

func (backend *durableBackend) requireHealthyLocked() error {
	if backend.persistenceFailed {
		return errCorruptState
	}
	return nil
}

func (backend *durableBackend) commitLocked(candidate durableSnapshot) error {
	if backend.persistenceFailed {
		return errCorruptState
	}
	if err := validateSnapshot(candidate); err != nil {
		backend.persistenceFailed = true
		return err
	}
	data, err := encodeSnapshot(candidate)
	if err != nil {
		backend.persistenceFailed = true
		return err
	}
	if err := backend.store.Save(data); err != nil {
		backend.persistenceFailed = true
		return err
	}
	backend.snapshot = candidate
	return nil
}

func (backend *durableBackend) writerLock(sessionID string) *sync.Mutex {
	return &backend.writerLocks[sessionLockStripe(sessionID)]
}

func (backend *durableBackend) readerLock(sessionID string) *sync.Mutex {
	return &backend.readerLocks[sessionLockStripe(sessionID)]
}

func sessionLockStripe(sessionID string) uint32 {
	hash := uint32(2_166_136_261)
	for index := range len(sessionID) {
		hash ^= uint32(sessionID[index])
		hash *= 16_777_619
	}
	return hash % sessionLockStripes
}

func entryIdentity(sessionID string, entry journalEntryWire, open writerOpenWire) (journalEntryIdentity, error) {
	ordinal, err := strconv.ParseUint(entry.Fields["CONTAINER_LOG_ORDINAL"], 10, 64)
	if err != nil || ordinal == 0 || ordinal == ^uint64(0) ||
		entry.Fields["CONTAINER_ID_FULL"] != open.Configuration.ContainerID ||
		entry.Fields["CONTAINER_LOG_EPOCH"] != open.Epoch ||
		entry.ProcessGeneration != open.Request.CandidateProcessGeneration {
		return journalEntryIdentity{}, errIdempotencyConflict
	}
	return journalEntryIdentity{SessionID: sessionID, Epoch: open.Epoch, Ordinal: ordinal}, nil
}

func validateSnapshot(snapshot durableSnapshot) error {
	if snapshot.SchemaVersion != durableSchemaVersion || snapshot.SandboxGeneration == 0 ||
		len(snapshot.Writers) > maximumWriters || len(snapshot.Readers) > maximumReaders {
		return errCorruptState
	}
	for sessionID, writer := range snapshot.Writers {
		if sessionID != writer.Open.Request.SessionID || writer.NextOrdinal == 0 ||
			(writer.Phase == writerActive) != (writer.CloseFenced == nil) ||
			(writer.Phase != writerActive && writer.Pending != nil) {
			return errCorruptState
		}
		if writer.Pending != nil {
			identity, err := entryIdentity(sessionID, writer.Pending.Entry, writer.Open)
			if err != nil || identity != writer.Pending.Identity || identity.Ordinal != writer.NextOrdinal {
				return errCorruptState
			}
		}
		if writer.LastCommitted == nil {
			if writer.NextOrdinal != 1 {
				return errCorruptState
			}
		} else {
			identity, err := entryIdentity(sessionID, writer.LastCommitted.Entry, writer.Open)
			if err != nil || identity != writer.LastCommitted.Identity || identity.Ordinal == ^uint64(0) ||
				identity.Ordinal+1 != writer.NextOrdinal {
				return errCorruptState
			}
		}
	}
	for sessionID, reader := range snapshot.Readers {
		if sessionID != reader.Open.ReaderSessionID || reader.NextSequence == 0 ||
			(reader.LastSequence == nil) != (reader.LastEvent == nil) || len(reader.Checkpoint) > maximumReaderCheckpoint {
			return errCorruptState
		}
		if reader.LastSequence == nil {
			if reader.Phase == readerEnded || reader.NextSequence != 1 {
				return errCorruptState
			}
			continue
		}
		switch reader.LastEvent.Kind {
		case "record":
			if reader.LastEvent.Record == nil || *reader.LastSequence == ^uint64(0) ||
				*reader.LastSequence+1 != reader.NextSequence || reader.Phase == readerEnded || len(reader.Checkpoint) == 0 {
				return errCorruptState
			}
		case "endOfStream":
			if reader.LastEvent.Record != nil || reader.NextSequence != *reader.LastSequence || reader.Phase != readerEnded {
				return errCorruptState
			}
		default:
			return errCorruptState
		}
	}
	return nil
}

func encodeSnapshot(snapshot durableSnapshot) ([]byte, error) {
	data, err := json.Marshal(snapshot)
	if err != nil {
		return nil, err
	}
	if len(data) > maximumStateBytes {
		return nil, errCorruptState
	}
	return data, nil
}

func cloneSnapshot(snapshot durableSnapshot) durableSnapshot {
	data, err := json.Marshal(snapshot)
	if err != nil {
		panic(err)
	}
	var clone durableSnapshot
	if err := json.Unmarshal(data, &clone); err != nil {
		panic(err)
	}
	return clone
}

func nanosecondDuration(value uint64) time.Duration {
	if value > uint64(^uint64(0)>>1) {
		return time.Duration(^uint64(0) >> 1)
	}
	return time.Duration(value)
}

func boolPointer(value bool) *bool       { return &value }
func uint64Pointer(value uint64) *uint64 { return &value }
func cloneBytes(value []byte) []byte     { return append([]byte(nil), value...) }
func bytesEqual(left, right []byte) bool { return reflect.DeepEqual(left, right) }

func failureForError(err error) wireFailure {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, errGenerationMismatch):
		return failureGenerationMismatch
	case errors.Is(err, errIdempotencyConflict):
		return failureIdempotencyConflict
	case errors.Is(err, errUnknownSession):
		return failureUnknownSession
	case errors.Is(err, errDeadlineExceeded), errors.Is(err, context.DeadlineExceeded):
		return failureDeadlineExceeded
	case errors.Is(err, errUnavailable), errors.Is(err, errReaderCancelled), errors.Is(err, context.Canceled):
		return failureUnavailable
	default:
		return failureInternal
	}
}
