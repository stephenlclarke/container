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
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func TestDurableWriterReconcilesAppendCrashWindow(t *testing.T) {
	t.Parallel()

	store := &memoryStateStore{}
	journal := newRecordingJournal()
	journal.failAfterAppend = true
	backend, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	open := testWriterOpen()
	if err := backend.openWriter(open); err != nil {
		t.Fatal(err)
	}
	entry := testJournalEntry(1)
	if err := backend.write(context.Background(), open.Request.SessionID, entry); !errors.Is(err, errTestAfterAppend) {
		t.Fatalf("write error = %v", err)
	}

	recovered, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := recovered.openWriter(open); err != nil {
		t.Fatal(err)
	}
	if err := recovered.write(context.Background(), open.Request.SessionID, entry); err != nil {
		t.Fatal(err)
	}
	if got := journal.entryCount(); got != 1 {
		t.Fatalf("journal entries = %d, want 1", got)
	}
	if journal.appendCalls != 2 {
		t.Fatalf("append calls = %d, want 2", journal.appendCalls)
	}
	if err := recovered.write(context.Background(), open.Request.SessionID, entry); err != nil {
		t.Fatal(err)
	}
	if journal.appendCalls != 2 {
		t.Fatalf("lost-response replay appended again: %d", journal.appendCalls)
	}
}

func TestDurableReaderPersistsCheckpointAndReplaysResponse(t *testing.T) {
	t.Parallel()

	store := &memoryStateStore{}
	journal := newRecordingJournal()
	journal.readerEvents[1] = readerEventWire{
		Kind: "record",
		Record: &readRecordWire{
			SchemaVersion:         1,
			Stream:                "stdout",
			SecondsSinceUnixEpoch: 1_700_000_000,
			Data:                  []byte("record\n"),
			Attributes:            map[string]string{},
			Sequence:              1,
			ProcessGeneration:     uint64Pointer(4),
		},
	}
	journal.readerEvents[2] = readerEventWire{Kind: "endOfStream"}
	open := testReaderOpen()
	backend, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	sequence, err := backend.openReader(context.Background(), open)
	if err != nil || sequence != 1 {
		t.Fatalf("open = %d, %v", sequence, err)
	}
	first, err := backend.nextReader(context.Background(), open.ReaderSessionID, 1)
	if err != nil || first.Kind != "record" {
		t.Fatalf("first = %#v, %v", first, err)
	}

	recovered, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	sequence, err = recovered.openReader(context.Background(), open)
	if err != nil || sequence != 2 {
		t.Fatalf("recovered open = %d, %v", sequence, err)
	}
	if _, err := recovered.nextReader(context.Background(), open.ReaderSessionID, 1); err != nil {
		t.Fatal(err)
	}
	if journal.readCalls != 1 {
		t.Fatalf("replay reached adapter: %d calls", journal.readCalls)
	}
	end, err := recovered.nextReader(context.Background(), open.ReaderSessionID, 2)
	if err != nil || end.Kind != "endOfStream" {
		t.Fatalf("end = %#v, %v", end, err)
	}
	wantCheckpoints := [][]byte{nil, []byte("checkpoint-1")}
	if !reflect.DeepEqual(journal.readCheckpoints, wantCheckpoints) {
		t.Fatalf("checkpoints = %q, want %q", journal.readCheckpoints, wantCheckpoints)
	}
}

func TestTerminalSessionsReclaimDurablyAndRejectActiveEffects(t *testing.T) {
	t.Parallel()

	store := &memoryStateStore{}
	journal := newRecordingJournal()
	journal.readerEvents[1] = readerEventWire{Kind: "endOfStream"}
	backend, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	writer := testWriterOpen()
	writerReclaim := terminalReclaimWire{
		SchemaVersion:      1,
		SessionID:          writer.Request.SessionID,
		ProviderID:         writer.Request.ProviderID,
		ProviderGeneration: writer.Request.ProviderGeneration,
	}
	if err := backend.openWriter(writer); err != nil {
		t.Fatal(err)
	}
	if err := backend.reclaimWriter(writerReclaim); !errors.Is(err, errGenerationMismatch) {
		t.Fatalf("active writer reclaim error = %v", err)
	}
	if err := backend.closeWriter(context.Background(), writer.Request.SessionID, false, 1_000); err != nil {
		t.Fatal(err)
	}
	wrongWriter := writerReclaim
	wrongWriter.ProviderID = "wrong-provider"
	if err := backend.reclaimWriter(wrongWriter); !errors.Is(err, errGenerationMismatch) {
		t.Fatalf("wrong writer reclaim error = %v", err)
	}
	if err := backend.reclaimWriter(writerReclaim); err != nil {
		t.Fatal(err)
	}
	if err := backend.reclaimWriter(writerReclaim); err != nil {
		t.Fatalf("writer reclaim replay: %v", err)
	}

	reader := testReaderOpen()
	readerReclaim := terminalReclaimWire{
		SchemaVersion:      1,
		SessionID:          reader.ReaderSessionID,
		ProviderID:         reader.ProviderID,
		ProviderGeneration: reader.ProviderGeneration,
	}
	if _, err := backend.openReader(context.Background(), reader); err != nil {
		t.Fatal(err)
	}
	if err := backend.reclaimReader(readerReclaim); !errors.Is(err, errGenerationMismatch) {
		t.Fatalf("active reader reclaim error = %v", err)
	}
	if event, err := backend.nextReader(context.Background(), reader.ReaderSessionID, 1); err != nil || event.Kind != "endOfStream" {
		t.Fatalf("terminal reader event = %#v, %v", event, err)
	}
	if err := backend.reclaimReader(readerReclaim); err != nil {
		t.Fatal(err)
	}
	if err := backend.reclaimReader(readerReclaim); err != nil {
		t.Fatalf("reader reclaim replay: %v", err)
	}

	recovered, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := recovered.openWriter(writer); err != nil {
		t.Fatal(err)
	}
	if sequence, err := recovered.openReader(context.Background(), reader); err != nil || sequence != 1 {
		t.Fatalf("reopened reader = %d, %v", sequence, err)
	}
}

