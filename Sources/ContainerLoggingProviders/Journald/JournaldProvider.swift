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

import ContainerResource
import CryptoKit
import Foundation

public enum JournaldLogDriverContract {
    public static let providerIdentity = LogDriverProviderIdentity(
        id: "com.apple.container.logging.providers.journald",
        version: "1",
        kind: .linuxService
    )

    public static func descriptor(
        providerGeneration: UInt64 = 1
    ) -> LogDriverDescriptor {
        do {
            return try LogDriverDescriptor(
                driver: "journald",
                providerIdentity: providerIdentity,
                providerGeneration: providerGeneration,
                placement: .engineLinuxSandbox,
                trust: .signed,
                options: [
                    option("env"),
                    option("env-regex", kind: .providerRegularExpression),
                    option("labels"),
                    option(
                        "labels-regex",
                        kind: .providerRegularExpression
                    ),
                    option("max-buffer-size", kind: .size),
                    LogDriverOptionDescriptor(
                        name: "mode",
                        valueKind: .string,
                        allowedValues: ["", "blocking", "non-blocking"]
                    ),
                    option("tag", kind: .tagTemplate),
                ],
                crossOptionConstraints: [
                    LogDriverCrossOptionConstraint(
                        whenOptionPresent: "max-buffer-size",
                        requiredOption: "mode",
                        requiredAllowedValues: ["non-blocking"]
                    )
                ],
                capabilities: LogDriverCapabilities(
                    deliveryModes: [.blocking, .nonBlocking],
                    nativeRead: true,
                    readFilters: [
                        .stdout,
                        .stderr,
                        .follow,
                        .tail,
                        .since,
                        .until,
                        .timestamps,
                        .details,
                    ],
                    supportsDualCache: false,
                    supportsDockerPluginProtocol: false,
                    requiresDeliverySession: true,
                    logPathVisibility: .none,
                    fileDefaults: nil
                )
            )
        } catch {
            preconditionFailure("invalid journald contract: \(error)")
        }
    }

    private static func option(
        _ name: String,
        kind: LogDriverOptionValueKind = .string
    ) -> LogDriverOptionDescriptor {
        LogDriverOptionDescriptor(
            name: name,
            valueKind: kind,
            validationPhase: .start
        )
    }
}

public struct JournaldConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let configuration: JournaldDriverConfiguration

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        configuration: JournaldDriverConfiguration
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.configuration = configuration
    }
}

public protocol JournaldConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> JournaldConfigurationBinding
}

/// Exact, idempotent writer material submitted to the protected Linux service.
public struct JournaldWriterOpenRequest: Equatable, Sendable {
    public let request: LogDriverStartRequestV1
    public let configuration: JournaldDriverConfiguration
    public let epoch: String

    public init(
        request: LogDriverStartRequestV1,
        configuration: JournaldDriverConfiguration,
        epoch: String
    ) throws {
        guard
            request.candidateSandboxGeneration != nil,
            configuration.containerID == request.containerID,
            !epoch.isEmpty
        else {
            throw JournaldProviderError.invalidSessionFence
        }
        self.request = request
        self.configuration = configuration
        self.epoch = epoch
    }
}

/// Narrow client boundary implemented by the signed journald service workload.
/// Writer/open calls are idempotent by their complete request identity. A
/// response loss must therefore reconcile to the same writer, never create a
/// second journal epoch or reader stream.
public protocol JournaldService: Sendable {
    func activeSandboxGeneration() async throws -> UInt64
    func openWriter(_ request: JournaldWriterOpenRequest) async throws
    func write(sessionID: String, entry: JournaldEntry) async throws
    func flushWriter(
        sessionID: String,
        deadline: ContinuousClock.Instant
    ) async throws
    func closeWriter(
        sessionID: String,
        fenced: Bool,
        deadline: ContinuousClock.Instant
    ) async throws
    func reclaimWriter(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) async throws
    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> any ContainerLogReader
    func reclaimReader(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) async throws
}

public protocol JournaldRandomBytesGenerating: Sendable {
    func makeBytes(count: Int) throws -> Data
}

public struct RandomJournaldBytesGenerator: JournaldRandomBytesGenerating {
    public init() {}

    public func makeBytes(count: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            var value = generator.next()
            withUnsafeBytes(of: &value) { bytes in
                data.append(contentsOf: bytes.prefix(count - data.count))
            }
        }
        return data
    }
}

public enum JournaldSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

