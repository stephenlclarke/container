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
	"encoding/json"
	"strconv"
	"testing"
)

func BenchmarkProtocolGenerationReplay(b *testing.B) {
	request, err := json.Marshal(wireRequest{
		SchemaVersion: wireSchemaVersion,
		OperationID:   testOperationID,
		Operation:     operationActiveSandboxGeneration,
	})
	if err != nil {
		b.Fatal(err)
	}
	handler := newProtocolHandler(&recordingServiceBackend{generationValue: 13})
	if response := handler.Handle(b.Context(), request); response.Failure != nil {
		b.Fatalf("initial request failed: %#v", response)
	}
	b.ReportAllocs()
	b.SetBytes(int64(len(request)))
	b.ResetTimer()
	for range b.N {
		if response := handler.Handle(b.Context(), request); response.Failure != nil {
			b.Fatalf("replay failed: %#v", response)
		}
	}
}

func BenchmarkDurableWriter(b *testing.B) {
	backend, err := loadDurableBackend(13, &memoryStateStore{}, newRecordingJournal())
	if err != nil {
		b.Fatal(err)
	}
	open := testWriterOpen()
	if err := backend.openWriter(open); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.SetBytes(int64(len(testJournalEntry(1).Message)))
	b.ResetTimer()
	for index := 1; index <= b.N; index++ {
		entry := testJournalEntry(uint64(index))
		entry.Message = []byte("payload-" + strconv.Itoa(index))
		if err := backend.write(b.Context(), open.Request.SessionID, entry); err != nil {
			b.Fatal(err)
		}
	}
}
