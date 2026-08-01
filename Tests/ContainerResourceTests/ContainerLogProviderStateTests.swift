//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import ContainerResource

struct ContainerLogProviderStateTests {
    private let controllerID = "logging-controller"
    private let writerSessionID = "writer-session"
    private let readerSessionID = "reader-session"
    private let providerID = "provider-id"
    private let providerGeneration: UInt64 = 5

    @Test func readerSourceUsesStrictExplicitEncoding() throws {
        let stopped = LoggingReaderSourceV1.stoppedContainer
        let active = try activeReaderSource()

        #expect(try roundTrip(stopped) == stopped)
        #expect(try roundTrip(active) == active)

        var object = try jsonObject(JSONEncoder().encode(stopped))
        object["sessionID"] = writerSessionID
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LoggingReaderSourceV1.self, from: encoded(object))
        }

        object = try jsonObject(JSONEncoder().encode(active))
        object["future"] = true
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LoggingReaderSourceV1.self, from: encoded(object))
        }

        #expect(throws: LogDriverLifecycleContractError.zeroGeneration("writerProviderGeneration")) {
            try LoggingReaderSourceV1(
                activeWriterSessionID: writerSessionID,
                writerProviderID: providerID,
                writerProviderGeneration: 0,
                activeProcessGeneration: 11,
                activeSandboxGeneration: nil
            )
        }
    }

    @Test func protectedEffectReferenceRoundTripsWithoutRawMaterialAndRejectsUnknownSchema() throws {
        let reference = try writerReference()
        let data = try JSONEncoder().encode(reference)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(try JSONDecoder().decode(ProtectedLoggingEffectReferenceV1.self, from: data) == reference)
        #expect(!text.contains("opaque-provider-secret"))

        var object = try jsonObject(data)
        object["schemaVersion"] = 2
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProtectedLoggingEffectReferenceV1.self, from: encoded(object))
        }
        object["schemaVersion"] = 1
        object["future"] = true
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProtectedLoggingEffectReferenceV1.self, from: encoded(object))
        }
    }

    @Test func everyProtectedReferenceFieldParticipatesInPreResolutionEquality() throws {
        let expected = try writerReference()
        let substitutions = [
            try ProtectedLoggingEffectReferenceV1(
                effectID: "different-session",
                owningControllerID: controllerID,
                providerID: providerID,
                providerGeneration: providerGeneration,
                protectedStoreObjectID: "protected-object",
                integrityDigest: "hmac:effect"
            ),
            try ProtectedLoggingEffectReferenceV1(
                effectID: writerSessionID,
                owningControllerID: "different-controller",
                providerID: providerID,
                providerGeneration: providerGeneration,
                protectedStoreObjectID: "protected-object",
                integrityDigest: "hmac:effect"
            ),
            try ProtectedLoggingEffectReferenceV1(
                effectID: writerSessionID,
                owningControllerID: controllerID,
                providerID: "different-provider",
                providerGeneration: providerGeneration,
                protectedStoreObjectID: "protected-object",
                integrityDigest: "hmac:effect"
            ),
            try ProtectedLoggingEffectReferenceV1(
                effectID: writerSessionID,
                owningControllerID: controllerID,
                providerID: providerID,
                providerGeneration: providerGeneration + 1,
                protectedStoreObjectID: "protected-object",
                integrityDigest: "hmac:effect"
            ),
            try ProtectedLoggingEffectReferenceV1(
                effectID: writerSessionID,
                owningControllerID: controllerID,
                providerID: providerID,
                providerGeneration: providerGeneration,
                protectedStoreObjectID: "different-object",
                integrityDigest: "hmac:effect"
            ),
            try ProtectedLoggingEffectReferenceV1(
                effectID: writerSessionID,
                owningControllerID: controllerID,
                providerID: providerID,
                providerGeneration: providerGeneration,
                protectedStoreObjectID: "protected-object",
                integrityDigest: "hmac:different"
            ),
        ]

        for substitution in substitutions {
            #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
                try substitution.validateExactReference(expected)
            }
        }
    }

    @Test func writerPreparationBindsEffectSessionProviderAndControllerBeforeResolution() throws {
        let reference = try writerReference()
        let preparation = try writerPreparation(reference: reference)

        #expect(try roundTrip(preparation) == preparation)
        try preparation.validateEffectReference(reference, owningControllerID: controllerID)

        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try preparation.validateEffectReference(owningControllerID: "substituted-controller")
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try writerPreparation(reference: try makeReference(effectID: "different-session"))
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try writerPreparation(reference: try makeReference(providerID: "different-provider"))
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try writerPreparation(reference: try makeReference(providerGeneration: 6))
        }
    }

    @Test func writerActivationEnforcesLiveAndTerminalReferenceDisposition() throws {
        let reference = try writerReference()
        let active = try writerActivation(reference: reference, disposition: nil, state: .active)
        let draining = try writerActivation(reference: reference, disposition: nil, state: .draining)
        let recovery = try writerActivation(reference: reference, disposition: nil, state: .recoveryRequired)
        let closed = try writerActivation(reference: nil, disposition: .complete, state: .closed)
        let tombstoned = try writerActivation(
            reference: nil,
            disposition: .deadlineTruncated,
            state: .tombstoned
        )

        for state in [active, draining, recovery, closed, tombstoned] {
            #expect(try roundTrip(state) == state)
        }
        try active.validateEffectReference(reference, owningControllerID: controllerID)
        try closed.validateEffectReference(nil, owningControllerID: controllerID)

        #expect(throws: (any Error).self) {
            try writerActivation(reference: nil, disposition: nil, state: .active)
        }
        #expect(throws: (any Error).self) {
            try writerActivation(reference: reference, disposition: .complete, state: .closed)
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try active.validateEffectReference(
                try makeReference(protectedStoreObjectID: "substituted-object"),
                owningControllerID: controllerID
            )
        }
    }

    @Test func detachedCleanupCanOnlyHoldReferenceBeforeTerminalProviderOutcome() throws {
        let reference = try writerReference()
        let pending = try cleanup(reference: reference, outcome: nil, state: .pending)
        let recovery = try cleanup(reference: reference, outcome: nil, state: .recoveryRequired)
        let complete = try cleanup(reference: nil, outcome: "sha256:closed", state: .complete)
        let tombstoned = try cleanup(reference: nil, outcome: "sha256:closed", state: .tombstoned)

        for state in [pending, recovery, complete, tombstoned] {
            #expect(try roundTrip(state) == state)
        }
        try pending.validateEffectReference(reference, owningControllerID: controllerID)

        #expect(throws: (any Error).self) {
            try cleanup(reference: nil, outcome: nil, state: .pending)
        }
        #expect(throws: (any Error).self) {
            try cleanup(reference: reference, outcome: "sha256:closed", state: .complete)
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try pending.validateEffectReference(
                try makeReference(integrityDigest: "hmac:substituted"),
                owningControllerID: controllerID
            )
        }
    }

    @Test func readerPreparationAndSessionRemainIndependentFromWriterIdentity() throws {
        let reference = try readerReference()
        let source = try activeReaderSource()
        let preparation = try readerPreparation(reference: reference, source: source)
        let active = try readerSession(
            reference: reference,
            outcome: nil,
            state: .active,
            source: source
        )
        let closing = try readerSession(
            reference: reference,
            outcome: nil,
            state: .closing,
            source: source
        )
        let recovery = try readerSession(
            reference: reference,
            outcome: nil,
            state: .recoveryRequired,
            source: source
        )
        let closed = try readerSession(
            reference: nil,
            outcome: "sha256:reader-closed",
            state: .closed,
            source: source
        )

        #expect(preparation.readerSessionID != writerSessionID)
        #expect(preparation.providerID != writerProviderID(from: source))
        for state in [active, closing, recovery, closed] {
            #expect(try roundTrip(state) == state)
        }
        try preparation.validateEffectReference(reference, owningControllerID: controllerID)
        try active.validateEffectReference(reference, owningControllerID: controllerID)

        #expect(throws: (any Error).self) {
            try readerSession(reference: nil, outcome: nil, state: .active, source: source)
        }
        #expect(throws: (any Error).self) {
            try readerSession(
                reference: reference,
                outcome: "sha256:reader-closed",
                state: .closed,
                source: source
            )
        }
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try readerPreparation(reference: try writerReference(), source: source)
        }
    }

    @Test func durableLifecycleModelsRejectUnknownKeysVersionsAndSubstitutionOnDecode() throws {
        let preparation = try writerPreparation(reference: writerReference())
        var object = try jsonObject(JSONEncoder().encode(preparation))

        object["future"] = true
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LoggingSessionPreparationV1.self, from: encoded(object))
        }

        object.removeValue(forKey: "future")
        object["schemaVersion"] = 2
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LoggingSessionPreparationV1.self, from: encoded(object))
        }

        object["schemaVersion"] = 1
        var nestedReference = try #require(object["effectTokenReference"] as? [String: Any])
        nestedReference["providerGeneration"] = 6
        object["effectTokenReference"] = nestedReference
        #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
            try JSONDecoder().decode(LoggingSessionPreparationV1.self, from: encoded(object))
        }
    }

    @Test func identifiersDigestsAndGenerationsAreBoundedAcrossDurableState() throws {
        #expect(throws: LogDriverLifecycleContractError.emptyField("effectID")) {
            try makeReference(effectID: "")
        }
        #expect(
            throws: LogDriverLifecycleContractError.fieldExceedsUTF8Limit(
                field: "integrityDigest",
                maximumBytes: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes
            )
        ) {
            try makeReference(
                integrityDigest: String(
                    repeating: "d",
                    count: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes + 1
                )
            )
        }
        #expect(throws: LogDriverLifecycleContractError.zeroGeneration("operationGeneration")) {
            try LoggingSessionPreparationV1(
                operationGeneration: 0,
                idempotencyKey: "key",
                semanticRequestDigest: "sha256:request",
                sessionID: writerSessionID,
                containerID: "container-id",
                leaseGeneration: 3,
                candidateProcessGeneration: 11,
                providerID: providerID,
                providerGeneration: providerGeneration,
                candidateSandboxGeneration: nil,
                effectTokenReference: writerReference()
            )
        }
    }

    private func makeReference(
        effectID: String? = nil,
        owningControllerID: String? = nil,
        providerID: String? = nil,
        providerGeneration: UInt64? = nil,
        protectedStoreObjectID: String = "protected-object",
        integrityDigest: String = "hmac:effect"
    ) throws -> ProtectedLoggingEffectReferenceV1 {
        try ProtectedLoggingEffectReferenceV1(
            effectID: effectID ?? writerSessionID,
            owningControllerID: owningControllerID ?? controllerID,
            providerID: providerID ?? self.providerID,
            providerGeneration: providerGeneration ?? self.providerGeneration,
            protectedStoreObjectID: protectedStoreObjectID,
            integrityDigest: integrityDigest
        )
    }

    private func writerReference() throws -> ProtectedLoggingEffectReferenceV1 {
        try makeReference()
    }

    private func readerReference() throws -> ProtectedLoggingEffectReferenceV1 {
        try makeReference(effectID: readerSessionID, providerID: "reader-provider", providerGeneration: 7)
    }

    private func writerPreparation(
        reference: ProtectedLoggingEffectReferenceV1
    ) throws -> LoggingSessionPreparationV1 {
        try LoggingSessionPreparationV1(
            operationGeneration: 7,
            idempotencyKey: "writer-operation",
            semanticRequestDigest: "sha256:writer-request",
            sessionID: writerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            candidateProcessGeneration: 11,
            providerID: providerID,
            providerGeneration: providerGeneration,
            candidateSandboxGeneration: 13,
            effectTokenReference: reference
        )
    }

    private func writerActivation(
        reference: ProtectedLoggingEffectReferenceV1?,
        disposition: LoggingSessionCloseDispositionV1?,
        state: LoggingSessionState
    ) throws -> LoggingSessionActivationV1 {
        try LoggingSessionActivationV1(
            sessionID: writerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            activeProcessGeneration: 11,
            providerID: providerID,
            providerGeneration: providerGeneration,
            activeSandboxGeneration: 13,
            effectTokenReference: reference,
            closeDisposition: disposition,
            state: state
        )
    }

    private func cleanup(
        reference: ProtectedLoggingEffectReferenceV1?,
        outcome: String?,
        state: LoggingDetachedCleanupStateV1
    ) throws -> LoggingDetachedCleanupV1 {
        try LoggingDetachedCleanupV1(
            cleanupID: "cleanup-id",
            sessionID: writerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            activeProcessGeneration: 11,
            providerID: providerID,
            providerGeneration: providerGeneration,
            activeSandboxGeneration: 13,
            writerFenceReceiptDigest: "sha256:fence",
            effectTokenReference: reference,
            providerCloseOutcomeDigest: outcome,
            state: state
        )
    }

    private func activeReaderSource() throws -> LoggingReaderSourceV1 {
        try LoggingReaderSourceV1(
            activeWriterSessionID: writerSessionID,
            writerProviderID: "writer-provider",
            writerProviderGeneration: providerGeneration,
            activeProcessGeneration: 11,
            activeSandboxGeneration: 13
        )
    }

    private func writerProviderID(from source: LoggingReaderSourceV1) -> String? {
        if case .activeWriter(_, let providerID, _, _, _) = source {
            return providerID
        }
        return nil
    }

    private func readerPreparation(
        reference: ProtectedLoggingEffectReferenceV1,
        source: LoggingReaderSourceV1
    ) throws -> LoggingReaderPreparationV1 {
        try LoggingReaderPreparationV1(
            operationGeneration: 8,
            idempotencyKey: "reader-operation",
            semanticRequestDigest: "sha256:reader-request",
            readerSessionID: readerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: "reader-provider",
            providerGeneration: 7,
            source: source,
            effectTokenReference: reference
        )
    }

    private func readerSession(
        reference: ProtectedLoggingEffectReferenceV1?,
        outcome: String?,
        state: LoggingReaderSessionStateV1,
        source: LoggingReaderSourceV1
    ) throws -> LoggingReaderSessionV1 {
        try LoggingReaderSessionV1(
            readerSessionID: readerSessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: "reader-provider",
            providerGeneration: 7,
            source: source,
            effectTokenReference: reference,
            terminalOutcomeDigest: outcome,
            state: state
        )
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
