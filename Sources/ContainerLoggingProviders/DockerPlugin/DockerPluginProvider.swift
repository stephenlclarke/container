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

/// Immutable contract published by one installed Docker logging-plugin
/// generation. The optional ReadLogs capability is frozen into the descriptor
/// and revalidated on every writer/reader acquisition.
public enum DockerPluginLogDriverContract {
    public static func descriptor(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        readLogs: Bool,
        trust: LogDriverTrust = .signed
    ) throws -> LogDriverDescriptor {
        guard providerIdentity.kind == .dockerPlugin else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        let readFilters: [LogDriverReadFilter] =
            readLogs
            ? [
                .stdout, .stderr, .follow, .tail, .since, .until,
                .timestamps, .details,
            ] : []
        return try LogDriverDescriptor(
            driver: driver,
            aliases: aliases,
            providerIdentity: providerIdentity,
            providerGeneration: providerGeneration,
            placement: .engineLinuxSandbox,
            trust: trust,
            options: [
                LogDriverOptionDescriptor(
                    name: "max-buffer-size",
                    valueKind: .size,
                    validationPhase: .start
                ),
                LogDriverOptionDescriptor(
                    name: "mode",
                    valueKind: .string,
                    allowedValues: ["", "blocking", "non-blocking"]
                ),
            ],
            crossOptionConstraints: [
                LogDriverCrossOptionConstraint(
                    whenOptionPresent: "max-buffer-size",
                    requiredOption: "mode",
                    requiredAllowedValues: ["non-blocking"]
                )
            ],
            acceptsUnknownOptions: true,
            capabilities: LogDriverCapabilities(
                deliveryModes: [.blocking, .nonBlocking],
                nativeRead: readLogs,
                readFilters: readFilters,
                supportsDualCache: true,
                supportsDockerPluginProtocol: true,
                requiresDeliverySession: true,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }
}

/// Exact authority-owned Docker metadata for one lifecycle request.
public struct DockerPluginConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let info: DockerPluginInfo

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        info: DockerPluginInfo
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.info = info
    }
}

/// Supplies protected Docker Info material only for an exact authority request.
public protocol DockerPluginConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> DockerPluginConfigurationBinding

    func configuration(
        for request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginConfigurationBinding
}

