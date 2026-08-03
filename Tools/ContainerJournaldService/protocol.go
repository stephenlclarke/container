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
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"reflect"
	"strings"
	"time"
)

const (
	wireSchemaVersion       = uint32(1)
	maximumFrameBytes       = 1 * 1024 * 1024
	maximumIdentifierBytes  = 256
	maximumEpochBytes       = 128
	maximumFieldCount       = 256
	maximumFieldBytes       = 512 * 1024
	maximumMessageBytes     = 512 * 1024
	maximumReadTail         = 100_000
	maximumReaderCheckpoint = 64 * 1024
)

type wireOperation string

const (
	operationActiveSandboxGeneration wireOperation = "activeSandboxGeneration"
	operationOpenWriter              wireOperation = "openWriter"
	operationWrite                   wireOperation = "write"
	operationFlushWriter             wireOperation = "flushWriter"
	operationCloseWriter             wireOperation = "closeWriter"
	operationOpenReader              wireOperation = "openReader"
	operationNextReader              wireOperation = "nextReader"
	operationCancelReader            wireOperation = "cancelReader"
)

type wireFailure string

const (
	failureInvalidRequest      wireFailure = "invalidRequest"
	failureGenerationMismatch  wireFailure = "generationMismatch"
	failureIdempotencyConflict wireFailure = "idempotencyConflict"
	failureUnknownSession      wireFailure = "unknownSession"
	failureDeadlineExceeded    wireFailure = "deadlineExceeded"
	failureUnavailable         wireFailure = "unavailable"
	failureInternal            wireFailure = "internalFailure"
)

type wireRequest struct {
	SchemaVersion      uint32            `json:"schemaVersion"`
	OperationID        string            `json:"operationID"`
	Operation          wireOperation     `json:"operation"`
	WriterOpen         *writerOpenWire   `json:"writerOpen,omitempty"`
	SessionID          *string           `json:"sessionID,omitempty"`
	Entry              *journalEntryWire `json:"entry,omitempty"`
	TimeoutNanoseconds *uint64           `json:"timeoutNanoseconds,omitempty"`
	Fenced             *bool             `json:"fenced,omitempty"`
	ReaderOpen         *readerOpenWire   `json:"readerOpen,omitempty"`
	ReaderSequence     *uint64           `json:"readerSequence,omitempty"`
}

type writerOpenWire struct {
	Request       writerStartWire   `json:"request"`
	Configuration configurationWire `json:"configuration"`
	Epoch         string            `json:"epoch"`
}

type writerStartWire struct {
	SchemaVersion              uint32  `json:"schemaVersion"`
	OperationGeneration        uint64  `json:"operationGeneration"`
	IdempotencyKey             string  `json:"idempotencyKey"`
	SemanticRequestDigest      string  `json:"semanticRequestDigest"`
	SessionID                  string  `json:"sessionID"`
	ContainerID                string  `json:"containerID"`
	LeaseGeneration            uint64  `json:"leaseGeneration"`
	CandidateProcessGeneration uint64  `json:"candidateProcessGeneration"`
	ProviderID                 string  `json:"providerID"`
	ProviderGeneration         uint64  `json:"providerGeneration"`
	CandidateSandboxGeneration *uint64 `json:"candidateSandboxGeneration,omitempty"`
}

type configurationWire struct {
	SchemaVersion uint32            `json:"schemaVersion"`
	ContainerID   string            `json:"containerID"`
	Fields        map[string]string `json:"fields"`
}

type journalEntryWire struct {
	SchemaVersion         uint32            `json:"schemaVersion"`
	Message               []byte            `json:"message"`
	Priority              int               `json:"priority"`
	Fields                map[string]string `json:"fields"`
	SecondsSinceUnixEpoch int64             `json:"secondsSinceUnixEpoch"`
	Nanoseconds           uint32            `json:"nanoseconds"`
	ProcessGeneration     uint64            `json:"processGeneration"`
}