public actor JournaldDriverSession: ContainerLogDriverSession {
    private let sessionID: String
    private let service: any JournaldService
    private var encoder: JournaldEntryEncoder
    private var state: JournaldSessionState = .active

    private init(
        sessionID: String,
        service: any JournaldService,
        encoder: JournaldEntryEncoder
    ) {
        self.sessionID = sessionID
        self.service = service
        self.encoder = encoder
    }

    public static func open(
        request: LogDriverStartRequestV1,
        configuration: JournaldDriverConfiguration,
        epoch: String,
        service: any JournaldService
    ) async throws -> JournaldDriverSession {
        let open = try JournaldWriterOpenRequest(
            request: request,
            configuration: configuration,
            epoch: epoch
        )
        try await service.openWriter(open)
        return try JournaldDriverSession(
            sessionID: request.sessionID,
            service: service,
            encoder: JournaldEntryEncoder(
                configuration: configuration,
                epoch: epoch
            )
        )
    }

    public func write(_ record: ContainerLogRecordV2) async throws {
        guard state == .active else {
            throw JournaldProviderError.transportClosed
        }
        let entry = try encoder.encode(record)
        try await service.write(sessionID: sessionID, entry: entry)
    }

    public func flush(deadline: ContinuousClock.Instant) async throws {
        guard state == .active else {
            throw JournaldProviderError.transportClosed
        }
        guard ContinuousClock().now < deadline else {
            throw JournaldProviderError.deadlineExceeded
        }
        try await service.flushWriter(
            sessionID: sessionID,
            deadline: deadline
        )
    }

    public func close(deadline: ContinuousClock.Instant) async throws {
        try await close(fenced: false, deadline: deadline)
    }

    public func closeUsingPolicy() async throws {
        try await close(
            fenced: false,
            deadline: ContinuousClock().now + .seconds(10)
        )
    }

    public func fence() async throws {
        try await close(
            fenced: true,
            deadline: ContinuousClock().now + .seconds(5)
        )
    }

    public func currentState() -> JournaldSessionState {
        state
    }

    private func close(
        fenced: Bool,
        deadline: ContinuousClock.Instant
    ) async throws {
        switch state {
        case .closed:
            return
        case .writerFenced:
            if !fenced {
                state = .closed
            }
            return
        case .closing:
            throw JournaldProviderError.transportClosed
        case .active:
            break
        }
        guard ContinuousClock().now < deadline else {
            throw JournaldProviderError.deadlineExceeded
        }
        state = .closing
        do {
            try await service.closeWriter(
                sessionID: sessionID,
                fenced: fenced,
                deadline: deadline
            )
            state = fenced ? .writerFenced : .closed
        } catch {
            state = fenced ? .writerFenced : .closed
            throw error
        }
    }
}

private actor JournaldTrackedReader: ContainerLogReader {
    private let reader: any ContainerLogReader
    private var closed = false

    init(reader: any ContainerLogReader) {
        self.reader = reader
    }

    func next() async throws -> ContainerLogReaderEventV1 {
        guard !closed else {
            throw ContainerLogReaderError.alreadyEnded
        }
        let event = try await reader.next()
        if event == .endOfStream {
            closed = true
        }
        return event
    }

    func cancel() async {
        guard !closed else {
            return
        }
        closed = true
        await reader.cancel()
    }

    func isClosed() -> Bool {
        closed
    }
}

