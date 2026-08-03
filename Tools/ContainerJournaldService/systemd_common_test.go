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
	"reflect"
	"testing"
)

func TestSystemdCheckpointCodecIsBoundedAndStrict(t *testing.T) {
	t.Parallel()

	want := systemdCheckpoint{
		SchemaVersion: checkpointSchemaVersion,
		Position:      checkpointAfterCursor,
		Cursor:        "s=cursor;i=1",
	}
	encoded, err := encodeCheckpoint(want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeCheckpoint(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("checkpoint = %#v, want %#v", got, want)
	}
	if _, err := decodeCheckpoint([]byte(`{"schemaVersion":1,"position":"end-of-stream","extra":true}`)); err == nil {
		t.Fatal("unknown checkpoint field accepted")
	}
	if _, err := encodeCheckpoint(systemdCheckpoint{SchemaVersion: 1, Position: checkpointNextCursor}); err == nil {
		t.Fatal("empty cursor accepted")
	}
}

func TestJournalRecordProjectionMatchesDockerSemantics(t *testing.T) {
	t.Parallel()

	fields := map[string]string{
		fieldPriority:                 "3",
		fieldPartialMessage:           "true",
		fieldServiceProcessGeneration: "4",
		"USER_ATTRIBUTE":              "value",
		fieldServiceEntrySHA256:       "private",
		"_SYSTEMD_UNIT":               "private.service",
	}
	record, err := recordFromJournalFields([]byte{0x00, 0xff}, fields, 1_700_000_000_123_456, 7)
	if err != nil {
		t.Fatal(err)
	}
	if record.Stream != "stderr" || !bytes.Equal(record.Data, []byte{0x00, 0xff}) ||
		record.SecondsSinceUnixEpoch != 1_700_000_000 || record.Nanoseconds != 123_456_000 ||
		record.Sequence != 7 || record.ProcessGeneration == nil || *record.ProcessGeneration != 4 {
		t.Fatalf("unexpected record: %#v", record)
	}
	if !reflect.DeepEqual(record.Attributes, map[string]string{"USER_ATTRIBUTE": "value"}) {
		t.Fatalf("attributes = %#v", record.Attributes)
	}

	delete(fields, fieldPartialMessage)
	record, err = recordFromJournalFields([]byte("line"), fields, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(record.Data, []byte("line\n")) {
		t.Fatalf("complete message = %q", record.Data)
	}
}

func TestJournalEntryDigestIsMapOrderIndependent(t *testing.T) {
	t.Parallel()

	left := testJournalEntry(1)
	right := testJournalEntry(1)
	right.Fields = map[string]string{
		fieldLogOrdinal:      "1",
		fieldContainerIDFull: left.Fields[fieldContainerIDFull],
		fieldLogEpoch:        left.Fields[fieldLogEpoch],
	}
	leftDigest, err := journalEntryDigest(left)
	if err != nil {
		t.Fatal(err)
	}
	rightDigest, err := journalEntryDigest(right)
	if err != nil {
		t.Fatal(err)
	}
	if leftDigest != rightDigest {
		t.Fatalf("digests differ: %s != %s", leftDigest, rightDigest)
	}
}
