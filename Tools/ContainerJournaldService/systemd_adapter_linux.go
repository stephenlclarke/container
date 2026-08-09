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

//go:build linux && cgo

package main

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/coreos/go-systemd/v22/journal"
	"github.com/coreos/go-systemd/v22/sdjournal"
)

const (
	journalWaitInterval     = 250 * time.Millisecond
	appendVisibilityTimeout = 5 * time.Second
)

type activeReaderCancellation struct {
	id     uint64
	cancel context.CancelFunc
}

type systemdJournalAdapter struct {
	readDirectory string
	writeMu       sync.Mutex
	readersMu     sync.Mutex
	readers       map[string]activeReaderCancellation
	nextReaderID  uint64
	now           func() time.Time
	send          func(string, journal.Priority, map[string]string) error
}

func newSystemdJournalAdapter(readDirectory string) *systemdJournalAdapter {
	return &systemdJournalAdapter{
		readDirectory: readDirectory,
		readers:       make(map[string]activeReaderCancellation),
		now:           time.Now,
		send:          journal.Send,
	}
}

func (adapter *systemdJournalAdapter) Append(
	ctx context.Context,
	identity journalEntryIdentity,
	entry journalEntryWire,
) (appendDisposition, error) {
	adapter.writeMu.Lock()
	defer adapter.writeMu.Unlock()
	digest, err := journalEntryDigest(entry)
	if err != nil {
		return 0, err
	}
	found, err := adapter.identityExists(identity, digest)
	if err != nil {
		return 0, err
	}
	if found {
		return alreadyPresent, nil
	}
	variables := make(map[string]string, len(entry.Fields)+3)
	for key, value := range entry.Fields {
		if key != fieldMessage && key != fieldPriority {
			variables[key] = value
		}
	}
	variables[fieldServiceSessionID] = identity.SessionID
	variables[fieldServiceEntrySHA256] = digest
	variables[fieldServiceProcessGeneration] = strconv.FormatUint(entry.ProcessGeneration, 10)
	if err := adapter.send(string(entry.Message), journal.Priority(entry.Priority), variables); err != nil {
		return 0, fmt.Errorf("send journal entry: %w", err)
	}
	visibilityContext, cancel := context.WithTimeout(ctx, appendVisibilityTimeout)
	defer cancel()
	for {
		found, err = adapter.identityExists(identity, digest)
		if err != nil {
			return 0, err
		}
		if found {
			return appended, nil
		}
		timer := time.NewTimer(10 * time.Millisecond)
		select {
		case <-visibilityContext.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return 0, fmt.Errorf("journal entry visibility: %w", visibilityContext.Err())
		case <-timer.C:
		}
	}
}

func (adapter *systemdJournalAdapter) Flush(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		// Append does not complete until the exact entry is query-visible, which
		// is stronger than the Docker flush boundary needed by the authority.
		return nil
	}
}