/// Acquires an authenticated service generation inside the Engine Linux
/// sandbox. Names, endpoints, executables, and launch arguments are resolved by
/// the installed provider plane and cannot originate in Compose configuration.
public protocol DockerPluginProviderAcquiring: Sendable {
    func activeSandboxGeneration(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> UInt64

    func acquire(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginProviderLease
}

public protocol DockerPluginRandomBytesGenerating: Sendable {
    func makeBytes(count: Int) throws -> Data
}

public struct RandomDockerPluginBytesGenerator:
    DockerPluginRandomBytesGenerating
{
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

private actor DockerPluginLeasedReader: ContainerLogReader {
    private let reader: DockerPluginLogReader
    private let lease: any DockerPluginProviderLease
    private var closed = false

    init(
        reader: DockerPluginLogReader,
        lease: any DockerPluginProviderLease
    ) {
        self.reader = reader
        self.lease = lease
    }

    func next() async throws -> ContainerLogReaderEventV1 {
        guard !closed else {
            throw ContainerLogReaderError.alreadyEnded
        }
        do {
            let event = try await reader.next()
            if event == .endOfStream {
                await finish(cancelReader: false)
            }
            return event
        } catch {
            await finish(cancelReader: true)
            throw error
        }
    }

    func cancel() async {
        await finish(cancelReader: true)
    }

    func isClosed() -> Bool {
        closed
    }

    private func finish(cancelReader: Bool) async {
        guard !closed else {
            return
        }
        closed = true
        if cancelReader {
            await reader.cancel()
        } else {
            await reader.close()
        }
        await lease.release()
    }
}

/// Lifecycle provider for one installed Docker logging-plugin generation.
///
/// The authority's durable lifecycle ledger remains the source of controller
/// intent. This actor owns exact in-process adapters and stable private tokens;
/// the injected acquisition/FIFO plane owns the protected Linux service
/// namespace. An uncertain writer start retains the exact prepared FIFO and
/// lease so tokenless reconciliation replays the same request without creating
/// a duplicate session.
public actor DockerPluginLogDriverProvider: ContainerLogDriverProvider {
    private struct WriterClaim: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let info: DockerPluginInfo
        let prepared: DockerPluginPreparedWriter
    }

    private struct SessionEntry: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: DockerPluginDriverSession
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

    private struct ReaderClaim: Sendable {
        let request: LogDriverReaderOpenRequestV1
        let token: LogDriverOpaqueEffectTokenV1
    }

    private struct ReaderEntry: Sendable {
        let request: LogDriverReaderOpenRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let reader: DockerPluginLeasedReader
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
    private let configurationResolver: any DockerPluginConfigurationResolving
    private let providerAcquirer: any DockerPluginProviderAcquiring
    private let fifoFactory: any DockerPluginFIFOFactory
    private let random: any DockerPluginRandomBytesGenerating
    private var writerClaims = [String: WriterClaim]()
    private var sessions = [String: SessionEntry]()
    private var readerClaims = [String: ReaderClaim]()
    private var readers = [String: ReaderEntry]()
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        readLogs: Bool,
        trust: LogDriverTrust = .signed,
        configurationResolver: any DockerPluginConfigurationResolving,
        providerAcquirer: any DockerPluginProviderAcquiring,
        fifoFactory: any DockerPluginFIFOFactory,
        random: any DockerPluginRandomBytesGenerating =
            RandomDockerPluginBytesGenerator()
    ) throws {
        self.descriptorValue = try DockerPluginLogDriverContract.descriptor(
            driver: driver,
            aliases: aliases,
            providerIdentity: providerIdentity,
            providerGeneration: providerGeneration,
            readLogs: readLogs,
            trust: trust
        )
        self.configurationResolver = configurationResolver
        self.providerAcquirer = providerAcquirer
        self.fifoFactory = fifoFactory
        self.random = random
    }

    public var descriptor: LogDriverDescriptor {
        get async throws { descriptorValue }
    }

    public func activeSandboxGeneration() async throws -> UInt64 {
        let generation = try await providerAcquirer.activeSandboxGeneration(
            providerID: descriptorValue.providerIdentity.id,
            providerGeneration: descriptorValue.providerGeneration
        )
        guard generation > 0 else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        return generation
    }

    public func start(
        _ request: LogDriverStartRequestV1
    ) async throws -> StartedLogDriverSessionV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        guard
            let requestedSandboxGeneration =
                request.candidateSandboxGeneration,
            requestedSandboxGeneration == (try await activeSandboxGeneration())
        else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        switch existingStart(for: request) {
        case .prepared(let started):
            return started
        case .conflict:
            throw DockerPluginProtocolError.idempotencyConflict
        case .uncertain:
            throw DockerPluginProtocolError.stopOutcomeUncertain
        case .absent:
            break
        }

        let binding = try await configurationResolver.configuration(
            for: request
        )
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: random.makeBytes(count: 32)
        )
        let lease = try await providerAcquirer.acquire(
            providerID: request.providerID,
            providerGeneration: request.providerGeneration
        )
        let prepared = try await DockerPluginDriverSession.prepare(
            sessionID: request.sessionID,
            providerGeneration: request.providerGeneration,
            lease: lease,
            fifoFactory: fifoFactory,
            deadline: ContinuousClock().now + .seconds(30)
        )
        guard
            prepared.capabilities.readLogs
                == descriptorValue.capabilities.nativeRead
        else {
            await prepared.abandon()
            throw DockerPluginProtocolError.capabilityMismatch
        }
        let claim = WriterClaim(
            request: request,
            token: token,
            info: binding.info,
            prepared: prepared
        )
        writerClaims[request.sessionID] = claim
        do {
            return try await start(claim)
        } catch {
            if Self.isDefinitiveStartRejection(error) {
                writerClaims.removeValue(forKey: request.sessionID)
                await prepared.abandon()
            }
            throw error
        }
    }

