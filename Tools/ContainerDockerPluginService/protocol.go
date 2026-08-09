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
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
)

const (
	wireSchemaVersion     = uint32(1)
	maximumWireFrameBytes = 24 * 1024 * 1024
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type wireOperation string

const (
	operationActiveSandboxGeneration wireOperation = "activeSandboxGeneration"
	operationMigrateHistory          wireOperation = "migrateHistory"
	operationExportHistoryForHandoff wireOperation = "exportHistoryForHandoff"
	operationPreflightHistoryHandoff wireOperation = "preflightHistoryHandoff"
	operationPromoteHistoryHandoff   wireOperation = "promoteHistoryHandoff"
	operationActivateHistoryHandoff  wireOperation = "activateHistoryHandoff"
	operationReclaimGeneration       wireOperation = "reclaimGeneration"
	operationStartWriter             wireOperation = "startWriter"
	operationReconcileWriterOpen     wireOperation = "reconcileWriterOpen"
	operationWriteWriter             wireOperation = "writeWriter"
	operationFlushWriter             wireOperation = "flushWriter"
	operationFinishWriter            wireOperation = "finishWriter"
	operationReconcileWriter         wireOperation = "reconcileWriter"
	operationFenceWriter             wireOperation = "fenceWriter"
	operationCloseWriter             wireOperation = "closeWriter"
	operationOpenReader              wireOperation = "openReader"
	operationReconcileReaderOpen     wireOperation = "reconcileReaderOpen"
	operationNextReader              wireOperation = "nextReader"
	operationCancelReader            wireOperation = "cancelReader"
	operationReconcileReader         wireOperation = "reconcileReader"
	operationCloseReader             wireOperation = "closeReader"
	operationReclaimTerminalEffect   wireOperation = "reclaimTerminalEffect"
)

type wireFailure string

const (
	failureInvalidRequest      wireFailure = "invalidRequest"
	failureGenerationMismatch  wireFailure = "generationMismatch"
	failureIdempotencyConflict wireFailure = "idempotencyConflict"
	failureInvalidToken        wireFailure = "invalidToken"
	failureInvalidFence        wireFailure = "invalidFence"
	failureCapabilityMismatch  wireFailure = "capabilityMismatch"
	failurePluginRejected      wireFailure = "pluginRejected"
	failureUnknownSession      wireFailure = "unknownSession"
	failureUnavailable         wireFailure = "unavailable"
	failureInternal            wireFailure = "internalFailure"
)

type wireRequest struct {
	SchemaVersion uint32        `json:"schemaVersion"`
	OperationID   string        `json:"operationID"`
	Operation     wireOperation `json:"operation"`

	WriterOpen                *writerOpen                       `json:"writerOpen,omitempty"`
	WriterStart               *writerStart                      `json:"writerStart,omitempty"`
	WriterCall                *writerCall                       `json:"writerCall,omitempty"`
	ReaderOpen                *readerOpen                       `json:"readerOpen,omitempty"`
	ReaderStart               *readerStart                      `json:"readerStart,omitempty"`
	ReaderCall                *readerCall                       `json:"readerCall,omitempty"`
	Reclaim                   *terminalReclaim                  `json:"terminalReclaim,omitempty"`
	HistoryMigration          *historyMigrationRequest          `json:"historyMigration,omitempty"`
	HistoryHandoffExport      *historyHandoffExportRequest      `json:"historyHandoffExport,omitempty"`
	HistoryHandoffDestination *historyHandoffDestinationRequest `json:"historyHandoffDestination,omitempty"`
	HistoryHandoffPromotion   *historyHandoffPromotionRequest   `json:"historyHandoffPromotion,omitempty"`
	HistoryHandoffActivation  *historyHandoffActivationRequest  `json:"historyHandoffActivation,omitempty"`
	GenerationReclaim         *providerGenerationReclaim        `json:"generationReclaim,omitempty"`

	SessionID      *string `json:"sessionID,omitempty"`
	Token          []byte  `json:"token,omitempty"`
	Frame          []byte  `json:"frame,omitempty"`
	Sequence       *uint64 `json:"sequence,omitempty"`
	Fenced         *bool   `json:"fenced,omitempty"`
	Authentication []byte  `json:"authentication,omitempty"`
}

func (request wireRequest) validate(identity serviceIdentity) error {
	if request.SchemaVersion != wireSchemaVersion || !uuidPattern.MatchString(request.OperationID) {
		return errors.New("invalid request envelope")
	}
	payloads := 0
	for _, present := range []bool{
		request.WriterOpen != nil,
		request.WriterStart != nil,
		request.WriterCall != nil,
		request.ReaderOpen != nil,
		request.ReaderStart != nil,
		request.ReaderCall != nil,
		request.Reclaim != nil,
		request.HistoryMigration != nil,
		request.HistoryHandoffExport != nil,
		request.HistoryHandoffDestination != nil,
		request.HistoryHandoffPromotion != nil,
		request.HistoryHandoffActivation != nil,
		request.GenerationReclaim != nil,
		request.SessionID != nil,
		len(request.Token) != 0,
		len(request.Frame) != 0,
		request.Sequence != nil,
		request.Fenced != nil,
	} {
		if present {
			payloads++
		}
	}
	requireSessionToken := func(withFrame bool, withSequence bool) error {
		expected := 2
		if withFrame {
			expected++
		}
		if withSequence {
			expected++
		}
		if payloads != expected || request.SessionID == nil || !validIdentifier(*request.SessionID) ||
			len(request.Token) == 0 || len(request.Token) > maximumTokenBytes {
			return errors.New("invalid session operation")
		}
		if withFrame && (len(request.Frame) == 0 || len(request.Frame) > maximumLogFrameBytes) {
			return errors.New("invalid writer frame")
		}
		if withSequence && (request.Sequence == nil || *request.Sequence == 0) {
			return errors.New("invalid reader sequence")
		}
		return nil
	}
	switch request.Operation {
	case operationActiveSandboxGeneration:
		if payloads != 0 {
			return errors.New("generation request has a payload")
		}
	case operationMigrateHistory:
		if payloads != 1 || request.HistoryMigration == nil {
			return errors.New("invalid history migration payload")
		}
		return request.HistoryMigration.validate(identity)
	case operationExportHistoryForHandoff:
		if payloads != 1 || request.HistoryHandoffExport == nil {
			return errors.New("invalid history handoff export payload")
		}
		return request.HistoryHandoffExport.validateSource(identity)
	case operationPreflightHistoryHandoff:
		if payloads != 1 || request.HistoryHandoffDestination == nil {
			return errors.New("invalid history handoff preflight payload")
		}
		return request.HistoryHandoffDestination.validate(identity)
	case operationPromoteHistoryHandoff:
		if payloads != 1 || request.HistoryHandoffPromotion == nil {
			return errors.New("invalid history handoff promotion payload")
		}
		return request.HistoryHandoffPromotion.validate(identity)
	case operationActivateHistoryHandoff:
		if payloads != 1 || request.HistoryHandoffActivation == nil {
			return errors.New("invalid history handoff activation payload")
		}
		return request.HistoryHandoffActivation.validate(identity)
	case operationReclaimGeneration:
		if payloads != 1 || request.GenerationReclaim == nil {
			return errors.New("invalid generation reclaim payload")
		}
		return request.GenerationReclaim.validate(identity)
	case operationStartWriter:
		if payloads != 1 || request.WriterOpen == nil {
			return errors.New("invalid start writer payload")
		}
		return request.WriterOpen.validate(identity)
	case operationReconcileWriterOpen:
		if payloads != 1 || request.WriterStart == nil {
			return errors.New("invalid writer reconciliation payload")
		}
		return request.WriterStart.validateForReconciliation(identity)
	case operationWriteWriter:
		return requireSessionToken(true, true)
	case operationFlushWriter, operationCancelReader:
		return requireSessionToken(false, false)
	case operationFinishWriter:
		if request.SessionID == nil || !validIdentifier(*request.SessionID) ||
			len(request.Token) == 0 || len(request.Token) > maximumTokenBytes ||
			request.Fenced == nil || payloads != 3 {
			return errors.New("invalid finish writer payload")
		}
	case operationReconcileWriter, operationFenceWriter, operationCloseWriter:
		if payloads != 1 || request.WriterCall == nil {
			return errors.New("invalid writer call payload")
		}
	case operationOpenReader:
		if payloads != 1 || request.ReaderOpen == nil {
			return errors.New("invalid open reader payload")
		}
		return request.ReaderOpen.validate(identity)
	case operationReconcileReaderOpen:
		if payloads != 1 || request.ReaderStart == nil {
			return errors.New("invalid reader reconciliation payload")
		}
		return request.ReaderStart.validate(identity)
	case operationNextReader:
		return requireSessionToken(false, true)
	case operationReconcileReader, operationCloseReader:
		if payloads != 1 || request.ReaderCall == nil {
			return errors.New("invalid reader call payload")
		}
	case operationReclaimTerminalEffect:
		if payloads != 1 || request.Reclaim == nil {
			return errors.New("invalid reclaim payload")
		}
	default:
		return errors.New("unknown operation")
	}
	return nil
}

type wireResponse struct {
	SchemaVersion uint32       `json:"schemaVersion"`
	OperationID   string       `json:"operationID"`
	Failure       *wireFailure `json:"failure,omitempty"`

	SandboxGeneration              *uint64                         `json:"sandboxGeneration,omitempty"`
	OpenObservation                *openObservation                `json:"openObservation,omitempty"`
	Capabilities                   *pluginCapabilities             `json:"capabilities,omitempty"`
	Token                          []byte                          `json:"token,omitempty"`
	WriterObservation              *string                         `json:"writerObservation,omitempty"`
	ReaderObservation              *string                         `json:"readerObservation,omitempty"`
	FenceReceiptDigest             *string                         `json:"fenceReceiptDigest,omitempty"`
	TerminalDigest                 *string                         `json:"terminalOutcomeDigest,omitempty"`
	Sequence                       *uint64                         `json:"sequence,omitempty"`
	Frame                          []byte                          `json:"frame,omitempty"`
	EndOfStream                    *bool                           `json:"endOfStream,omitempty"`
	HistoryMigrationReceipt        *historyMigrationReceipt        `json:"historyMigrationReceipt,omitempty"`
	HistoryHandoffExportReceipt    *historyHandoffExportReceipt    `json:"historyHandoffExportReceipt,omitempty"`
	HistoryHandoffPromotionReceipt *historyHandoffPromotionReceipt `json:"historyHandoffPromotionReceipt,omitempty"`
}

func acknowledgement(operationID string) wireResponse {
	return wireResponse{SchemaVersion: wireSchemaVersion, OperationID: operationID}
}

func failed(operationID string, failure wireFailure) wireResponse {
	return wireResponse{SchemaVersion: wireSchemaVersion, OperationID: operationID, Failure: &failure}
}

func decodeWireRequest(payload []byte, identity serviceIdentity, authenticationKey []byte) (wireRequest, error) {
	var request wireRequest
	if len(payload) == 0 || len(payload) > maximumWireFrameBytes || len(authenticationKey) != sha256.Size {
		return request, errors.New("invalid request frame length")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return request, err
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return request, errors.New("trailing request data")
	}
	if err := request.validate(identity); err != nil {
		return request, err
	}
	if len(request.Authentication) != sha256.Size {
		return request, errors.New("invalid request authentication")
	}
	canonical, err := canonicalUnauthenticatedRequest(payload)
	if err != nil {
		return request, err
	}
	mac := hmac.New(sha256.New, authenticationKey)
	_, _ = mac.Write(canonical)
	if !hmac.Equal(request.Authentication, mac.Sum(nil)) {
		return request, errors.New("invalid request authentication")
	}
	return request, nil
}

func canonicalUnauthenticatedRequest(payload []byte) ([]byte, error) {
	var fields map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&fields); err != nil || fields == nil {
		return nil, errors.New("invalid authentication envelope")
	}
	if _, found := fields["authentication"]; !found {
		return nil, errors.New("missing request authentication")
	}
	delete(fields, "authentication")
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var canonical bytes.Buffer
	canonical.WriteByte('{')
	for index, key := range keys {
		if index != 0 {
			canonical.WriteByte(',')
		}
		encodedKey, _ := json.Marshal(key)
		canonical.Write(encodedKey)
		canonical.WriteByte(':')
		canonical.Write(fields[key])
	}
	canonical.WriteByte('}')
	return canonical.Bytes(), nil
}

func readFrame(reader io.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > maximumWireFrameBytes {
		return nil, fmt.Errorf("invalid wire frame length %d", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(writer io.Writer, value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(payload) == 0 || len(payload) > maximumWireFrameBytes {
		return errors.New("wire response exceeds limit")
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(payload)))
	if _, err := writer.Write(header); err != nil {
		return err
	}
	_, err = writer.Write(payload)
	return err
}