type readerOpenWire struct {
	SchemaVersion         uint32           `json:"schemaVersion"`
	OperationGeneration   uint64           `json:"operationGeneration"`
	IdempotencyKey        string           `json:"idempotencyKey"`
	SemanticRequestDigest string           `json:"semanticRequestDigest"`
	ReaderSessionID       string           `json:"readerSessionID"`
	ContainerID           string           `json:"containerID"`
	LeaseGeneration       uint64           `json:"leaseGeneration"`
	ProviderID            string           `json:"providerID"`
	ProviderGeneration    uint64           `json:"providerGeneration"`
	Source                readerSourceWire `json:"source"`
	Read                  readRequestWire  `json:"read"`
}

type readerSourceWire struct {
	Kind                     string  `json:"kind"`
	SessionID                *string `json:"sessionID,omitempty"`
	WriterProviderID         *string `json:"writerProviderID,omitempty"`
	WriterProviderGeneration *uint64 `json:"writerProviderGeneration,omitempty"`
	ActiveProcessGeneration  *uint64 `json:"activeProcessGeneration,omitempty"`
	ActiveSandboxGeneration  *uint64 `json:"activeSandboxGeneration,omitempty"`
}

type readRequestWire struct {
	SchemaVersion uint32   `json:"schemaVersion"`
	Stdout        bool     `json:"stdout"`
	Stderr        bool     `json:"stderr"`
	Follow        bool     `json:"follow"`
	Tail          *int     `json:"tail,omitempty"`
	Since         *float64 `json:"since,omitempty"`
	Until         *float64 `json:"until,omitempty"`
	Timestamps    bool     `json:"timestamps"`
	Details       bool     `json:"details"`
}

type wireResponse struct {
	SchemaVersion     uint32           `json:"schemaVersion"`
	OperationID       string           `json:"operationID"`
	SandboxGeneration *uint64          `json:"sandboxGeneration,omitempty"`
	ReaderSequence    *uint64          `json:"readerSequence,omitempty"`
	ReaderEvent       *readerEventWire `json:"readerEvent,omitempty"`
	Failure           *wireFailure     `json:"failure,omitempty"`
}

type readerEventWire struct {
	Kind   string          `json:"kind"`
	Record *readRecordWire `json:"record,omitempty"`
}

type readRecordWire struct {
	SchemaVersion         uint32            `json:"schemaVersion"`
	Stream                string            `json:"stream"`
	SecondsSinceUnixEpoch int64             `json:"secondsSinceUnixEpoch"`
	Nanoseconds           uint32            `json:"nanoseconds"`
	Data                  []byte            `json:"data"`
	Attributes            map[string]string `json:"attributes"`
	Sequence              uint64            `json:"sequence"`
	ProcessGeneration     *uint64           `json:"processGeneration,omitempty"`
}

func acknowledgementResponse(operationID string) wireResponse {
	return wireResponse{SchemaVersion: wireSchemaVersion, OperationID: operationID}
}

func failureResponse(operationID string, failure wireFailure) wireResponse {
	return wireResponse{
		SchemaVersion: wireSchemaVersion,
		OperationID:   operationID,
		Failure:       &failure,
	}
}

func decodeWireRequest(payload []byte) (wireRequest, error) {
	var request wireRequest
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, fmt.Errorf("decode request: %w", err)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return request, err
	}
	if err := request.validate(); err != nil {
		return request, err
	}
	return request, nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var extra json.RawMessage
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("decode trailing data: %w", err)
	}
	return errors.New("multiple JSON values in frame")
}

