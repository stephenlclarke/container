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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"
)

const (
	fieldMessage                  = "MESSAGE"
	fieldPriority                 = "PRIORITY"
	fieldContainerIDFull          = "CONTAINER_ID_FULL"
	fieldPartialMessage           = "CONTAINER_PARTIAL_MESSAGE"
	fieldLogEpoch                 = "CONTAINER_LOG_EPOCH"
	fieldLogOrdinal               = "CONTAINER_LOG_ORDINAL"
	fieldServiceSessionID         = "CONTAINER_SERVICE_SESSION_ID"
	fieldServiceEntrySHA256       = "CONTAINER_SERVICE_ENTRY_SHA256"
	fieldServiceProcessGeneration = "CONTAINER_SERVICE_PROCESS_GENERATION"
	checkpointSchemaVersion       = uint32(1)
)

type checkpointPosition string

const (
	checkpointNextCursor  checkpointPosition = "next-cursor"
	checkpointAfterCursor checkpointPosition = "after-cursor"
	checkpointRealtime    checkpointPosition = "realtime"
	checkpointEndOfStream checkpointPosition = "end-of-stream"
)

type systemdCheckpoint struct {
	SchemaVersion uint32             `json:"schemaVersion"`
	Position      checkpointPosition `json:"position"`
	Cursor        string             `json:"cursor,omitempty"`
	RealtimeUsec  uint64             `json:"realtimeUsec,omitempty"`
}

func encodeCheckpoint(checkpoint systemdCheckpoint) ([]byte, error) {
	if err := checkpoint.validate(); err != nil {
		return nil, err
	}
	data, err := json.Marshal(checkpoint)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || len(data) > maximumReaderCheckpoint {
		return nil, errCorruptState
	}
	return data, nil
}

func decodeCheckpoint(data []byte) (systemdCheckpoint, error) {
	var checkpoint systemdCheckpoint
	if len(data) == 0 || len(data) > maximumReaderCheckpoint {
		return checkpoint, errCorruptState
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&checkpoint); err != nil {
		return checkpoint, errCorruptState
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return checkpoint, errCorruptState
	}
	if err := checkpoint.validate(); err != nil {
		return checkpoint, err
	}
	return checkpoint, nil
}

func (checkpoint systemdCheckpoint) validate() error {
	if checkpoint.SchemaVersion != checkpointSchemaVersion {
		return errCorruptState
	}
	switch checkpoint.Position {
	case checkpointNextCursor, checkpointAfterCursor:
		if checkpoint.Cursor == "" || len(checkpoint.Cursor) > maximumReaderCheckpoint/2 || checkpoint.RealtimeUsec != 0 {
			return errCorruptState
		}
	case checkpointRealtime:
		if checkpoint.Cursor != "" || checkpoint.RealtimeUsec == 0 {
			return errCorruptState
		}
	case checkpointEndOfStream:
		if checkpoint.Cursor != "" || checkpoint.RealtimeUsec != 0 {
			return errCorruptState
		}
	default:
		return errCorruptState
	}
	return nil
}

func journalEntryDigest(entry journalEntryWire) (string, error) {
	payload, err := json.Marshal(entry)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:]), nil
}

func recordFromJournalFields(
	message []byte,
	fields map[string]string,
	realtimeUsec uint64,
	sequence uint64,
) (readRecordWire, error) {
	priority, err := strconv.Atoi(fields[fieldPriority])
	if err != nil {
		return readRecordWire{}, fmt.Errorf("parse journal priority: %w", err)
	}
	stream := ""
	switch priority {
	case 3:
		stream = "stderr"
	case 6:
		stream = "stdout"
	default:
		return readRecordWire{}, fmt.Errorf("unsupported journal priority: %d", priority)
	}
	processGeneration, err := strconv.ParseUint(fields[fieldServiceProcessGeneration], 10, 64)
	if err != nil || processGeneration == 0 {
		return readRecordWire{}, errors.New("invalid journal process generation")
	}
	presentation := append([]byte(nil), message...)
	if fields[fieldPartialMessage] != "true" {
		presentation = append(presentation, '\n')
	}
	attributes := make(map[string]string)
	for key, value := range fields {
		if !strings.HasPrefix(key, "_") && !wellKnownJournalFields[key] {
			attributes[key] = value
		}
	}
	seconds := int64(realtimeUsec / 1_000_000)
	nanoseconds := uint32(realtimeUsec%1_000_000) * 1_000
	return readRecordWire{
		SchemaVersion:         1,
		Stream:                stream,
		SecondsSinceUnixEpoch: seconds,
		Nanoseconds:           nanoseconds,
		Data:                  presentation,
		Attributes:            attributes,
		Sequence:              sequence,
		ProcessGeneration:     uint64Pointer(processGeneration),
	}, nil
}

func streamEnabled(request readRequestWire, stream string) bool {
	return (stream == "stdout" && request.Stdout) || (stream == "stderr" && request.Stderr)
}

func timeToRealtimeUsec(value time.Time) uint64 {
	if value.Before(time.Unix(0, 0)) {
		return 1
	}
	seconds := uint64(value.Unix())
	return seconds*1_000_000 + uint64(value.Nanosecond()/1_000)
}

var wellKnownJournalFields = map[string]bool{
	fieldMessage:                  true,
	"MESSAGE_ID":                  true,
	fieldPriority:                 true,
	"CODE_FILE":                   true,
	"CODE_LINE":                   true,
	"CODE_FUNC":                   true,
	"ERRNO":                       true,
	"SYSLOG_FACILITY":             true,
	"SYSLOG_IDENTIFIER":           true,
	"SYSLOG_PID":                  true,
	"SYSLOG_TIMESTAMP":            true,
	"CONTAINER_NAME":              true,
	"CONTAINER_ID":                true,
	fieldContainerIDFull:          true,
	"CONTAINER_TAG":               true,
	"IMAGE_NAME":                  true,
	"CONTAINER_PARTIAL_ID":        true,
	"CONTAINER_PARTIAL_ORDINAL":   true,
	"CONTAINER_PARTIAL_LAST":      true,
	fieldPartialMessage:           true,
	fieldLogEpoch:                 true,
	fieldLogOrdinal:               true,
	fieldServiceSessionID:         true,
	fieldServiceEntrySHA256:       true,
	fieldServiceProcessGeneration: true,
}
