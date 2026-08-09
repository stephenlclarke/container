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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	serviceSchemaVersion      = uint32(1)
	maximumIdentifierBytes    = 256
	maximumSemanticBytes      = 32 * 1024
	maximumPluginRequestBytes = 256 * 1024
	maximumTokenBytes         = 4 * 1024
	maximumLogFrameBytes      = 16 * 1024 * 1024
	maximumMigrationIDBytes   = 4 * 1024
	maximumMigrationTextBytes = 1024
)

var (
	errGenerationMismatch  = errors.New("generation mismatch")
	errIdempotencyConflict = errors.New("idempotency conflict")
	errInvalidToken        = errors.New("invalid effect token")
	errInvalidFence        = errors.New("invalid session fence")
	errUnknownSession      = errors.New("unknown session")
	errUnavailable         = errors.New("service unavailable")
	errCorruptState        = errors.New("corrupt durable state")
	errCapabilityMismatch  = errors.New("capability mismatch")
)

type writerStart struct {
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

func (request writerStart) validate(provider serviceIdentity) error {
	if err := request.validateForReconciliation(provider); err != nil ||
		*request.CandidateSandboxGeneration != provider.SandboxGeneration {
		return errInvalidFence
	}
	return nil
}

// Reconciliation may describe a writer fenced by an earlier sandbox
// generation. It must never accept generation zero or a future generation,
// while a new writer still requires the exact active generation above.
func (request writerStart) validateForReconciliation(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion ||
		request.OperationGeneration == 0 || request.LeaseGeneration == 0 ||
		request.CandidateProcessGeneration == 0 ||
		request.ProviderGeneration != provider.Generation ||
		request.CandidateSandboxGeneration == nil ||
		*request.CandidateSandboxGeneration == 0 ||
		*request.CandidateSandboxGeneration > provider.SandboxGeneration ||
		request.ProviderID != provider.ID ||
		!validIdentifier(request.IdempotencyKey) ||
		!validIdentifier(request.SessionID) ||
		!validIdentifier(request.ContainerID) ||
		!validBoundedText(request.SemanticRequestDigest, maximumSemanticBytes) {
		return errInvalidFence
	}
	return nil
}

type writerOpen struct {
	Request          writerStart     `json:"request"`
	Info             json.RawMessage `json:"info"`
	ExpectedReadLogs bool            `json:"expectedReadLogs"`
}

func (open writerOpen) validate(provider serviceIdentity) error {
	if err := open.Request.validate(provider); err != nil {
		return err
	}
	return validateJSONObject(open.Info, maximumPluginRequestBytes)
}

type readerOpen struct {
	Request       readerStart     `json:"request"`
	PluginRequest json.RawMessage `json:"pluginRequest"`
}

type readerStart struct {
	SchemaVersion         uint32          `json:"schemaVersion"`
	OperationGeneration   uint64          `json:"operationGeneration"`
	IdempotencyKey        string          `json:"idempotencyKey"`
	SemanticRequestDigest string          `json:"semanticRequestDigest"`
	ReaderSessionID       string          `json:"readerSessionID"`
	ContainerID           string          `json:"containerID"`
	LeaseGeneration       uint64          `json:"leaseGeneration"`
	ProviderID            string          `json:"providerID"`
	ProviderGeneration    uint64          `json:"providerGeneration"`
	Source                json.RawMessage `json:"source"`
	Read                  json.RawMessage `json:"read"`
}

func (open readerOpen) validate(provider serviceIdentity) error {
	if err := open.Request.validate(provider); err != nil {
		return err
	}
	return validateJSONObject(open.PluginRequest, maximumPluginRequestBytes)
}

func (request readerStart) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion ||
		request.OperationGeneration == 0 || request.LeaseGeneration == 0 ||
		request.ProviderGeneration != provider.Generation ||
		request.ProviderID != provider.ID ||
		!validIdentifier(request.IdempotencyKey) ||
		!validIdentifier(request.ReaderSessionID) ||
		!validIdentifier(request.ContainerID) ||
		!validBoundedText(request.SemanticRequestDigest, maximumSemanticBytes) {
		return errInvalidFence
	}
	if err := validateJSONObject(request.Source, maximumSemanticBytes); err != nil {
		return err
	}
	if err := validateJSONObject(request.Read, maximumSemanticBytes); err != nil {
		return err
	}
	return nil
}