func (adapter *systemdJournalAdapter) PrepareReader(
	ctx context.Context,
	open readerOpenWire,
) ([]byte, error) {
	anchor := adapter.now().UTC()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	journalHandle, err := adapter.openJournal(open.ContainerID)
	if err != nil {
		return nil, err
	}
	defer journalHandle.Close()

	if open.Read.Tail != nil && *open.Read.Tail == 0 {
		if !open.Read.Follow {
			return encodeCheckpoint(systemdCheckpoint{
				SchemaVersion: checkpointSchemaVersion,
				Position:      checkpointEndOfStream,
			})
		}
		if err := journalHandle.SeekTail(); err != nil {
			return nil, err
		}
		count, err := journalHandle.Previous()
		if err != nil {
			return nil, err
		}
		if count > 0 {
			cursor, err := journalHandle.GetCursor()
			if err != nil {
				return nil, err
			}
			return encodeCheckpoint(systemdCheckpoint{
				SchemaVersion: checkpointSchemaVersion,
				Position:      checkpointAfterCursor,
				Cursor:        cursor,
			})
		}
		return adapter.emptyReaderCheckpoint(open.Read, anchor)
	}

	positioned := false
	if open.Read.Tail != nil {
		if until := swiftDate(open.Read.Until); until != nil {
			if err := journalHandle.SeekRealtimeUsec(timeToRealtimeUsec(*until)); err != nil {
				return nil, err
			}
		} else if err := journalHandle.SeekTail(); err != nil {
			return nil, err
		}
		count, err := journalHandle.PreviousSkip(uint64(*open.Read.Tail))
		if err != nil {
			return nil, err
		}
		positioned = count > 0
		if positioned {
			realtimeUsec, err := journalHandle.GetRealtimeUsec()
			if err != nil {
				return nil, err
			}
			if since := swiftDate(open.Read.Since); since != nil && realtimeUsec < timeToRealtimeUsec(*since) {
				positioned, err = seekInitialHead(journalHandle, since)
				if err != nil {
					return nil, err
				}
			}
		} else {
			var err error
			positioned, err = seekInitialHead(journalHandle, swiftDate(open.Read.Since))
			if err != nil {
				return nil, err
			}
		}
	} else {
		positioned, err = seekInitialHead(journalHandle, swiftDate(open.Read.Since))
		if err != nil {
			return nil, err
		}
	}
	if !positioned {
		return adapter.emptyReaderCheckpoint(open.Read, anchor)
	}
	if until := swiftDate(open.Read.Until); until != nil {
		realtimeUsec, err := journalHandle.GetRealtimeUsec()
		if err != nil {
			return nil, err
		}
		if realtimeUsec > timeToRealtimeUsec(*until) {
			return encodeCheckpoint(systemdCheckpoint{
				SchemaVersion: checkpointSchemaVersion,
				Position:      checkpointEndOfStream,
			})
		}
	}
	cursor, err := journalHandle.GetCursor()
	if err != nil {
		return nil, err
	}
	return encodeCheckpoint(systemdCheckpoint{
		SchemaVersion: checkpointSchemaVersion,
		Position:      checkpointNextCursor,
		Cursor:        cursor,
	})
}

func (adapter *systemdJournalAdapter) Read(
	ctx context.Context,
	open readerOpenWire,
	sequence uint64,
	checkpointData []byte,
) (journalReadResult, error) {
	checkpoint, err := decodeCheckpoint(checkpointData)
	if err != nil {
		return journalReadResult{}, err
	}
	if checkpoint.Position == checkpointEndOfStream {
		return journalReadResult{
			Event:      readerEventWire{Kind: "endOfStream"},
			Checkpoint: cloneBytes(checkpointData),
		}, nil
	}
	readerContext, cancel := context.WithCancel(ctx)
	readerID := adapter.registerReader(open.ReaderSessionID, cancel)
	defer func() {
		cancel()
		adapter.unregisterReader(open.ReaderSessionID, readerID)
	}()

	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	journalHandle, err := adapter.openJournal(open.ContainerID)
	if err != nil {
		return journalReadResult{}, err
	}
	defer journalHandle.Close()
	positioned, err := seekCheckpoint(journalHandle, checkpoint)
	if err != nil {
		return journalReadResult{}, err
	}
	for {
		if err := readerContext.Err(); err != nil {
			return journalReadResult{}, errReaderCancelled
		}
		if positioned {
			realtimeUsec, err := journalHandle.GetRealtimeUsec()
			if err != nil {
				return journalReadResult{}, err
			}
			if until := swiftDate(open.Read.Until); until != nil && realtimeUsec > timeToRealtimeUsec(*until) {
				return journalReadResult{
					Event:      readerEventWire{Kind: "endOfStream"},
					Checkpoint: cloneBytes(checkpointData),
				}, nil
			}
			entry, err := journalHandle.GetEntry()
			if err != nil {
				return journalReadResult{}, err
			}
			message, err := journalHandle.GetDataValueBytes(fieldMessage)
			if err == nil {
				record, projectionError := recordFromJournalFields(
					message,
					entry.Fields,
					realtimeUsec,
					sequence,
				)
				if projectionError == nil && streamEnabled(open.Read, record.Stream) {
					checkpoint, err := encodeCheckpoint(systemdCheckpoint{
						SchemaVersion: checkpointSchemaVersion,
						Position:      checkpointAfterCursor,
						Cursor:        entry.Cursor,
					})
					if err != nil {
						return journalReadResult{}, err
					}
					return journalReadResult{
						Event: readerEventWire{
							Kind:   "record",
							Record: &record,
						},
						Checkpoint: checkpoint,
					}, nil
				}
			}
		}

		count, err := journalHandle.Next()
		if err != nil {
			return journalReadResult{}, err
		}
		if count > 0 {
			positioned = true
			continue
		}
		positioned = false
		if !open.Read.Follow {
			return journalReadResult{
				Event:      readerEventWire{Kind: "endOfStream"},
				Checkpoint: cloneBytes(checkpointData),
			}, nil
		}
		wait := journalWaitInterval
		if until := swiftDate(open.Read.Until); until != nil {
			remaining := until.Sub(adapter.now())
			if remaining <= 0 {
				return journalReadResult{
					Event:      readerEventWire{Kind: "endOfStream"},
					Checkpoint: cloneBytes(checkpointData),
				}, nil
			}
			if remaining < wait {
				wait = remaining
			}
		}
		if status := journalHandle.Wait(wait); status < 0 {
			return journalReadResult{}, errUnavailable
		}
	}
}