func (request wireRequest) validate() error {
	if request.SchemaVersion != wireSchemaVersion || !validUUID(request.OperationID) {
		return errors.New("invalid request identity")
	}
	if request.SessionID != nil && !validIdentifier(*request.SessionID) {
		return errors.New("invalid session ID")
	}
	present := func(value any) bool {
		if value == nil {
			return false
		}
		return !reflect.ValueOf(value).IsNil()
	}
	switch request.Operation {
	case operationActiveSandboxGeneration:
		if present(request.WriterOpen) || present(request.SessionID) ||
			present(request.Entry) || present(request.TimeoutNanoseconds) ||
			present(request.Fenced) || present(request.ReaderOpen) ||
			present(request.ReaderSequence) {
			return errors.New("generation request contains payload")
		}
	case operationOpenWriter:
		if request.WriterOpen == nil || present(request.SessionID) ||
			present(request.Entry) || present(request.TimeoutNanoseconds) ||
			present(request.Fenced) || present(request.ReaderOpen) ||
			present(request.ReaderSequence) {
			return errors.New("invalid open-writer payload")
		}
		if err := request.WriterOpen.validate(); err != nil {
			return err
		}
	case operationWrite:
		if request.SessionID == nil || request.Entry == nil ||
			present(request.WriterOpen) || present(request.TimeoutNanoseconds) ||
			present(request.Fenced) || present(request.ReaderOpen) ||
			present(request.ReaderSequence) {
			return errors.New("invalid write payload")
		}
		if err := request.Entry.validate(); err != nil {
			return err
		}
	case operationFlushWriter:
		if request.SessionID == nil || request.TimeoutNanoseconds == nil ||
			*request.TimeoutNanoseconds == 0 || present(request.WriterOpen) ||
			present(request.Entry) || present(request.Fenced) ||
			present(request.ReaderOpen) || present(request.ReaderSequence) {
			return errors.New("invalid flush-writer payload")
		}
	case operationCloseWriter:
		if request.SessionID == nil || request.TimeoutNanoseconds == nil ||
			*request.TimeoutNanoseconds == 0 || request.Fenced == nil ||
			present(request.WriterOpen) || present(request.Entry) ||
			present(request.ReaderOpen) || present(request.ReaderSequence) {
			return errors.New("invalid close-writer payload")
		}
	case operationOpenReader:
		if request.ReaderOpen == nil || present(request.WriterOpen) ||
			present(request.SessionID) || present(request.Entry) ||
			present(request.TimeoutNanoseconds) || present(request.Fenced) ||
			present(request.ReaderSequence) {
			return errors.New("invalid open-reader payload")
		}
		if err := request.ReaderOpen.validate(); err != nil {
			return err
		}
	case operationNextReader:
		if request.SessionID == nil || request.ReaderSequence == nil ||
			*request.ReaderSequence == 0 || present(request.WriterOpen) ||
			present(request.Entry) || present(request.TimeoutNanoseconds) ||
			present(request.Fenced) || present(request.ReaderOpen) {
			return errors.New("invalid next-reader payload")
		}
	case operationCancelReader:
		if request.SessionID == nil || present(request.WriterOpen) ||
			present(request.Entry) || present(request.TimeoutNanoseconds) ||
			present(request.Fenced) || present(request.ReaderOpen) ||
			present(request.ReaderSequence) {
			return errors.New("invalid cancel-reader payload")
		}
	default:
		return errors.New("unknown operation")
	}
	return nil
}

func (open writerOpenWire) validate() error {
	request := open.Request
	configuration := open.Configuration
	if request.SchemaVersion != 1 || configuration.SchemaVersion != 1 ||
		request.OperationGeneration == 0 || request.LeaseGeneration == 0 ||
		request.CandidateProcessGeneration == 0 || request.ProviderGeneration == 0 ||
		request.CandidateSandboxGeneration == nil || *request.CandidateSandboxGeneration == 0 ||
		!validIdentifier(request.IdempotencyKey) ||
		!validIdentifier(request.SemanticRequestDigest) ||
		!validIdentifier(request.SessionID) || !validIdentifier(request.ContainerID) ||
		!validIdentifier(request.ProviderID) || configuration.ContainerID != request.ContainerID ||
		len(open.Epoch) == 0 || len(open.Epoch) > maximumEpochBytes {
		return errors.New("invalid writer open")
	}
	if err := validateFields(configuration.Fields); err != nil {
		return err
	}
	if configuration.Fields["CONTAINER_ID_FULL"] != request.ContainerID ||
		configuration.Fields["CONTAINER_ID"] != truncateBytes(request.ContainerID, 12) ||
		configuration.Fields["CONTAINER_TAG"] == "" ||
		configuration.Fields["SYSLOG_IDENTIFIER"] == "" {
		return errors.New("invalid writer configuration")
	}
	return nil
}

func (entry journalEntryWire) validate() error {
	if entry.SchemaVersion != 1 || len(entry.Message) > maximumMessageBytes ||
		(entry.Priority != 3 && entry.Priority != 6) || entry.Nanoseconds >= 1_000_000_000 ||
		entry.ProcessGeneration == 0 || entry.Fields["CONTAINER_ID_FULL"] == "" ||
		entry.Fields["CONTAINER_LOG_EPOCH"] == "" || entry.Fields["CONTAINER_LOG_ORDINAL"] == "" {
		return errors.New("invalid journal entry")
	}
	return validateFields(entry.Fields)
}