type writerFence struct {
	Kind                    string  `json:"kind"`
	OperationGeneration     *uint64 `json:"operationGeneration,omitempty"`
	ProcessGeneration       uint64  `json:"processGeneration"`
	ActiveSandboxGeneration *uint64 `json:"sandboxGeneration,omitempty"`
}

type writerCall struct {
	SchemaVersion      uint32      `json:"schemaVersion"`
	SessionID          string      `json:"sessionID"`
	ContainerID        string      `json:"containerID"`
	LeaseGeneration    uint64      `json:"leaseGeneration"`
	ProviderID         string      `json:"providerID"`
	ProviderGeneration uint64      `json:"providerGeneration"`
	Fence              writerFence `json:"fence"`
	Token              []byte      `json:"token"`
}

type readerCall struct {
	SchemaVersion      uint32          `json:"schemaVersion"`
	ReaderSessionID    string          `json:"readerSessionID"`
	ContainerID        string          `json:"containerID"`
	LeaseGeneration    uint64          `json:"leaseGeneration"`
	ProviderID         string          `json:"providerID"`
	ProviderGeneration uint64          `json:"providerGeneration"`
	Source             json.RawMessage `json:"source"`
	Token              []byte          `json:"token"`
}

type terminalReclaim struct {
	SchemaVersion      uint32 `json:"schemaVersion"`
	Kind               string `json:"kind"`
	EffectID           string `json:"effectID"`
	ProviderID         string `json:"providerID"`
	ProviderGeneration uint64 `json:"providerGeneration"`
}

type historyMigrationRequest struct {
	SchemaVersion            uint32 `json:"schemaVersion"`
	ContainerID              string `json:"containerID"`
	SourceLeaseGeneration    uint64 `json:"sourceLeaseGeneration"`
	TargetLeaseGeneration    uint64 `json:"targetLeaseGeneration"`
	ProviderID               string `json:"providerID"`
	SourceProviderGeneration uint64 `json:"sourceProviderGeneration"`
	TargetProviderGeneration uint64 `json:"targetProviderGeneration"`
	ContractDigest           string `json:"contractDigest"`
	TerminalHistoryDigest    string `json:"terminalHistoryDigest"`
}

func (request historyMigrationRequest) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion ||
		request.ContainerID == "" || len(request.ContainerID) > maximumMigrationIDBytes ||
		request.SourceLeaseGeneration == 0 || request.SourceLeaseGeneration == ^uint64(0) ||
		request.TargetLeaseGeneration != request.SourceLeaseGeneration+1 ||
		request.ProviderID != provider.ID ||
		request.SourceProviderGeneration == 0 ||
		request.TargetProviderGeneration != provider.Generation ||
		request.TargetProviderGeneration <= request.SourceProviderGeneration ||
		request.ContractDigest != provider.ContractDigest ||
		!validBoundedText(request.TerminalHistoryDigest, maximumMigrationTextBytes) {
		return errInvalidFence
	}
	return nil
}

type historyMigrationReceipt struct {
	SchemaVersion         uint32                  `json:"schemaVersion"`
	Request               historyMigrationRequest `json:"request"`
	ProviderOutcomeDigest string                  `json:"providerOutcomeDigest"`
}