func (adapter *systemdJournalAdapter) CancelReader(sessionID string) {
	adapter.readersMu.Lock()
	reader, ok := adapter.readers[sessionID]
	adapter.readersMu.Unlock()
	if ok {
		reader.cancel()
	}
}

func (adapter *systemdJournalAdapter) Close() error {
	adapter.readersMu.Lock()
	readers := make([]activeReaderCancellation, 0, len(adapter.readers))
	for _, reader := range adapter.readers {
		readers = append(readers, reader)
	}
	adapter.readers = make(map[string]activeReaderCancellation)
	adapter.readersMu.Unlock()
	for _, reader := range readers {
		reader.cancel()
	}
	return nil
}

func (adapter *systemdJournalAdapter) identityExists(identity journalEntryIdentity, digest string) (bool, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	journalHandle, err := adapter.openJournal("")
	if err != nil {
		return false, err
	}
	defer journalHandle.Close()
	matches := []sdjournal.Match{
		{Field: fieldServiceSessionID, Value: identity.SessionID},
		{Field: fieldLogEpoch, Value: identity.Epoch},
		{Field: fieldLogOrdinal, Value: strconv.FormatUint(identity.Ordinal, 10)},
	}
	for _, match := range matches {
		if err := journalHandle.AddMatch(match.String()); err != nil {
			return false, err
		}
	}
	if err := journalHandle.SeekHead(); err != nil {
		return false, err
	}
	found := false
	for {
		count, err := journalHandle.Next()
		if err != nil {
			return false, err
		}
		if count == 0 {
			return found, nil
		}
		storedDigest, err := journalHandle.GetDataValue(fieldServiceEntrySHA256)
		if err != nil {
			return false, errCorruptState
		}
		if storedDigest != digest {
			return false, errIdempotencyConflict
		}
		found = true
	}
}