public actor JournaldLogDriverProvider: ContainerLogDriverProvider {
    private struct SessionEntry: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: JournaldDriverSession
        let fenceReceiptDigest: String

        var started: StartedLogDriverSessionV1 {
            StartedLogDriverSessionV1(
                receipt: LogDriverStartReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                session: session
            )
        }
    }

    private struct ReaderEntry: Sendable {
        let request: LogDriverReaderOpenRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let reader: JournaldTrackedReader
        let terminalOutcomeDigest: String

        var started: StartedLogDriverReaderV1 {
            StartedLogDriverReaderV1(
                receipt: LogDriverReaderOpenReceiptV1(
                    request: request,
                    effectTokenMaterial: token
                ),
                reader: reader
            )
        }
    }

    private let descriptorValue: LogDriverDescriptor
    private let configurationResolver: any JournaldConfigurationResolving
    private let service: any JournaldService
    private let random: any JournaldRandomBytesGenerating
    private var sessions = [String: SessionEntry]()
    private var readers = [String: ReaderEntry]()
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        providerGeneration: UInt64 = 1,
        configurationResolver: any JournaldConfigurationResolving,
        service: any JournaldService,
        random: any JournaldRandomBytesGenerating = RandomJournaldBytesGenerator()
    ) {
        self.descriptorValue = JournaldLogDriverContract.descriptor(
            providerGeneration: providerGeneration
        )
        self.configurationResolver = configurationResolver
        self.service = service
        self.random = random
    }

    public var descriptor: LogDriverDescriptor {
        get async throws { descriptorValue }
    }

    public func activeSandboxGeneration() async throws -> UInt64 {
        let generation = try await service.activeSandboxGeneration()
        guard generation > 0 else {
            throw JournaldProviderError.invalidSessionFence
        }
        return generation
    }

    /// Journald history is owned by the stable service journal rather than a
    /// provider-generation actor. Readiness plus the exact immutable contract
    /// therefore revalidates the same journal epoch for the replacement.
    public func migrateHistory(
        _ request: LogDriverHistoryMigrationRequestV1
    ) async throws -> LogDriverHistoryMigrationReceiptV1 {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.targetProviderGeneration
                == descriptorValue.providerGeneration,
            request.contractDigest
                == descriptorValue.optionContractDigest,
            try await service.activeSandboxGeneration() > 0
        else {
            throw LogDriverHistoryMigrationError.receiptMismatch
        }
        return try LogDriverHistoryMigrationReceiptV1(
            request: request,
            providerOutcomeDigest: Self.digest(
                "journald-history-migration-v1",
                values: [
                    request.containerID,
                    String(request.sourceLeaseGeneration),
                    String(request.targetLeaseGeneration),
                    request.providerID,
                    String(request.sourceProviderGeneration),
                    String(request.targetProviderGeneration),
                    request.contractDigest,
                    request.terminalHistoryDigest,
                ]
            )
        )
    }

    public func exportHistoryForHandoff(
        _ request: LogDriverHistoryHandoffExportRequestV1
    ) async throws -> LogDriverHistoryHandoffExportReceiptV1 {
        guard
            request.sourceProviderID == descriptorValue.providerIdentity.id,
            request.sourceProviderGeneration == descriptorValue.providerGeneration,
            request.sourceContractDigest == descriptorValue.optionContractDigest,
            descriptorValue.capabilities.nativeRead,
            try await service.activeSandboxGeneration() > 0
        else {
            throw LogDriverHistoryHandoffError.receiptMismatch
        }
        return try LogDriverHistoryHandoffExportReceiptV1(
            request: request,
            providerOutcomeDigestSHA256: Self.digest(
                "journald-history-handoff-export-v1",
                values: Self.exportIdentity(request)
            )
        )
    }

    public func preflightHistoryHandoff(
        _ request: LogDriverHistoryHandoffDestinationRequestV1
    ) async throws {
        guard
            request.destinationProviderID == descriptorValue.providerIdentity.id,
            request.destinationProviderGeneration == descriptorValue.providerGeneration,
            request.destinationContractDigest == descriptorValue.optionContractDigest,
            request.exportReceipt.request.sourceProviderID
                == descriptorValue.providerIdentity.id,
            request.exportReceipt.request.sourceContractDigest
                == descriptorValue.optionContractDigest,
            descriptorValue.capabilities.nativeRead,
            try await service.activeSandboxGeneration() > 0
        else {
            throw LogDriverHistoryHandoffError.receiptMismatch
        }
    }

    public func promoteHistoryHandoff(
        _ request: LogDriverHistoryHandoffPromotionRequestV1
    ) async throws -> LogDriverHistoryHandoffPromotionReceiptV1 {
        try await preflightHistoryHandoff(request.destination)
        return try LogDriverHistoryHandoffPromotionReceiptV1(
            request: request,
            providerOutcomeDigestSHA256: Self.digest(
                "journald-history-handoff-promotion-v1",
                values: [
                    request.destination.exportReceipt.exportReceiptDigestSHA256,
                    request.destination.manifestDigestSHA256,
                    String(request.destination.destinationLeaseGeneration),
                    request.destination.destinationProviderID,
                    String(request.destination.destinationProviderGeneration),
                    request.destination.destinationContractDigest,
                    request.commitDigestSHA256,
                    request.handoffChainHeadDigestSHA256,
                ]
            )
        )
    }

    public func activateHistoryHandoff(
        _ request: LogDriverHistoryHandoffActivationRequestV1
    ) async throws {
        try await preflightHistoryHandoff(request.promotionReceipt.request.destination)
        let expected = try await promoteHistoryHandoff(
            request.promotionReceipt.request
        )
        guard expected == request.promotionReceipt else {
            throw LogDriverHistoryHandoffError.receiptMismatch
        }
    }

    public func start(
        _ request: LogDriverStartRequestV1
    ) async throws -> StartedLogDriverSessionV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        guard request.candidateSandboxGeneration != nil else {
            throw JournaldProviderError.invalidSessionFence
        }
        switch existingStart(for: request) {
        case .prepared(let started):
            return started
        case .conflict:
            throw JournaldProviderError.idempotencyConflict
        case .absent, .uncertain:
            break
        }

        let binding = try await configurationResolver.configuration(for: request)
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: random.makeBytes(count: 32)
        )
        let epoch = try random.makeBytes(count: 32).map {
            String(format: "%02x", $0)
        }.joined()
        let session = try await JournaldDriverSession.open(
            request: request,
            configuration: binding.configuration,
            epoch: epoch,
            service: service
        )
        let entry = SessionEntry(
            request: request,
            token: token,
            session: session,
            fenceReceiptDigest: Self.digest(
                "writer-fence",
                values: Self.writerIdentity(request)
            )
        )
        sessions[request.sessionID] = entry
        return entry.started
    }

    public func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) throws -> LogDriverStartReconciliationV1 {
        try validateProviderIdentity(request)
        return existingStart(for: request)
    }

    public func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            return try acknowledgement(request, observation: .absent)
        }
        try validate(request, against: entry)
        switch await entry.session.currentState() {
        case .active:
            return try acknowledgement(request, observation: .active)
        case .closing:
            return try acknowledgement(request, observation: .draining)
        case .writerFenced:
            return try acknowledgement(
                request,
                observation: .writerFenced,
                fenceReceiptDigest: entry.fenceReceiptDigest
            )
        case .closed:
            return try acknowledgement(request, observation: .closed)
        }
    }

    public func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            return try acknowledgement(request, observation: .absent)
        }
        try validate(request, against: entry)
        if await entry.session.currentState() == .closed {
            return try acknowledgement(request, observation: .closed)
        }
        try await entry.session.fence()
        return try acknowledgement(
            request,
            observation: .writerFenced,
            fenceReceiptDigest: entry.fenceReceiptDigest
        )
    }

    public func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            return try acknowledgement(request, observation: .absent)
        }
        try validate(request, against: entry)
        try await entry.session.closeUsingPolicy()
        return try acknowledgement(request, observation: .closed)
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        switch existingReader(for: request) {
        case .prepared(let started):
            return started
        case .conflict:
            throw JournaldProviderError.idempotencyConflict
        case .absent, .uncertain:
            break
        }
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: random.makeBytes(count: 32)
        )
        let reader = JournaldTrackedReader(
            reader: try await service.openReader(request)
        )
        let entry = ReaderEntry(
            request: request,
            token: token,
            reader: reader,
            terminalOutcomeDigest: Self.digest(
                "reader-terminal",
                values: [
                    request.readerSessionID,
                    request.containerID,
                    String(request.leaseGeneration),
                    request.providerID,
                    String(request.providerGeneration),
                ]
            )
        )
        readers[request.readerSessionID] = entry
        return entry.started
    }

    public func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> LogDriverReaderOpenReconciliationV1 {
        try validateProviderIdentity(request)
        return existingReader(for: request)
    }

    public func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = readers[request.readerSessionID] else {
            return try readerAcknowledgement(request, observation: .absent)
        }
        try validate(request, against: entry)
        if await entry.reader.isClosed() {
            return try readerAcknowledgement(
                request,
                observation: .closed,
                terminalOutcomeDigest: entry.terminalOutcomeDigest
            )
        }
        return try readerAcknowledgement(request, observation: .active)
    }

    public func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = readers[request.readerSessionID] else {
            return try readerAcknowledgement(request, observation: .absent)
        }
        try validate(request, against: entry)
        await entry.reader.cancel()
        return try readerAcknowledgement(
            request,
            observation: .closed,
            terminalOutcomeDigest: entry.terminalOutcomeDigest
        )
    }

    public func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
        switch request.kind {
        case .writerCandidate, .writerSession, .detachedCleanup:
            if let entry = sessions[request.effectID] {
                switch await entry.session.currentState() {
                case .writerFenced, .closed:
                    break
                case .active, .closing:
                    throw JournaldProviderError.invalidSessionFence
                }
            }
            try await service.reclaimWriter(
                sessionID: request.effectID,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
            sessions.removeValue(forKey: request.effectID)
        case .readerCandidate, .readerSession:
            if let entry = readers[request.effectID],
                !(await entry.reader.isClosed())
            {
                throw JournaldProviderError.invalidSessionFence
            }
            try await service.reclaimReader(
                sessionID: request.effectID,
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
            readers.removeValue(forKey: request.effectID)
        }
    }

    private func existingStart(
        for request: LogDriverStartRequestV1
    ) -> LogDriverStartReconciliationV1 {
        if let entry = sessions[request.sessionID] {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .prepared(entry.started)
            case .conflict, .distinctScope:
                return .conflict
            }
        }
        for entry in sessions.values {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .prepared(entry.started)
            case .conflict:
                return .conflict
            case .distinctScope:
                continue
            }
        }
        return .absent
    }

    private func existingReader(
        for request: LogDriverReaderOpenRequestV1
    ) -> LogDriverReaderOpenReconciliationV1 {
        if let entry = readers[request.readerSessionID] {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .prepared(entry.started)
            case .conflict, .distinctScope:
                return .conflict
            }
        }
        for entry in readers.values {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .prepared(entry.started)
            case .conflict:
                return .conflict
            case .distinctScope:
                continue
            }
        }
        return .absent
    }

    private func validateProviderIdentity(
        _ request: LogDriverStartRequestV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
    }

    private func validateProviderIdentity(
        _ request: LogDriverReaderOpenRequestV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: JournaldConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration,
            binding.configuration.containerID == request.containerID
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ call: LogDriverSessionCallV1,
        against entry: SessionEntry
    ) throws {
        let request = entry.request
        guard
            call.containerID == request.containerID,
            call.leaseGeneration == request.leaseGeneration,
            call.providerID == request.providerID,
            call.providerGeneration == request.providerGeneration
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw JournaldProviderError.invalidEffectToken
        }
        switch call.fence {
        case .candidate(
            let operationGeneration,
            let processGeneration,
            let sandboxGeneration
        ):
            guard
                operationGeneration == request.operationGeneration,
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw JournaldProviderError.invalidSessionFence
            }
        case .active(let processGeneration, let sandboxGeneration):
            guard
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw JournaldProviderError.invalidSessionFence
            }
        }
    }

    private func validate(
        _ call: LogDriverReaderCallV1,
        against entry: ReaderEntry
    ) throws {
        let request = entry.request
        guard
            call.containerID == request.containerID,
            call.leaseGeneration == request.leaseGeneration,
            call.providerID == request.providerID,
            call.providerGeneration == request.providerGeneration,
            call.source == request.source
        else {
            throw JournaldProviderError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw JournaldProviderError.invalidEffectToken
        }
    }

    private func acknowledgement(
        _ request: LogDriverSessionCallV1,
        observation: LogDriverSessionObservationV1,
        fenceReceiptDigest: String? = nil
    ) throws -> LogDriverSessionAcknowledgementV1 {
        try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: observation,
            writerFenceReceiptDigest: fenceReceiptDigest
        )
    }

    private func readerAcknowledgement(
        _ request: LogDriverReaderCallV1,
        observation: LogDriverReaderObservationV1,
        terminalOutcomeDigest: String? = nil
    ) throws -> LogDriverReaderAcknowledgementV1 {
        try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: observation,
            terminalOutcomeDigest: terminalOutcomeDigest
        )
    }

    private static func writerIdentity(
        _ request: LogDriverStartRequestV1
    ) -> [String] {
        [
            request.sessionID,
            request.containerID,
            String(request.leaseGeneration),
            request.providerID,
            String(request.providerGeneration),
            String(request.candidateProcessGeneration),
            request.candidateSandboxGeneration.map(String.init) ?? "",
        ]
    }

    private static func exportIdentity(
        _ request: LogDriverHistoryHandoffExportRequestV1
    ) -> [String] {
        [
            request.tokenID,
            request.manifestID,
            request.containerID,
            request.sourceStateRootUUID,
            request.destinationStateRootUUID,
            String(request.sourceLeaseGeneration),
            request.sourceProviderID,
            String(request.sourceProviderGeneration),
            request.sourceContractDigest,
            request.terminalHistoryDigestSHA256,
        ]
    }

    private static func digest(_ domain: String, values: [String]) -> String {
        let material = ([domain] + values).joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "sha256:"
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func acquireOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty {
            operationActive = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}