type historyHandoffExportRequest struct {
	SchemaVersion               uint32 `json:"schemaVersion"`
	TokenID                     string `json:"tokenID"`
	ManifestID                  string `json:"manifestID"`
	ContainerID                 string `json:"containerID"`
	SourceStateRootUUID         string `json:"sourceStateRootUUID"`
	DestinationStateRootUUID    string `json:"destinationStateRootUUID"`
	SourceLeaseGeneration       uint64 `json:"sourceLeaseGeneration"`
	SourceProviderID            string `json:"sourceProviderID"`
	SourceProviderGeneration    uint64 `json:"sourceProviderGeneration"`
	SourceContractDigest        string `json:"sourceContractDigest"`
	TerminalHistoryDigestSHA256 string `json:"terminalHistoryDigestSHA256"`
}

func (request historyHandoffExportRequest) validate() error {
	if request.SchemaVersion != serviceSchemaVersion ||
		!validBoundedText(request.TokenID, maximumMigrationIDBytes) ||
		!validBoundedText(request.ManifestID, maximumMigrationIDBytes) ||
		!validBoundedText(request.ContainerID, maximumMigrationIDBytes) ||
		!validBoundedText(request.SourceStateRootUUID, maximumMigrationIDBytes) ||
		!validBoundedText(request.DestinationStateRootUUID, maximumMigrationIDBytes) ||
		request.SourceStateRootUUID == request.DestinationStateRootUUID ||
		request.SourceLeaseGeneration == 0 ||
		!validBoundedText(request.SourceProviderID, maximumMigrationIDBytes) ||
		request.SourceProviderGeneration == 0 ||
		!validBoundedText(request.SourceContractDigest, maximumMigrationTextBytes) ||
		!validBoundedText(request.TerminalHistoryDigestSHA256, maximumMigrationTextBytes) {
		return errInvalidFence
	}
	return nil
}

func (request historyHandoffExportRequest) validateSource(provider serviceIdentity) error {
	if err := request.validate(); err != nil || request.SourceProviderID != provider.ID ||
		request.SourceProviderGeneration != provider.Generation ||
		request.SourceContractDigest != provider.ContractDigest {
		return errInvalidFence
	}
	return nil
}

type historyHandoffExportReceipt struct {
	SchemaVersion               uint32                      `json:"schemaVersion"`
	Request                     historyHandoffExportRequest `json:"request"`
	ProviderOutcomeDigestSHA256 string                      `json:"providerOutcomeDigestSHA256"`
	ExportReceiptDigestSHA256   string                      `json:"exportReceiptDigestSHA256"`
}

func (receipt historyHandoffExportReceipt) validate() error {
	if receipt.SchemaVersion != serviceSchemaVersion || receipt.Request.validate() != nil ||
		!validBoundedText(receipt.ProviderOutcomeDigestSHA256, maximumMigrationTextBytes) ||
		receipt.ExportReceiptDigestSHA256 != historyHandoffExportReceiptDigest(receipt) {
		return errInvalidFence
	}
	return nil
}

type historyHandoffDestinationRequest struct {
	SchemaVersion                 uint32                      `json:"schemaVersion"`
	ExportReceipt                 historyHandoffExportReceipt `json:"exportReceipt"`
	ManifestDigestSHA256          string                      `json:"manifestDigestSHA256"`
	DestinationLeaseGeneration    uint64                      `json:"destinationLeaseGeneration"`
	DestinationProviderID         string                      `json:"destinationProviderID"`
	DestinationProviderGeneration uint64                      `json:"destinationProviderGeneration"`
	DestinationContractDigest     string                      `json:"destinationContractDigest"`
}

func (request historyHandoffDestinationRequest) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion || request.ExportReceipt.validate() != nil ||
		!validBoundedText(request.ManifestDigestSHA256, maximumMigrationTextBytes) ||
		request.DestinationLeaseGeneration == 0 || request.DestinationProviderID != provider.ID ||
		request.DestinationProviderGeneration != provider.Generation ||
		request.DestinationContractDigest != provider.ContractDigest ||
		request.ExportReceipt.Request.DestinationStateRootUUID == "" {
		return errInvalidFence
	}
	return nil
}

