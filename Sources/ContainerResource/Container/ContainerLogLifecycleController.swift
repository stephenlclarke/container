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

import CryptoKit
import Foundation

/// Controller-local protected storage for opaque provider effect material.
///
/// `seal` must be idempotent for byte-identical material and a binding. It must
/// return the same complete reference after response loss. `resolve` and
/// `remove` must independently authenticate the complete reference and binding;
/// the lifecycle controller performs the same checks before invoking them.
public protocol ProtectedLoggingEffectStoreV1: Sendable {
    func seal(
        _ material: LogDriverOpaqueEffectTokenV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> ProtectedLoggingEffectReferenceV1

    func resolve(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws -> LogDriverOpaqueEffectTokenV1

    func remove(
        _ reference: ProtectedLoggingEffectReferenceV1,
        binding: ProtectedLoggingEffectBindingV1
    ) async throws
}

public enum LoggingWriterDeadlineOutcomeV1: Equatable, Sendable {
    case detached(LoggingDetachedCleanupV1)
    case closed(LoggingSessionActivationV1)
}

/// Effectful coordinator layered over ``ContainerLogLifecycleLedgerV1``.
///
/// Every mutating provider call is preceded by a durable intent/state change.
/// Every protected resolution is preceded by an exact ledger-state comparison,
/// complete reference comparison, controller/provider binding validation, and
/// provider-generation validation. The only tokenless recovery calls are the
/// provider's idempotent writer-start and reader-open reconciliation methods.
public actor ContainerLogLifecycleControllerV1 {
    public nonisolated let owningControllerID: String

    private let ledger: ContainerLogLifecycleLedgerV1
    private let protectedEffects: any ProtectedLoggingEffectStoreV1

    public init(
        ledger: ContainerLogLifecycleLedgerV1,
        protectedEffects: any ProtectedLoggingEffectStoreV1
    ) {
        self.owningControllerID = ledger.owningControllerID
        self.ledger = ledger
        self.protectedEffects = protectedEffects
    }

    /// Completes effect removals that were durably committed before a prior
    /// controller process stopped. Removal is idempotent; the journal entry is
    /// cleared only after the protected store confirms the effect is absent.
    public func reconcilePendingEffectRemovals(
        using provider: (any ContainerLogDriverProvider)? = nil
    ) async throws {
        while let pending = await ledger.snapshot().pendingEffectRemovals.first {
            try await finishEffectRemoval(pending, using: provider)
        }
    }

    /// Reserves before effect and chooses tokenless reconciliation on replay.
    @discardableResult
    public func prepareWriter(
        _ request: LogDriverStartRequestV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> StartedLogDriverSessionV1 {
        let reservation = try await ledger.reserveWriter(request)
        let record: LoggingWriterOperationRecordV1
        let isFirstAttempt: Bool
        switch reservation {
        case .reserved(let reserved):
            record = reserved
            isFirstAttempt = true
        case .replay(let replay):
            record = replay
            isFirstAttempt = false
        }

        try await validateProvider(
            provider,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )

        if isFirstAttempt {
            do {
                let started = try await provider.start(request)
                try await acceptWriterStart(started, request: request, existing: record)
                return started
            } catch {
                _ = try await ledger.markWriterStartRecoveryRequired(for: request)
                throw error
            }
        }

        switch record.result {
        case .candidateClosed:
            try await finishPendingEffectRemoval(
                kind: .writerCandidate,
                ownerID: request.sessionID,
                using: provider
            )
            throw ContainerLogLifecycleLedgerError.terminalOperation
        case .candidateClosing, .candidateRecoveryRequired:
            throw ContainerLogLifecycleLedgerError.terminalOperation
        case .activated(let activation) where activation.state != .active:
            if activation.state == .closed || activation.state == .tombstoned {
                try await finishPendingEffectRemoval(
                    kind: .writerSession,
                    ownerID: activation.sessionID,
                    using: provider
                )
            }
            throw ContainerLogLifecycleLedgerError.terminalOperation
        default:
            break
        }
        return try await reconcileWriterStart(request, record: record, provider: provider)
    }

    public func activateWriter(
        _ request: LogDriverStartRequestV1
    ) async throws -> LoggingSessionActivationV1 {
        try await ledger.commitWriterActivation(for: request)
    }

    /// Compensates a prepared candidate that did not commit process start.
    @discardableResult
    public func closePreparedWriter(
        _ request: LogDriverStartRequestV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingWriterOperationRecordV1 {
        guard let record = try await ledger.writerOperation(for: request) else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if case .candidateClosed = record.result {
            try await finishPendingEffectRemoval(
                kind: .writerCandidate,
                ownerID: request.sessionID,
                using: provider
            )
            return record
        }
        let shouldReconcile: Bool
        switch record.result {
        case .candidateClosing, .candidateRecoveryRequired:
            shouldReconcile = true
        case .prepared:
            shouldReconcile = false
        default:
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: "prepared writer candidate",
                actual: record.result.kindName
            )
        }

        let preparation = try await ledger.markWriterCandidateClosing(for: request)
        let call = try await writerCandidateCall(preparation, provider: provider)
        do {
            if shouldReconcile {
                let observation = try await provider.reconcileSession(call)
                try validateWriterAcknowledgement(observation, call: call)
                switch observation.observation {
                case .closed, .absent:
                    return try await completePreparedWriter(
                        request,
                        preparation: preparation,
                        using: provider
                    )
                case .active, .draining, .writerFenced:
                    break
                case .uncertain:
                    _ = try await ledger.markWriterCandidateRecoveryRequired(for: request)
                    throw ContainerLogLifecycleLedgerError.uncertainOwnership
                }
            }

            let acknowledgement = try await provider.closeSession(call)
            try validateWriterAcknowledgement(acknowledgement, call: call)
            guard acknowledgement.observation == .closed || acknowledgement.observation == .absent else {
                _ = try await ledger.markWriterCandidateRecoveryRequired(for: request)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
            return try await completePreparedWriter(
                request,
                preparation: preparation,
                using: provider
            )
        } catch {
            _ = try await markWriterCandidateRecoveryIfCurrent(request)
            throw error
        }
    }

    /// Performs the normal active -> draining -> closed path.
    @discardableResult
    public func closeWriter(
        _ expected: LoggingSessionActivationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingSessionActivationV1 {
        if let actual = await ledger.writerActivation(sessionID: expected.sessionID),
            actual != expected
        {
            guard Self.sameWriterIdentity(actual, expected) else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            switch actual.state {
            case .active, .draining, .recoveryRequired:
                return try await closeWriter(actual, using: provider)
            case .closed, .tombstoned:
                try await finishPendingEffectRemoval(
                    kind: .writerSession,
                    ownerID: actual.sessionID,
                    using: provider
                )
                return actual
            }
        }
        if expected.state == .closed || expected.state == .tombstoned {
            try await finishPendingEffectRemoval(
                kind: .writerSession,
                ownerID: expected.sessionID,
                using: provider
            )
            return expected
        }
        if expected.state == .recoveryRequired {
            return try await reconcileWriterClose(expected, using: provider)
        }
        let wasAlreadyDraining = expected.state == .draining
        let draining = try await ledger.beginWriterDrain(expected)
        let call = try await writerActiveCall(draining, provider: provider)

        do {
            if wasAlreadyDraining {
                let observation = try await provider.reconcileSession(call)
                try validateWriterAcknowledgement(observation, call: call)
                switch observation.observation {
                case .closed, .absent:
                    return try await completeWriterClose(
                        draining,
                        using: provider
                    )
                case .active, .draining, .writerFenced:
                    break
                case .uncertain:
                    _ = try await ledger.markWriterRecoveryRequired(draining)
                    throw ContainerLogLifecycleLedgerError.uncertainOwnership
                }
            }

            let acknowledgement = try await provider.closeSession(call)
            try validateWriterAcknowledgement(acknowledgement, call: call)
            guard acknowledgement.observation == .closed || acknowledgement.observation == .absent else {
                _ = try await ledger.markWriterRecoveryRequired(draining)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
            return try await completeWriterClose(draining, using: provider)
        } catch {
            _ = try await markWriterRecoveryIfCurrent(draining)
            throw error
        }
    }

    /// Uses raw-token reconciliation after an uncertain close response.
    @discardableResult
    public func reconcileWriterClose(
        _ expected: LoggingSessionActivationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingSessionActivationV1 {
        guard expected.state == .recoveryRequired else {
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: LoggingSessionState.recoveryRequired.rawValue,
                actual: expected.state.rawValue
            )
        }
        guard await ledger.writerActivation(sessionID: expected.sessionID) == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let call = try await writerActiveCall(expected, provider: provider)
        do {
            let observation = try await provider.reconcileSession(call)
            try validateWriterAcknowledgement(observation, call: call)
            switch observation.observation {
            case .closed, .absent:
                let draining = try await ledger.resumeWriterDrain(expected)
                return try await completeWriterClose(draining, using: provider)
            case .active, .draining, .writerFenced:
                let draining = try await ledger.resumeWriterDrain(expected)
                return try await closeWriter(draining, using: provider)
            case .uncertain:
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
        } catch {
            throw error
        }
    }

    /// Fences local writer authority before atomically transferring the exact
    /// protected reference to detached cleanup.
    @discardableResult
    public func fenceWriterAtDeadline(
        _ expected: LoggingSessionActivationV1,
        cleanupID: String,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingWriterDeadlineOutcomeV1 {
        if let existing = await ledger.detachedCleanup(cleanupID: cleanupID) {
            guard Self.cleanup(existing, matches: expected) else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            if existing.state == .complete || existing.state == .tombstoned {
                try await finishPendingEffectRemoval(
                    kind: .detachedCleanup,
                    ownerID: existing.cleanupID,
                    using: provider
                )
            }
            return .detached(existing)
        }
        if let actual = await ledger.writerActivation(sessionID: expected.sessionID),
            actual != expected
        {
            guard Self.sameWriterIdentity(actual, expected) else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            switch actual.state {
            case .active, .draining, .recoveryRequired:
                return try await fenceWriterAtDeadline(
                    actual,
                    cleanupID: cleanupID,
                    using: provider
                )
            case .closed, .tombstoned:
                try await finishPendingEffectRemoval(
                    kind: .writerSession,
                    ownerID: actual.sessionID,
                    using: provider
                )
                return .closed(actual)
            }
        }
        if expected.state == .closed || expected.state == .tombstoned {
            try await finishPendingEffectRemoval(
                kind: .writerSession,
                ownerID: expected.sessionID,
                using: provider
            )
            return .closed(expected)
        }
        let wasAlreadyDraining = expected.state == .draining
        let draining: LoggingSessionActivationV1
        if expected.state == .recoveryRequired {
            draining = try await ledger.resumeWriterDrain(expected)
        } else {
            draining = try await ledger.beginWriterDrain(expected)
        }
        let call = try await writerActiveCall(draining, provider: provider)

        do {
            if wasAlreadyDraining || expected.state == .recoveryRequired {
                let observation = try await provider.reconcileSession(call)
                try validateWriterAcknowledgement(observation, call: call)
                if let outcome = try await applyWriterFenceObservation(
                    observation,
                    draining: draining,
                    cleanupID: cleanupID,
                    using: provider
                ) {
                    return outcome
                }
            }

            let acknowledgement = try await provider.fenceSession(call)
            try validateWriterAcknowledgement(acknowledgement, call: call)
            if let outcome = try await applyWriterFenceObservation(
                acknowledgement,
                draining: draining,
                cleanupID: cleanupID,
                using: provider
            ) {
                return outcome
            }
            _ = try await ledger.markWriterRecoveryRequired(draining)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        } catch {
            _ = try await markWriterRecoveryIfCurrent(draining)
            throw error
        }
    }

    @discardableResult
    public func runDetachedCleanup(
        _ expected: LoggingDetachedCleanupV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingDetachedCleanupV1 {
        guard let actual = await ledger.detachedCleanup(cleanupID: expected.cleanupID) else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if actual != expected {
            guard Self.sameCleanupIdentity(actual, expected) else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            switch actual.state {
            case .pending, .recoveryRequired:
                return try await runDetachedCleanup(actual, using: provider)
            case .complete, .tombstoned:
                try await finishPendingEffectRemoval(
                    kind: .detachedCleanup,
                    ownerID: actual.cleanupID,
                    using: provider
                )
                return actual
            }
        }
        guard expected.state == .pending || expected.state == .recoveryRequired else {
            if expected.state == .complete || expected.state == .tombstoned {
                try await finishPendingEffectRemoval(
                    kind: .detachedCleanup,
                    ownerID: expected.cleanupID,
                    using: provider
                )
                return expected
            }
            throw ContainerLogLifecycleLedgerError.terminalOperation
        }
        let shouldReconcile = expected.state == .recoveryRequired
        let call = try await detachedCleanupCall(expected, provider: provider)
        do {
            if shouldReconcile {
                let observation = try await provider.reconcileSession(call)
                try validateWriterAcknowledgement(observation, call: call)
                switch observation.observation {
                case .closed, .absent:
                    return try await completeDetachedCleanup(
                        expected,
                        observation: observation.observation,
                        using: provider
                    )
                case .active, .draining, .writerFenced:
                    break
                case .uncertain:
                    throw ContainerLogLifecycleLedgerError.uncertainOwnership
                }
            }

            let acknowledgement = try await provider.closeSession(call)
            try validateWriterAcknowledgement(acknowledgement, call: call)
            guard acknowledgement.observation == .closed || acknowledgement.observation == .absent else {
                _ = try await ledger.markDetachedCleanupRecoveryRequired(expected)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
            return try await completeDetachedCleanup(
                expected,
                observation: acknowledgement.observation,
                using: provider
            )
        } catch {
            _ = try await markCleanupRecoveryIfCurrent(expected)
            throw error
        }
    }

    @discardableResult
    public func prepareReader(
        _ request: LogDriverReaderOpenRequestV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> StartedLogDriverReaderV1 {
        let reservation = try await ledger.reserveReader(request)
        let record: LoggingReaderOperationRecordV1
        let isFirstAttempt: Bool
        switch reservation {
        case .reserved(let reserved):
            record = reserved
            isFirstAttempt = true
        case .replay(let replay):
            record = replay
            isFirstAttempt = false
        }

        try await validateProvider(
            provider,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
        if isFirstAttempt {
            do {
                let started = try await provider.openReader(request)
                try await acceptReaderOpen(started, request: request, existing: record)
                return started
            } catch {
                _ = try await ledger.markReaderOpenRecoveryRequired(for: request)
                throw error
            }
        }
        switch record.result {
        case .candidateClosed:
            try await finishPendingEffectRemoval(
                kind: .readerCandidate,
                ownerID: request.readerSessionID,
                using: provider
            )
            throw ContainerLogLifecycleLedgerError.terminalOperation
        case .candidateClosing, .candidateRecoveryRequired:
            throw ContainerLogLifecycleLedgerError.terminalOperation
        case .activated(let session) where session.state != .active:
            if session.state == .closed || session.state == .tombstoned {
                try await finishPendingEffectRemoval(
                    kind: .readerSession,
                    ownerID: session.readerSessionID,
                    using: provider
                )
            }
            throw ContainerLogLifecycleLedgerError.terminalOperation
        default:
            break
        }
        return try await reconcileReaderOpen(request, record: record, provider: provider)
    }

    public func activateReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderSessionV1 {
        try await ledger.commitReaderSession(for: request)
    }

    @discardableResult
    public func closePreparedReader(
        _ request: LogDriverReaderOpenRequestV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderOperationRecordV1 {
        guard let record = try await ledger.readerOperation(for: request) else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        if case .candidateClosed = record.result {
            try await finishPendingEffectRemoval(
                kind: .readerCandidate,
                ownerID: request.readerSessionID,
                using: provider
            )
            return record
        }
        let shouldReconcile: Bool
        switch record.result {
        case .candidateClosing, .candidateRecoveryRequired:
            shouldReconcile = true
        case .prepared:
            shouldReconcile = false
        default:
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: "prepared reader candidate",
                actual: record.result.kindName
            )
        }

        let preparation = try await ledger.markReaderCandidateClosing(for: request)
        let call = try await readerCandidateCall(preparation, provider: provider)
        do {
            if shouldReconcile {
                let observation = try await provider.reconcileReader(call)
                try validateReaderAcknowledgement(observation, call: call)
                switch observation.observation {
                case .closed, .absent:
                    return try await completePreparedReader(
                        request,
                        preparation: preparation,
                        using: provider
                    )
                case .active, .closing:
                    break
                case .uncertain:
                    _ = try await ledger.markReaderCandidateRecoveryRequired(for: request)
                    throw ContainerLogLifecycleLedgerError.uncertainOwnership
                }
            }

            let acknowledgement = try await provider.closeReader(call)
            try validateReaderAcknowledgement(acknowledgement, call: call)
            guard acknowledgement.observation == .closed || acknowledgement.observation == .absent else {
                _ = try await ledger.markReaderCandidateRecoveryRequired(for: request)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
            return try await completePreparedReader(
                request,
                preparation: preparation,
                using: provider
            )
        } catch {
            _ = try await markReaderCandidateRecoveryIfCurrent(request)
            throw error
        }
    }

    @discardableResult
    public func closeReader(
        _ expected: LoggingReaderSessionV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderSessionV1 {
        if let actual = await ledger.readerSession(readerSessionID: expected.readerSessionID),
            actual != expected
        {
            guard Self.sameReaderIdentity(actual, expected) else {
                throw ContainerLogLifecycleLedgerError.staleSession
            }
            switch actual.state {
            case .active, .closing, .recoveryRequired:
                return try await closeReader(actual, using: provider)
            case .closed, .tombstoned:
                try await finishPendingEffectRemoval(
                    kind: .readerSession,
                    ownerID: actual.readerSessionID,
                    using: provider
                )
                return actual
            }
        }
        if expected.state == .closed || expected.state == .tombstoned {
            try await finishPendingEffectRemoval(
                kind: .readerSession,
                ownerID: expected.readerSessionID,
                using: provider
            )
            return expected
        }
        if expected.state == .recoveryRequired {
            return try await reconcileReaderClose(expected, using: provider)
        }
        let wasAlreadyClosing = expected.state == .closing
        let closing = try await ledger.beginReaderClose(expected)
        let call = try await readerActiveCall(closing, provider: provider)
        do {
            if wasAlreadyClosing {
                let observation = try await provider.reconcileReader(call)
                try validateReaderAcknowledgement(observation, call: call)
                if let closed = try await applyReaderCloseObservation(
                    observation,
                    closing: closing,
                    using: provider
                ) {
                    return closed
                }
            }

            let acknowledgement = try await provider.closeReader(call)
            try validateReaderAcknowledgement(acknowledgement, call: call)
            if let closed = try await applyReaderCloseObservation(
                acknowledgement,
                closing: closing,
                using: provider
            ) {
                return closed
            }
            _ = try await ledger.markReaderRecoveryRequired(closing)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        } catch {
            _ = try await markReaderRecoveryIfCurrent(closing)
            throw error
        }
    }

    @discardableResult
    public func reconcileReaderClose(
        _ expected: LoggingReaderSessionV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderSessionV1 {
        guard expected.state == .recoveryRequired else {
            throw ContainerLogLifecycleLedgerError.invalidTransition(
                expected: LoggingReaderSessionStateV1.recoveryRequired.rawValue,
                actual: expected.state.rawValue
            )
        }
        guard await ledger.readerSession(readerSessionID: expected.readerSessionID) == expected else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        let call = try await readerActiveCall(expected, provider: provider)
        let observation = try await provider.reconcileReader(call)
        try validateReaderAcknowledgement(observation, call: call)
        switch observation.observation {
        case .closed, .absent:
            let closing = try await ledger.resumeReaderClose(expected)
            return try await completeReaderClose(
                closing,
                acknowledgement: observation,
                using: provider
            )
        case .active, .closing:
            let closing = try await ledger.resumeReaderClose(expected)
            return try await closeReader(closing, using: provider)
        case .uncertain:
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        }
    }

    private func reconcileWriterStart(
        _ request: LogDriverStartRequestV1,
        record: LoggingWriterOperationRecordV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> StartedLogDriverSessionV1 {
        switch try await provider.reconcileStart(request) {
        case .prepared(let started):
            try await acceptWriterStart(started, request: request, existing: record)
            return started
        case .absent:
            switch record.result {
            case .reserved, .startRecoveryRequired:
                let started = try await provider.start(request)
                try await acceptWriterStart(started, request: request, existing: record)
                return started
            default:
                try await markWriterRecordRecovery(record, request: request)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
        case .conflict:
            throw ContainerLogLifecycleLedgerError.idempotencyConflict
        case .uncertain:
            try await markWriterRecordRecovery(record, request: request)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        }
    }

    private func acceptWriterStart(
        _ started: StartedLogDriverSessionV1,
        request: LogDriverStartRequestV1,
        existing: LoggingWriterOperationRecordV1
    ) async throws {
        guard started.receipt.request == request else {
            throw ContainerLogLifecycleLedgerError.providerResponseMismatch
        }
        let binding = try writerBinding(request)
        let reference = try await protectedEffects.seal(
            started.receipt.effectTokenMaterial,
            binding: binding
        )
        try reference.validateBinding(binding)

        if let existingReference = writerReference(in: existing.result) {
            try reference.validateExactReference(existingReference)
            return
        }
        let preparation = try writerPreparation(request, reference: reference)
        _ = try await ledger.recordWriterPreparation(preparation, for: request)
    }

    private func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1,
        record: LoggingReaderOperationRecordV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> StartedLogDriverReaderV1 {
        switch try await provider.reconcileReaderOpen(request) {
        case .prepared(let started):
            try await acceptReaderOpen(started, request: request, existing: record)
            return started
        case .absent:
            switch record.result {
            case .reserved, .openRecoveryRequired:
                let started = try await provider.openReader(request)
                try await acceptReaderOpen(started, request: request, existing: record)
                return started
            default:
                try await markReaderRecordRecovery(record, request: request)
                throw ContainerLogLifecycleLedgerError.uncertainOwnership
            }
        case .conflict:
            throw ContainerLogLifecycleLedgerError.idempotencyConflict
        case .uncertain:
            try await markReaderRecordRecovery(record, request: request)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        }
    }

    private func acceptReaderOpen(
        _ started: StartedLogDriverReaderV1,
        request: LogDriverReaderOpenRequestV1,
        existing: LoggingReaderOperationRecordV1
    ) async throws {
        guard started.receipt.request == request else {
            throw ContainerLogLifecycleLedgerError.providerResponseMismatch
        }
        let binding = try readerBinding(request)
        let reference = try await protectedEffects.seal(
            started.receipt.effectTokenMaterial,
            binding: binding
        )
        try reference.validateBinding(binding)

        if let existingReference = readerReference(in: existing.result) {
            try reference.validateExactReference(existingReference)
            return
        }
        let preparation = try readerPreparation(request, reference: reference)
        _ = try await ledger.recordReaderPreparation(preparation, for: request)
    }

    private func writerCandidateCall(
        _ preparation: LoggingSessionPreparationV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverSessionCallV1 {
        let reference = preparation.effectTokenReference
        try preparation.validateEffectReference(reference, owningControllerID: owningControllerID)
        try await validateProvider(
            provider,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration
        )
        let material = try await protectedEffects.resolve(
            reference,
            binding: reference.binding
        )
        let snapshot = await ledger.snapshot()
        guard
            snapshot.writerOperations.contains(where: { operation in
                switch operation.result {
                case .candidateClosing(let current), .candidateRecoveryRequired(let current):
                    return current == preparation
                default:
                    return false
                }
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return try LogDriverSessionCallV1(
            sessionID: preparation.sessionID,
            containerID: preparation.containerID,
            leaseGeneration: preparation.leaseGeneration,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            fence: LogDriverSessionFenceV1(
                candidateOperationGeneration: preparation.operationGeneration,
                processGeneration: preparation.candidateProcessGeneration,
                sandboxGeneration: preparation.candidateSandboxGeneration
            ),
            effectTokenMaterial: material
        )
    }

    private func writerActiveCall(
        _ activation: LoggingSessionActivationV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverSessionCallV1 {
        guard let reference = activation.effectTokenReference else {
            throw ContainerLogLifecycleLedgerError.terminalOperation
        }
        try activation.validateEffectReference(reference, owningControllerID: owningControllerID)
        try await validateProvider(
            provider,
            providerID: activation.providerID,
            providerGeneration: activation.providerGeneration
        )
        let material = try await protectedEffects.resolve(
            reference,
            binding: reference.binding
        )
        guard await ledger.writerActivation(sessionID: activation.sessionID) == activation else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return try LogDriverSessionCallV1(
            sessionID: activation.sessionID,
            containerID: activation.containerID,
            leaseGeneration: activation.leaseGeneration,
            providerID: activation.providerID,
            providerGeneration: activation.providerGeneration,
            fence: LogDriverSessionFenceV1(
                activeProcessGeneration: activation.activeProcessGeneration,
                sandboxGeneration: activation.activeSandboxGeneration
            ),
            effectTokenMaterial: material
        )
    }

    private func detachedCleanupCall(
        _ cleanup: LoggingDetachedCleanupV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverSessionCallV1 {
        guard let reference = cleanup.effectTokenReference else {
            throw ContainerLogLifecycleLedgerError.terminalOperation
        }
        try cleanup.validateEffectReference(reference, owningControllerID: owningControllerID)
        try await validateProvider(
            provider,
            providerID: cleanup.providerID,
            providerGeneration: cleanup.providerGeneration
        )
        let material = try await protectedEffects.resolve(
            reference,
            binding: reference.binding
        )
        guard await ledger.detachedCleanup(cleanupID: cleanup.cleanupID) == cleanup else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return try LogDriverSessionCallV1(
            sessionID: cleanup.sessionID,
            containerID: cleanup.containerID,
            leaseGeneration: cleanup.leaseGeneration,
            providerID: cleanup.providerID,
            providerGeneration: cleanup.providerGeneration,
            fence: LogDriverSessionFenceV1(
                activeProcessGeneration: cleanup.activeProcessGeneration,
                sandboxGeneration: cleanup.activeSandboxGeneration
            ),
            effectTokenMaterial: material
        )
    }

    private func readerCandidateCall(
        _ preparation: LoggingReaderPreparationV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverReaderCallV1 {
        let reference = preparation.effectTokenReference
        try preparation.validateEffectReference(reference, owningControllerID: owningControllerID)
        try await validateProvider(
            provider,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration
        )
        let material = try await protectedEffects.resolve(
            reference,
            binding: reference.binding
        )
        let snapshot = await ledger.snapshot()
        guard
            snapshot.readerOperations.contains(where: { operation in
                switch operation.result {
                case .candidateClosing(let current), .candidateRecoveryRequired(let current):
                    return current == preparation
                default:
                    return false
                }
            })
        else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return try LogDriverReaderCallV1(
            readerSessionID: preparation.readerSessionID,
            containerID: preparation.containerID,
            leaseGeneration: preparation.leaseGeneration,
            providerID: preparation.providerID,
            providerGeneration: preparation.providerGeneration,
            source: preparation.source,
            effectTokenMaterial: material
        )
    }

    private func readerActiveCall(
        _ session: LoggingReaderSessionV1,
        provider: any ContainerLogDriverProvider
    ) async throws -> LogDriverReaderCallV1 {
        guard let reference = session.effectTokenReference else {
            throw ContainerLogLifecycleLedgerError.terminalOperation
        }
        try session.validateEffectReference(reference, owningControllerID: owningControllerID)
        try await validateProvider(
            provider,
            providerID: session.providerID,
            providerGeneration: session.providerGeneration
        )
        let material = try await protectedEffects.resolve(
            reference,
            binding: reference.binding
        )
        guard await ledger.readerSession(readerSessionID: session.readerSessionID) == session else {
            throw ContainerLogLifecycleLedgerError.staleSession
        }
        return try LogDriverReaderCallV1(
            readerSessionID: session.readerSessionID,
            containerID: session.containerID,
            leaseGeneration: session.leaseGeneration,
            providerID: session.providerID,
            providerGeneration: session.providerGeneration,
            source: session.source,
            effectTokenMaterial: material
        )
    }

    private func completePreparedWriter(
        _ request: LogDriverStartRequestV1,
        preparation: LoggingSessionPreparationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingWriterOperationRecordV1 {
        let record = try await ledger.completeWriterCandidate(for: request)
        try await finishPendingEffectRemoval(
            kind: .writerCandidate,
            ownerID: preparation.sessionID,
            using: provider
        )
        return record
    }

    private func completeWriterClose(
        _ draining: LoggingSessionActivationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingSessionActivationV1 {
        let closed = try await ledger.completeWriterClose(draining)
        try await finishPendingEffectRemoval(
            kind: .writerSession,
            ownerID: draining.sessionID,
            using: provider
        )
        return closed
    }

    private func applyWriterFenceObservation(
        _ acknowledgement: LogDriverSessionAcknowledgementV1,
        draining: LoggingSessionActivationV1,
        cleanupID: String,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingWriterDeadlineOutcomeV1? {
        switch acknowledgement.observation {
        case .writerFenced:
            guard let digest = acknowledgement.writerFenceReceiptDigest else {
                throw ContainerLogLifecycleLedgerError.providerResponseMismatch
            }
            let cleanup = try await ledger.transferWriterToDetachedCleanup(
                draining,
                cleanupID: cleanupID,
                writerFenceReceiptDigest: digest
            )
            return .detached(cleanup)
        case .closed, .absent:
            return .closed(
                try await completeWriterClose(draining, using: provider)
            )
        case .active, .draining:
            return nil
        case .uncertain:
            _ = try await ledger.markWriterRecoveryRequired(draining)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        }
    }

    private func completeDetachedCleanup(
        _ cleanup: LoggingDetachedCleanupV1,
        observation: LogDriverSessionObservationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingDetachedCleanupV1 {
        let outcomeDigest = Self.writerCloseOutcomeDigest(
            cleanup: cleanup,
            observation: observation
        )
        let completed = try await ledger.completeDetachedCleanup(
            cleanup,
            providerCloseOutcomeDigest: outcomeDigest
        )
        try await finishPendingEffectRemoval(
            kind: .detachedCleanup,
            ownerID: cleanup.cleanupID,
            using: provider
        )
        return completed
    }

    private func completePreparedReader(
        _ request: LogDriverReaderOpenRequestV1,
        preparation: LoggingReaderPreparationV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderOperationRecordV1 {
        let record = try await ledger.completeReaderCandidate(for: request)
        try await finishPendingEffectRemoval(
            kind: .readerCandidate,
            ownerID: preparation.readerSessionID,
            using: provider
        )
        return record
    }

    private func applyReaderCloseObservation(
        _ acknowledgement: LogDriverReaderAcknowledgementV1,
        closing: LoggingReaderSessionV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderSessionV1? {
        switch acknowledgement.observation {
        case .closed, .absent:
            return try await completeReaderClose(
                closing,
                acknowledgement: acknowledgement,
                using: provider
            )
        case .active, .closing:
            return nil
        case .uncertain:
            _ = try await ledger.markReaderRecoveryRequired(closing)
            throw ContainerLogLifecycleLedgerError.uncertainOwnership
        }
    }

    private func completeReaderClose(
        _ closing: LoggingReaderSessionV1,
        acknowledgement: LogDriverReaderAcknowledgementV1,
        using provider: any ContainerLogDriverProvider
    ) async throws -> LoggingReaderSessionV1 {
        let digest =
            acknowledgement.terminalOutcomeDigest
            ?? Self.readerAbsentOutcomeDigest(session: closing)
        let closed = try await ledger.completeReaderClose(
            closing,
            terminalOutcomeDigest: digest
        )
        try await finishPendingEffectRemoval(
            kind: .readerSession,
            ownerID: closing.readerSessionID,
            using: provider
        )
        return closed
    }

    private func finishPendingEffectRemoval(
        kind: LoggingEffectRemovalKindV1,
        ownerID: String,
        using provider: (any ContainerLogDriverProvider)? = nil
    ) async throws {
        guard let pending = await ledger.pendingEffectRemoval(kind: kind, ownerID: ownerID) else {
            return
        }
        try await finishEffectRemoval(pending, using: provider)
    }

    private func finishEffectRemoval(
        _ pending: LoggingEffectRemovalPendingV1,
        using provider: (any ContainerLogDriverProvider)?
    ) async throws {
        if let provider {
            let binding = pending.effectTokenReference.binding
            try await validateProvider(
                provider,
                providerID: binding.providerID,
                providerGeneration: binding.providerGeneration
            )
            try await provider.reclaimTerminalEffect(
                LogDriverTerminalEffectReclaimV1(
                    kind: pending.kind,
                    effectID: binding.effectID,
                    providerID: binding.providerID,
                    providerGeneration: binding.providerGeneration
                )
            )
        }
        try await removeEffect(pending.effectTokenReference)
        try await ledger.acknowledgeEffectRemoval(pending)
    }

    private func removeEffect(_ reference: ProtectedLoggingEffectReferenceV1) async throws {
        try reference.validateBinding(reference.binding)
        try await protectedEffects.remove(reference, binding: reference.binding)
    }

    private func markWriterRecordRecovery(
        _ record: LoggingWriterOperationRecordV1,
        request: LogDriverStartRequestV1
    ) async throws {
        switch record.result {
        case .reserved, .startRecoveryRequired:
            _ = try await ledger.markWriterStartRecoveryRequired(for: request)
        case .prepared, .candidateClosing, .candidateRecoveryRequired:
            _ = try await ledger.markWriterCandidateRecoveryRequired(for: request)
        case .activated(let activation):
            _ = try await ledger.markWriterRecoveryRequired(activation)
        case .candidateClosed:
            break
        }
    }

    private func markReaderRecordRecovery(
        _ record: LoggingReaderOperationRecordV1,
        request: LogDriverReaderOpenRequestV1
    ) async throws {
        switch record.result {
        case .reserved, .openRecoveryRequired:
            _ = try await ledger.markReaderOpenRecoveryRequired(for: request)
        case .prepared, .candidateClosing, .candidateRecoveryRequired:
            _ = try await ledger.markReaderCandidateRecoveryRequired(for: request)
        case .activated(let session):
            _ = try await ledger.markReaderRecoveryRequired(session)
        case .candidateClosed:
            break
        }
    }

    private func markWriterRecoveryIfCurrent(
        _ expected: LoggingSessionActivationV1
    ) async throws -> LoggingSessionActivationV1? {
        guard await ledger.writerActivation(sessionID: expected.sessionID) == expected else {
            return nil
        }
        return try await ledger.markWriterRecoveryRequired(expected)
    }

    private func markWriterCandidateRecoveryIfCurrent(
        _ request: LogDriverStartRequestV1
    ) async throws -> LoggingSessionPreparationV1? {
        guard let record = try await ledger.writerOperation(for: request) else {
            return nil
        }
        switch record.result {
        case .prepared, .candidateClosing, .candidateRecoveryRequired:
            return try await ledger.markWriterCandidateRecoveryRequired(for: request)
        default:
            return nil
        }
    }

    private func markCleanupRecoveryIfCurrent(
        _ expected: LoggingDetachedCleanupV1
    ) async throws -> LoggingDetachedCleanupV1? {
        guard await ledger.detachedCleanup(cleanupID: expected.cleanupID) == expected else {
            return nil
        }
        return try await ledger.markDetachedCleanupRecoveryRequired(expected)
    }

    private func markReaderRecoveryIfCurrent(
        _ expected: LoggingReaderSessionV1
    ) async throws -> LoggingReaderSessionV1? {
        guard await ledger.readerSession(readerSessionID: expected.readerSessionID) == expected else {
            return nil
        }
        return try await ledger.markReaderRecoveryRequired(expected)
    }

    private func markReaderCandidateRecoveryIfCurrent(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LoggingReaderPreparationV1? {
        guard let record = try await ledger.readerOperation(for: request) else {
            return nil
        }
        switch record.result {
        case .prepared, .candidateClosing, .candidateRecoveryRequired:
            return try await ledger.markReaderCandidateRecoveryRequired(for: request)
        default:
            return nil
        }
    }

    private func validateProvider(
        _ provider: any ContainerLogDriverProvider,
        providerID: String,
        providerGeneration: UInt64
    ) async throws {
        let descriptor = try await provider.descriptor
        guard descriptor.providerIdentity.id == providerID,
            descriptor.providerGeneration == providerGeneration
        else {
            throw ContainerLogLifecycleLedgerError.providerIdentityMismatch
        }
    }

    private func validateWriterAcknowledgement(
        _ acknowledgement: LogDriverSessionAcknowledgementV1,
        call: LogDriverSessionCallV1
    ) throws {
        guard acknowledgement.call.identity == call.identity,
            acknowledgement.call.effectTokenMaterial.isByteIdentical(
                to: call.effectTokenMaterial
            )
        else {
            throw ContainerLogLifecycleLedgerError.providerResponseMismatch
        }
    }

    private func validateReaderAcknowledgement(
        _ acknowledgement: LogDriverReaderAcknowledgementV1,
        call: LogDriverReaderCallV1
    ) throws {
        guard acknowledgement.call.identity == call.identity,
            acknowledgement.call.effectTokenMaterial.isByteIdentical(
                to: call.effectTokenMaterial
            )
        else {
            throw ContainerLogLifecycleLedgerError.providerResponseMismatch
        }
    }

    private func writerBinding(
        _ request: LogDriverStartRequestV1
    ) throws -> ProtectedLoggingEffectBindingV1 {
        try ProtectedLoggingEffectBindingV1(
            effectID: request.sessionID,
            owningControllerID: owningControllerID,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
    }

    private func readerBinding(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> ProtectedLoggingEffectBindingV1 {
        try ProtectedLoggingEffectBindingV1(
            effectID: request.readerSessionID,
            owningControllerID: owningControllerID,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
    }

    private func writerPreparation(
        _ request: LogDriverStartRequestV1,
        reference: ProtectedLoggingEffectReferenceV1
    ) throws -> LoggingSessionPreparationV1 {
        try LoggingSessionPreparationV1(
            operationGeneration: request.operationGeneration,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: request.semanticRequestDigest,
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            candidateProcessGeneration: request.candidateProcessGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            candidateSandboxGeneration: request.candidateSandboxGeneration,
            effectTokenReference: reference
        )
    }

    private func readerPreparation(
        _ request: LogDriverReaderOpenRequestV1,
        reference: ProtectedLoggingEffectReferenceV1
    ) throws -> LoggingReaderPreparationV1 {
        try LoggingReaderPreparationV1(
            operationGeneration: request.operationGeneration,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: request.semanticRequestDigest,
            readerSessionID: request.readerSessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            source: request.source,
            effectTokenReference: reference
        )
    }

    private func writerReference(
        in result: LoggingWriterOperationResultV1
    ) -> ProtectedLoggingEffectReferenceV1? {
        result.preparation?.effectTokenReference ?? result.activation?.effectTokenReference
    }

    private func readerReference(
        in result: LoggingReaderOperationResultV1
    ) -> ProtectedLoggingEffectReferenceV1? {
        result.preparation?.effectTokenReference ?? result.session?.effectTokenReference
    }

    private static func writerCloseOutcomeDigest(
        cleanup: LoggingDetachedCleanupV1,
        observation: LogDriverSessionObservationV1
    ) -> String {
        sha256(
            "writer-close\n\(cleanup.sessionID)\n\(cleanup.containerID)\n"
                + "\(cleanup.leaseGeneration)\n\(cleanup.activeProcessGeneration)\n"
                + "\(cleanup.providerID)\n\(cleanup.providerGeneration)\n"
                + "\(observation.rawValue)"
        )
    }

    private static func readerAbsentOutcomeDigest(
        session: LoggingReaderSessionV1
    ) -> String {
        sha256(
            "reader-absent\n\(session.readerSessionID)\n\(session.containerID)\n"
                + "\(session.leaseGeneration)\n\(session.providerID)\n"
                + "\(session.providerGeneration)"
        )
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sameWriterIdentity(
        _ lhs: LoggingSessionActivationV1,
        _ rhs: LoggingSessionActivationV1
    ) -> Bool {
        guard
            lhs.sessionID == rhs.sessionID,
            lhs.containerID == rhs.containerID,
            lhs.leaseGeneration == rhs.leaseGeneration,
            lhs.activeProcessGeneration == rhs.activeProcessGeneration,
            lhs.providerID == rhs.providerID,
            lhs.providerGeneration == rhs.providerGeneration,
            lhs.activeSandboxGeneration == rhs.activeSandboxGeneration
        else {
            return false
        }
        if let lhsReference = lhs.effectTokenReference,
            let rhsReference = rhs.effectTokenReference
        {
            return lhsReference == rhsReference
        }
        return lhs.effectTokenReference == nil || rhs.effectTokenReference == nil
    }

    private static func sameReaderIdentity(
        _ lhs: LoggingReaderSessionV1,
        _ rhs: LoggingReaderSessionV1
    ) -> Bool {
        guard
            lhs.readerSessionID == rhs.readerSessionID,
            lhs.containerID == rhs.containerID,
            lhs.leaseGeneration == rhs.leaseGeneration,
            lhs.providerID == rhs.providerID,
            lhs.providerGeneration == rhs.providerGeneration,
            lhs.source == rhs.source
        else {
            return false
        }
        if let lhsReference = lhs.effectTokenReference,
            let rhsReference = rhs.effectTokenReference
        {
            return lhsReference == rhsReference
        }
        return lhs.effectTokenReference == nil || rhs.effectTokenReference == nil
    }

    private static func sameCleanupIdentity(
        _ lhs: LoggingDetachedCleanupV1,
        _ rhs: LoggingDetachedCleanupV1
    ) -> Bool {
        lhs.cleanupID == rhs.cleanupID
            && lhs.sessionID == rhs.sessionID
            && lhs.containerID == rhs.containerID
            && lhs.leaseGeneration == rhs.leaseGeneration
            && lhs.activeProcessGeneration == rhs.activeProcessGeneration
            && lhs.providerID == rhs.providerID
            && lhs.providerGeneration == rhs.providerGeneration
            && lhs.activeSandboxGeneration == rhs.activeSandboxGeneration
            && lhs.writerFenceReceiptDigest == rhs.writerFenceReceiptDigest
    }

    private static func cleanup(
        _ cleanup: LoggingDetachedCleanupV1,
        matches activation: LoggingSessionActivationV1
    ) -> Bool {
        guard
            cleanup.sessionID == activation.sessionID,
            cleanup.containerID == activation.containerID,
            cleanup.leaseGeneration == activation.leaseGeneration,
            cleanup.activeProcessGeneration == activation.activeProcessGeneration,
            cleanup.providerID == activation.providerID,
            cleanup.providerGeneration == activation.providerGeneration,
            cleanup.activeSandboxGeneration == activation.activeSandboxGeneration
        else {
            return false
        }
        if let cleanupReference = cleanup.effectTokenReference,
            let activationReference = activation.effectTokenReference
        {
            return cleanupReference == activationReference
        }
        return cleanup.effectTokenReference == nil
    }
}
