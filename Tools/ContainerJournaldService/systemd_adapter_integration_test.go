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

//go:build linux && cgo && integration

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strconv"
	"testing"
	"time"
)

func TestSystemdAdapterRealJournalWriteReplayConflictAndRead(t *testing.T) {
	adapter := newSystemdJournalAdapter("")
	defer adapter.Close()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 10)
	containerID := fmt.Sprintf("%064x", uint64(time.Now().UnixNano()))
	entry := integrationEntry(containerID, "epoch-"+nonce, 1, []byte("real-journal-record"))
	identity := journalEntryIdentity{
		SessionID: "writer-" + nonce,
		Epoch:     entry.Fields[fieldLogEpoch],
		Ordinal:   1,
	}

	disposition, err := adapter.Append(t.Context(), identity, entry)
	if err != nil || disposition != appended {
		t.Fatalf("append = %v, %v", disposition, err)
	}
	disposition, err = adapter.Append(t.Context(), identity, entry)
	if err != nil || disposition != alreadyPresent {
		t.Fatalf("replay = %v, %v", disposition, err)
	}
	conflict := entry
	conflict.Message = []byte("different-message")
	if _, err := adapter.Append(t.Context(), identity, conflict); !errors.Is(err, errIdempotencyConflict) {
		t.Fatalf("identity conflict error = %v", err)
	}

	tail := 1
	open := integrationReaderOpen("static-"+nonce, containerID, false, &tail)
	checkpoint, err := adapter.PrepareReader(t.Context(), open)
	if err != nil {
		t.Fatal(err)
	}
	result, err := adapter.Read(t.Context(), open, 1, checkpoint)
	if err != nil {
		t.Fatal(err)
	}
	if result.Event.Kind != "record" || result.Event.Record == nil {
		t.Fatalf("event = %#v", result.Event)
	}
	record := result.Event.Record
	if record.Stream != "stdout" || !bytes.Equal(record.Data, []byte("real-journal-record\n")) ||
		record.Sequence != 1 || record.ProcessGeneration == nil || *record.ProcessGeneration != 7 ||
		record.Attributes["INTEGRATION_ATTRIBUTE"] != "preserved" {
		t.Fatalf("record = %#v", record)
	}
	if bytes.Equal(result.Checkpoint, checkpoint) {
		t.Fatal("record did not advance checkpoint")
	}
	end, err := adapter.Read(t.Context(), open, 2, result.Checkpoint)
	if err != nil || end.Event.Kind != "endOfStream" || !bytes.Equal(end.Checkpoint, result.Checkpoint) {
		t.Fatalf("end = %#v, %v", end, err)
	}
}

func TestSystemdAdapterRealJournalFollowAndCancel(t *testing.T) {
	adapter := newSystemdJournalAdapter("")
	defer adapter.Close()
	nonce := strconv.FormatInt(time.Now().UnixNano(), 10)
	containerID := fmt.Sprintf("%064x", uint64(time.Now().UnixNano()))
	tail := 0
	open := integrationReaderOpen("follow-"+nonce, containerID, true, &tail)
	checkpoint, err := adapter.PrepareReader(t.Context(), open)
	if err != nil {
		t.Fatal(err)
	}

	type readOutcome struct {
		result journalReadResult
		err    error
	}
	read := make(chan readOutcome, 1)
	go func() {
		result, readError := adapter.Read(t.Context(), open, 1, checkpoint)
		read <- readOutcome{result: result, err: readError}
	}()
	waitForRegisteredReader(t, adapter, open.ReaderSessionID)
	entry := integrationEntry(containerID, "epoch-"+nonce, 1, []byte("followed-record"))
	_, err = adapter.Append(t.Context(), journalEntryIdentity{
		SessionID: "writer-" + nonce,
		Epoch:     entry.Fields[fieldLogEpoch],
		Ordinal:   1,
	}, entry)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case outcome := <-read:
		if outcome.err != nil || outcome.result.Event.Kind != "record" || outcome.result.Event.Record == nil ||
			!bytes.Equal(outcome.result.Event.Record.Data, []byte("followed-record\n")) {
			t.Fatalf("follow = %#v, %v", outcome.result, outcome.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("follow did not observe appended record")
	}

	cancelOpen := integrationReaderOpen("cancel-"+nonce, containerID, true, &tail)
	cancelCheckpoint, err := adapter.PrepareReader(t.Context(), cancelOpen)
	if err != nil {
		t.Fatal(err)
	}
	canceled := make(chan error, 1)
	go func() {
		_, readError := adapter.Read(context.Background(), cancelOpen, 1, cancelCheckpoint)
		canceled <- readError
	}()
	waitForRegisteredReader(t, adapter, cancelOpen.ReaderSessionID)
	adapter.CancelReader(cancelOpen.ReaderSessionID)
	select {
	case err := <-canceled:
		if !errors.Is(err, errReaderCancelled) {
			t.Fatalf("cancel error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not interrupt blocked read")
	}
}

func integrationEntry(containerID, epoch string, ordinal uint64, message []byte) journalEntryWire {
	return journalEntryWire{
		SchemaVersion: 1,
		Message:       message,
		Priority:      6,
		Fields: map[string]string{
			fieldContainerIDFull:    containerID,
			fieldLogEpoch:           epoch,
			fieldLogOrdinal:         strconv.FormatUint(ordinal, 10),
			"INTEGRATION_ATTRIBUTE": "preserved",
		},
		SecondsSinceUnixEpoch: time.Now().Unix(),
		ProcessGeneration:     7,
	}
}

func integrationReaderOpen(sessionID, containerID string, follow bool, tail *int) readerOpenWire {
	return readerOpenWire{
		ReaderSessionID: sessionID,
		ContainerID:     containerID,
		Read: readRequestWire{
			SchemaVersion: 1,
			Stdout:        true,
			Stderr:        true,
			Follow:        follow,
			Tail:          tail,
		},
	}
}

func waitForRegisteredReader(t *testing.T, adapter *systemdJournalAdapter, sessionID string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		adapter.readersMu.Lock()
		_, found := adapter.readers[sessionID]
		adapter.readersMu.Unlock()
		if found {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("reader did not register")
}