func TestDurableReaderRejectsCheckpointViolations(t *testing.T) {
	t.Parallel()

	journal := newRecordingJournal()
	journal.readerEvents[1] = readerEventWire{
		Kind: "record",
		Record: &readRecordWire{
			SchemaVersion: 1,
			Stream:        "stderr",
			Data:          []byte("error\n"),
			Attributes:    map[string]string{},
			Sequence:      1,
		},
	}
	journal.stallRecordCheckpoint = true
	backend, err := loadDurableBackend(13, &memoryStateStore{}, journal)
	if err != nil {
		t.Fatal(err)
	}
	open := testReaderOpen()
	if _, err := backend.openReader(context.Background(), open); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.nextReader(context.Background(), open.ReaderSessionID, 1); !errors.Is(err, errCorruptState) {
		t.Fatalf("stalled checkpoint error = %v", err)
	}
}

func TestFileStateStoreIsPrivateAndRejectsSymlinks(t *testing.T) {
	t.Parallel()

	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "private", "state.json")
	store, err := newFileStateStore(path)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte(`{"schemaVersion":2}`)
	if err := store.Save(want); err != nil {
		t.Fatal(err)
	}
	got, err := store.Load()
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("load = %q, %v", got, err)
	}
	assertMode(t, filepath.Dir(path), 0o700)
	assertMode(t, path, 0o600)

	target := filepath.Join(root, "target.json")
	if err := os.WriteFile(target, want, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Load(); !errors.Is(err, errCorruptState) {
		t.Fatalf("symlink load error = %v", err)
	}
}

func TestSnapshotGenerationResetAndSchemaFailClosed(t *testing.T) {
	t.Parallel()

	store := &memoryStateStore{}
	journal := newRecordingJournal()
	first, err := loadDurableBackend(13, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	oldWriter := testWriterOpen()
	if err := first.openWriter(oldWriter); err != nil {
		t.Fatal(err)
	}
	next, err := loadDurableBackend(14, store, journal)
	if err != nil {
		t.Fatal(err)
	}
	if err := next.write(context.Background(), oldWriter.Request.SessionID, testJournalEntry(1)); !errors.Is(err, errUnknownSession) {
		t.Fatalf("old generation writer error = %v", err)
	}
	newWriter := oldWriter
	newGeneration := uint64(14)
	newWriter.Request.CandidateSandboxGeneration = &newGeneration
	if err := next.openWriter(newWriter); err != nil {
		t.Fatalf("new generation writer: %v", err)
	}
	store.data = []byte(`{"schemaVersion":1,"sandboxGeneration":13,"writers":{},"readers":{}}`)
	if _, err := loadDurableBackend(13, store, journal); !errors.Is(err, errCorruptState) {
		t.Fatalf("schema error = %v", err)
	}
}

func TestSessionLockRegistryIsFixedAndDomainSeparated(t *testing.T) {
	t.Parallel()

	backend, err := loadDurableBackend(13, &memoryStateStore{}, newRecordingJournal())
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index < 100_000; index++ {
		sessionID := "untrusted-session-" + strconv.Itoa(index)
		if backend.writerLock(sessionID) == nil || backend.readerLock(sessionID) == nil {
			t.Fatal("fixed lock registry returned nil")
		}
	}
	if backend.writerLock("same-session") == backend.readerLock("same-session") {
		t.Fatal("writer and reader lock domains share storage")
	}
}

type memoryStateStore struct {
	mu   sync.Mutex
	data []byte
}

func (store *memoryStateStore) Load() ([]byte, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	return cloneBytes(store.data), nil
}

func (store *memoryStateStore) Save(data []byte) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	store.data = cloneBytes(data)
	return nil
}