type historyHandoffPromotionRequest struct {
	SchemaVersion                uint32                           `json:"schemaVersion"`
	Destination                  historyHandoffDestinationRequest `json:"destination"`
	CommitDigestSHA256           string                           `json:"commitDigestSHA256"`
	HandoffChainHeadDigestSHA256 string                           `json:"handoffChainHeadDigestSHA256"`
}

func (request historyHandoffPromotionRequest) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion || request.Destination.validate(provider) != nil ||
		!validBoundedText(request.CommitDigestSHA256, maximumMigrationTextBytes) ||
		!validBoundedText(request.HandoffChainHeadDigestSHA256, maximumMigrationTextBytes) {
		return errInvalidFence
	}
	return nil
}

type historyHandoffPromotionReceipt struct {
	SchemaVersion                uint32                         `json:"schemaVersion"`
	Request                      historyHandoffPromotionRequest `json:"request"`
	ProviderOutcomeDigestSHA256  string                         `json:"providerOutcomeDigestSHA256"`
	PromotionReceiptDigestSHA256 string                         `json:"promotionReceiptDigestSHA256"`
}

func (receipt historyHandoffPromotionReceipt) validate(provider serviceIdentity) error {
	if receipt.SchemaVersion != serviceSchemaVersion || receipt.Request.validate(provider) != nil ||
		!validBoundedText(receipt.ProviderOutcomeDigestSHA256, maximumMigrationTextBytes) ||
		receipt.PromotionReceiptDigestSHA256 != historyHandoffPromotionReceiptDigest(receipt) {
		return errInvalidFence
	}
	return nil
}

type historyHandoffActivationRequest struct {
	SchemaVersion               uint32                         `json:"schemaVersion"`
	PromotionReceipt            historyHandoffPromotionReceipt `json:"promotionReceipt"`
	TerminalOutcomeDigestSHA256 string                         `json:"terminalOutcomeDigestSHA256"`
}

func (request historyHandoffActivationRequest) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion || request.PromotionReceipt.validate(provider) != nil ||
		!validBoundedText(request.TerminalOutcomeDigestSHA256, maximumMigrationTextBytes) {
		return errInvalidFence
	}
	return nil
}

type providerGenerationReclaim struct {
	SchemaVersion      uint32 `json:"schemaVersion"`
	ProviderID         string `json:"providerID"`
	ProviderGeneration uint64 `json:"providerGeneration"`
}

func (request providerGenerationReclaim) validate(provider serviceIdentity) error {
	if request.SchemaVersion != serviceSchemaVersion || request.ProviderID != provider.ID ||
		request.ProviderGeneration != provider.Generation {
		return errInvalidFence
	}
	return nil
}

type serviceIdentity struct {
	ID                string `json:"providerID"`
	Generation        uint64 `json:"providerGeneration"`
	SandboxGeneration uint64 `json:"sandboxGeneration"`
	ContractDigest    string `json:"contractDigest"`
}

func (identity serviceIdentity) validate() error {
	if !validIdentifier(identity.ID) || identity.Generation == 0 ||
		identity.SandboxGeneration == 0 ||
		!validBoundedText(identity.ContractDigest, maximumMigrationTextBytes) {
		return errInvalidFence
	}
	return nil
}

func validIdentifier(value string) bool {
	if value == "" || len(value) > maximumIdentifierBytes ||
		strings.TrimSpace(value) != value {
		return false
	}
	for _, value := range []byte(value) {
		if value < 0x21 || value > 0x7e {
			return false
		}
	}
	return true
}

func validBoundedText(value string, maximum int) bool {
	return value != "" && len(value) <= maximum
}

func validateJSONObject(data []byte, maximum int) error {
	if len(data) == 0 || len(data) > maximum {
		return errors.New("invalid bounded JSON object")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	var object map[string]json.RawMessage
	if err := decoder.Decode(&object); err != nil || object == nil {
		return errors.New("invalid JSON object")
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return fmt.Errorf("trailing JSON data: %w", err)
	}
	return nil
}