    public func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        if let entry = sessions[request.sessionID] {
            return Self.reconcile(entry.request, request, prepared: entry.started)
        }
        if let claim = writerClaims[request.sessionID] {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                do {
                    return .prepared(try await start(claim))
                } catch {
                    return .uncertain
                }
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
        for claim in writerClaims.values {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .uncertain
            case .conflict:
                return .conflict
            case .distinctScope:
                continue
            }
        }
        return .absent
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
        case .stopOutcomeUncertain:
            return try acknowledgement(request, observation: .uncertain)
        case .writerFencing, .closing:
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
        await entry.session.fence()
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
        try await entry.session.close(
            deadline: ContinuousClock().now + .seconds(10)
        )
        return try acknowledgement(request, observation: .closed)
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        guard descriptorValue.capabilities.nativeRead else {
            throw ContainerLogReaderError
                .configuredDriverDoesNotSupportReading
        }
        switch existingReader(for: request) {
        case .prepared(let started):
            return started
        case .conflict:
            throw DockerPluginProtocolError.idempotencyConflict
        case .uncertain:
            throw DockerPluginProtocolError.stopOutcomeUncertain
        case .absent:
            break
        }

        let binding = try await configurationResolver.configuration(
            for: request
        )
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: random.makeBytes(count: 32)
        )
        readerClaims[request.readerSessionID] = ReaderClaim(
            request: request,
            token: token
        )
        let lease: any DockerPluginProviderLease
        do {
            lease = try await providerAcquirer.acquire(
                providerID: request.providerID,
                providerGeneration: request.providerGeneration
            )
        } catch {
            readerClaims.removeValue(forKey: request.readerSessionID)
            throw error
        }
        do {
            let client = DockerPluginProtocolClient(
                transport: lease.transport
            )
            let capabilities = try await client.capabilities(
                deadline: ContinuousClock().now + .seconds(30)
            )
            guard capabilities.readLogs else {
                throw DockerPluginProtocolError.capabilityMismatch
            }
            let reader = try await DockerPluginLogReader.open(
                client: client,
                capabilities: capabilities,
                info: binding.info,
                request: request.read
            )
            let tracked = DockerPluginLeasedReader(
                reader: reader,
                lease: lease
            )
            let entry = ReaderEntry(
                request: request,
                token: token,
                reader: tracked,
                terminalOutcomeDigest: Self.digest(
                    "reader-terminal",
                    values: Self.readerIdentity(request)
                )
            )
            readers[request.readerSessionID] = entry
            readerClaims.removeValue(forKey: request.readerSessionID)
            return entry.started
        } catch {
            readerClaims.removeValue(forKey: request.readerSessionID)
            await lease.release()
            throw error
        }
    }

    public func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        return existingReader(for: request)
    }

    public func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = readers[request.readerSessionID] else {
            return try readerAcknowledgement(
                request,
                observation: .absent
            )
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
            return try readerAcknowledgement(
                request,
                observation: .absent
            )
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
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        switch request.kind {
        case .writerCandidate, .writerSession, .detachedCleanup:
            if let entry = sessions[request.effectID] {
                switch await entry.session.currentState() {
                case .writerFenced, .closed:
                    break
                case .active, .stopOutcomeUncertain, .writerFencing,
                    .closing:
                    throw DockerPluginProtocolError.invalidSessionFence
                }
            }
            if let claim = writerClaims.removeValue(
                forKey: request.effectID
            ) {
                await claim.prepared.abandon()
            }
            sessions.removeValue(forKey: request.effectID)
        case .readerCandidate, .readerSession:
            if let entry = readers[request.effectID],
                !(await entry.reader.isClosed())
            {
                throw DockerPluginProtocolError.invalidSessionFence
            }
            readerClaims.removeValue(forKey: request.effectID)
            readers.removeValue(forKey: request.effectID)
        }
    }

    private func start(
        _ claim: WriterClaim
    ) async throws -> StartedLogDriverSessionV1 {
        let started = try await claim.prepared.start(
            info: claim.info,
            deadline: ContinuousClock().now + .seconds(30)
        )
        guard
            started.capabilities.readLogs
                == descriptorValue.capabilities.nativeRead
        else {
            throw DockerPluginProtocolError.capabilityMismatch
        }
        let entry = SessionEntry(
            request: claim.request,
            token: claim.token,
            session: started.session,
            fenceReceiptDigest: Self.digest(
                "writer-fence",
                values: Self.writerIdentity(claim.request)
            )
        )
        sessions[claim.request.sessionID] = entry
        writerClaims.removeValue(forKey: claim.request.sessionID)
        return entry.started
    }

    private func existingStart(
        for request: LogDriverStartRequestV1
    ) -> LogDriverStartReconciliationV1 {
        if let entry = sessions[request.sessionID] {
            return Self.reconcile(
                entry.request,
                request,
                prepared: entry.started
            )
        }
        if let claim = writerClaims[request.sessionID] {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .uncertain
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
        for claim in writerClaims.values {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .uncertain
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
        if let claim = readerClaims[request.readerSessionID] {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .uncertain
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
        for claim in readerClaims.values {
            switch claim.request.idempotencyComparison(to: request) {
            case .identicalReplay:
                return .uncertain
            case .conflict:
                return .conflict
            case .distinctScope:
                continue
            }
        }
        return .absent
    }

    private static func reconcile(
        _ existing: LogDriverStartRequestV1,
        _ request: LogDriverStartRequestV1,
        prepared: StartedLogDriverSessionV1
    ) -> LogDriverStartReconciliationV1 {
        switch existing.idempotencyComparison(to: request) {
        case .identicalReplay:
            return .prepared(prepared)
        case .conflict, .distinctScope:
            return .conflict
        }
    }

    private func validateProviderIdentity(
        _ request: LogDriverStartRequestV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }

    private func validateProviderIdentity(
        _ request: LogDriverReaderOpenRequestV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: DockerPluginConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration,
            binding.info.containerID == request.containerID
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: DockerPluginConfigurationBinding,
        for request: LogDriverReaderOpenRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration,
            binding.info.containerID == request.containerID
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
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
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw DockerPluginProtocolError.invalidEffectToken
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
                throw DockerPluginProtocolError.invalidSessionFence
            }
        case .active(let processGeneration, let sandboxGeneration):
            guard
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw DockerPluginProtocolError.invalidSessionFence
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
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw DockerPluginProtocolError.invalidEffectToken
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

    private static func readerIdentity(
        _ request: LogDriverReaderOpenRequestV1
    ) -> [String] {
        [
            request.readerSessionID,
            request.containerID,
            String(request.leaseGeneration),
            request.providerID,
            String(request.providerGeneration),
            readerSourceIdentity(request.source),
        ]
    }

    private static func readerSourceIdentity(
        _ source: LoggingReaderSourceV1
    ) -> String {
        switch source {
        case .stoppedContainer:
            return "stopped-container"
        case .activeWriter(
            let sessionID,
            let providerID,
            let providerGeneration,
            let processGeneration,
            let sandboxGeneration
        ):
            return [
                "active-writer",
                sessionID,
                providerID,
                String(providerGeneration),
                String(processGeneration),
                sandboxGeneration.map(String.init) ?? "",
            ].joined(separator: "\u{0}")
        }
    }

    private static func digest(_ domain: String, values: [String]) -> String {
        let material = ([domain] + values).joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "sha256:"
            + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isDefinitiveStartRejection(
        _ error: any Error
    ) -> Bool {
        guard let error = error as? DockerPluginProtocolError else {
            return false
        }
        if case .endpointRejected(endpoint: .startLogging) = error {
            return true
        }
        return false
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