func (open readerOpenWire) validate() error {
	if open.SchemaVersion != 1 || open.OperationGeneration == 0 ||
		open.LeaseGeneration == 0 || open.ProviderGeneration == 0 ||
		!validIdentifier(open.IdempotencyKey) ||
		!validIdentifier(open.SemanticRequestDigest) ||
		!validIdentifier(open.ReaderSessionID) || !validIdentifier(open.ContainerID) ||
		!validIdentifier(open.ProviderID) || open.Read.SchemaVersion != 1 {
		return errors.New("invalid reader open")
	}
	if open.Read.Tail != nil && (*open.Read.Tail < 0 || *open.Read.Tail > maximumReadTail) {
		return errors.New("invalid reader tail")
	}
	if (open.Read.Since != nil && (math.IsInf(*open.Read.Since, 0) || math.IsNaN(*open.Read.Since))) ||
		(open.Read.Until != nil && (math.IsInf(*open.Read.Until, 0) || math.IsNaN(*open.Read.Until))) {
		return errors.New("invalid reader time")
	}
	switch open.Source.Kind {
	case "stopped-container":
		if open.Source.SessionID != nil || open.Source.WriterProviderID != nil ||
			open.Source.WriterProviderGeneration != nil || open.Source.ActiveProcessGeneration != nil ||
			open.Source.ActiveSandboxGeneration != nil {
			return errors.New("stopped source contains active fields")
		}
	case "active-writer":
		if open.Source.SessionID == nil || open.Source.WriterProviderID == nil ||
			open.Source.WriterProviderGeneration == nil || *open.Source.WriterProviderGeneration == 0 ||
			open.Source.ActiveProcessGeneration == nil || *open.Source.ActiveProcessGeneration == 0 ||
			open.Source.ActiveSandboxGeneration == nil || *open.Source.ActiveSandboxGeneration == 0 ||
			!validIdentifier(*open.Source.SessionID) || !validIdentifier(*open.Source.WriterProviderID) {
			return errors.New("invalid active reader source")
		}
	default:
		return errors.New("invalid reader source")
	}
	return nil
}

func validateFields(fields map[string]string) error {
	if len(fields) > maximumFieldCount {
		return errors.New("too many journal fields")
	}
	bytes := 0
	for key, value := range fields {
		bytes += len(key) + len(value)
		if key == "" || strings.HasPrefix(key, "_") || bytes > maximumFieldBytes {
			return errors.New("invalid journal fields")
		}
	}
	return nil
}

func validIdentifier(value string) bool {
	return value != "" && len(value) <= maximumIdentifierBytes
}

func validUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	compact := strings.ReplaceAll(value, "-", "")
	if len(compact) != 32 {
		return false
	}
	_, err := hex.DecodeString(compact)
	return err == nil
}

func truncateBytes(value string, count int) string {
	if len(value) <= count {
		return value
	}
	return value[:count]
}

func readFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > maximumFrameBytes {
		return nil, fmt.Errorf("invalid frame length: %d", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(writer io.Writer, value wireResponse) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(payload) == 0 || len(payload) > maximumFrameBytes {
		return fmt.Errorf("response frame too large: %d", len(payload))
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if err := writeAll(writer, header[:]); err != nil {
		return err
	}
	return writeAll(writer, payload)
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		count, err := writer.Write(data)
		if err != nil {
			return err
		}
		if count <= 0 {
			return io.ErrShortWrite
		}
		data = data[count:]
	}
	return nil
}

var swiftReferenceDate = time.Date(2001, time.January, 1, 0, 0, 0, 0, time.UTC)

func swiftDate(value *float64) *time.Time {
	if value == nil {
		return nil
	}
	seconds, fraction := math.Modf(*value)
	timestamp := swiftReferenceDate.Add(time.Duration(seconds) * time.Second)
	timestamp = timestamp.Add(time.Duration(math.Round(fraction * float64(time.Second))))
	return &timestamp
}