func (adapter *systemdJournalAdapter) openJournal(containerID string) (*sdjournal.Journal, error) {
	var (
		journalHandle *sdjournal.Journal
		err           error
	)
	if adapter.readDirectory == "" {
		journalHandle, err = sdjournal.NewJournal()
	} else {
		journalHandle, err = sdjournal.NewJournalFromDir(adapter.readDirectory)
	}
	if err != nil {
		return nil, fmt.Errorf("open system journal: %w", err)
	}
	if err := journalHandle.SetDataThreshold(0); err != nil {
		_ = journalHandle.Close()
		return nil, err
	}
	if containerID != "" {
		match := sdjournal.Match{Field: fieldContainerIDFull, Value: containerID}
		if err := journalHandle.AddMatch(match.String()); err != nil {
			_ = journalHandle.Close()
			return nil, err
		}
	}
	return journalHandle, nil
}

func (adapter *systemdJournalAdapter) emptyReaderCheckpoint(request readRequestWire, anchor time.Time) ([]byte, error) {
	if !request.Follow {
		return encodeCheckpoint(systemdCheckpoint{
			SchemaVersion: checkpointSchemaVersion,
			Position:      checkpointEndOfStream,
		})
	}
	if until := swiftDate(request.Until); until != nil && !anchor.Before(*until) {
		return encodeCheckpoint(systemdCheckpoint{
			SchemaVersion: checkpointSchemaVersion,
			Position:      checkpointEndOfStream,
		})
	}
	if since := swiftDate(request.Since); since != nil && since.After(anchor) {
		anchor = *since
	}
	return encodeCheckpoint(systemdCheckpoint{
		SchemaVersion: checkpointSchemaVersion,
		Position:      checkpointRealtime,
		RealtimeUsec:  timeToRealtimeUsec(anchor),
	})
}

func (adapter *systemdJournalAdapter) registerReader(sessionID string, cancel context.CancelFunc) uint64 {
	adapter.readersMu.Lock()
	defer adapter.readersMu.Unlock()
	adapter.nextReaderID++
	id := adapter.nextReaderID
	if existing, ok := adapter.readers[sessionID]; ok {
		existing.cancel()
	}
	adapter.readers[sessionID] = activeReaderCancellation{id: id, cancel: cancel}
	return id
}

func (adapter *systemdJournalAdapter) unregisterReader(sessionID string, id uint64) {
	adapter.readersMu.Lock()
	defer adapter.readersMu.Unlock()
	if existing, ok := adapter.readers[sessionID]; ok && existing.id == id {
		delete(adapter.readers, sessionID)
	}
}

func seekInitialHead(journalHandle *sdjournal.Journal, since *time.Time) (bool, error) {
	if since == nil {
		if err := journalHandle.SeekHead(); err != nil {
			return false, err
		}
	} else if err := journalHandle.SeekRealtimeUsec(timeToRealtimeUsec(*since)); err != nil {
		return false, err
	}
	count, err := journalHandle.Next()
	return count > 0, err
}

func seekCheckpoint(journalHandle *sdjournal.Journal, checkpoint systemdCheckpoint) (bool, error) {
	switch checkpoint.Position {
	case checkpointNextCursor:
		if err := journalHandle.SeekCursor(checkpoint.Cursor); err != nil {
			return false, err
		}
		count, err := journalHandle.Next()
		if err != nil || count == 0 {
			return false, errCorruptState
		}
		cursor, err := journalHandle.GetCursor()
		if err != nil || cursor != checkpoint.Cursor {
			return false, errCorruptState
		}
		return true, nil
	case checkpointAfterCursor:
		if err := journalHandle.SeekCursor(checkpoint.Cursor); err != nil {
			return false, err
		}
		count, err := journalHandle.Next()
		if err != nil || count == 0 {
			return false, errCorruptState
		}
		cursor, err := journalHandle.GetCursor()
		if err != nil || cursor != checkpoint.Cursor {
			return false, errCorruptState
		}
		count, err = journalHandle.Next()
		return count > 0, err
	case checkpointRealtime:
		if err := journalHandle.SeekRealtimeUsec(checkpoint.RealtimeUsec); err != nil {
			return false, err
		}
		count, err := journalHandle.Next()
		return count > 0, err
	default:
		return false, errors.New("invalid readable checkpoint")
	}
}