var errTestAfterAppend = errors.New("failure after append effect")

type recordingJournal struct {
	mu                    sync.Mutex
	entries               map[journalEntryIdentity]journalEntryWire
	readerEvents          map[uint64]readerEventWire
	readCheckpoints       [][]byte
	appendCalls           int
	readCalls             int
	failAfterAppend       bool
	stallRecordCheckpoint bool
}

func newRecordingJournal() *recordingJournal {
	return &recordingJournal{
		entries:      make(map[journalEntryIdentity]journalEntryWire),
		readerEvents: make(map[uint64]readerEventWire),
	}
}

func (journal *recordingJournal) Append(_ context.Context, identity journalEntryIdentity, entry journalEntryWire) (appendDisposition, error) {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	journal.appendCalls++
	if existing, ok := journal.entries[identity]; ok {
		if !reflect.DeepEqual(existing, entry) {
			return 0, errIdempotencyConflict
		}
		return alreadyPresent, nil
	}
	journal.entries[identity] = entry
	if journal.failAfterAppend {
		journal.failAfterAppend = false
		return appended, errTestAfterAppend
	}
	return appended, nil
}

func (journal *recordingJournal) Flush(context.Context) error { return nil }

func (journal *recordingJournal) PrepareReader(context.Context, readerOpenWire) ([]byte, error) {
	return nil, nil
}

func (journal *recordingJournal) Read(_ context.Context, _ readerOpenWire, sequence uint64, checkpoint []byte) (journalReadResult, error) {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	journal.readCalls++
	journal.readCheckpoints = append(journal.readCheckpoints, cloneBytes(checkpoint))
	event, ok := journal.readerEvents[sequence]
	if !ok {
		event = readerEventWire{Kind: "endOfStream"}
	}
	next := checkpoint
	if event.Kind == "record" && !journal.stallRecordCheckpoint {
		next = []byte("checkpoint-" + strconv.FormatUint(sequence, 10))
	}
	return journalReadResult{Event: event, Checkpoint: cloneBytes(next)}, nil
}

func (journal *recordingJournal) CancelReader(string) {}
func (journal *recordingJournal) Close() error        { return nil }

func (journal *recordingJournal) entryCount() int {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	return len(journal.entries)
}

func testWriterOpen() writerOpenWire {
	containerID := strings.Repeat("a", 64)
	generation := uint64(13)
	return writerOpenWire{
		Request: writerStartWire{
			SchemaVersion:              1,
			OperationGeneration:        1,
			IdempotencyKey:             "writer-operation",
			SemanticRequestDigest:      "sha256:writer",
			SessionID:                  "writer-session",
			ContainerID:                containerID,
			LeaseGeneration:            2,
			CandidateProcessGeneration: 4,
			ProviderID:                 "com.apple.container.logging.providers.journald",
			ProviderGeneration:         3,
			CandidateSandboxGeneration: &generation,
		},
		Configuration: configurationWire{
			SchemaVersion: 1,
			ContainerID:   containerID,
			Fields: map[string]string{
				"CONTAINER_ID":      containerID[:12],
				"CONTAINER_ID_FULL": containerID,
				"CONTAINER_TAG":     "container-name",
				"SYSLOG_IDENTIFIER": "container-name",
			},
		},
		Epoch: "epoch-1",
	}
}

func testJournalEntry(ordinal uint64) journalEntryWire {
	open := testWriterOpen()
	return journalEntryWire{
		SchemaVersion: 1,
		Message:       []byte("payload"),
		Priority:      6,
		Fields: map[string]string{
			"CONTAINER_ID_FULL":     open.Request.ContainerID,
			"CONTAINER_LOG_EPOCH":   open.Epoch,
			"CONTAINER_LOG_ORDINAL": strconv.FormatUint(ordinal, 10),
		},
		SecondsSinceUnixEpoch: 1_700_000_000,
		Nanoseconds:           123,
		ProcessGeneration:     open.Request.CandidateProcessGeneration,
	}
}

func testReaderOpen() readerOpenWire {
	return readerOpenWire{
		SchemaVersion:         1,
		OperationGeneration:   1,
		IdempotencyKey:        "reader-operation",
		SemanticRequestDigest: "sha256:reader",
		ReaderSessionID:       "reader-session",
		ContainerID:           strings.Repeat("a", 64),
		LeaseGeneration:       2,
		ProviderID:            "com.apple.container.logging.providers.journald",
		ProviderGeneration:    3,
		Source:                readerSourceWire{Kind: "stopped-container"},
		Read: readRequestWire{
			SchemaVersion: 1,
			Stdout:        true,
			Stderr:        true,
		},
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("mode for %s = %o, want %o", path, got, want)
	}
}
