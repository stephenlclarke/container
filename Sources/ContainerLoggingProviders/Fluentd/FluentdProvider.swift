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

public enum FluentdLogDriverContract {
    public static let providerIdentity = LogDriverProviderIdentity(
        id: "com.apple.container.logging.providers.fluentd",
        version: "1",
        kind: .native
    )

    public static func descriptor(providerGeneration: UInt64 = 1) -> LogDriverDescriptor {
        do {
            return try LogDriverDescriptor(
                driver: "fluentd",
                providerIdentity: providerIdentity,
                providerGeneration: providerGeneration,
                placement: .macOSHost,
                trust: .signed,
                options: [
                    LogDriverOptionDescriptor(
                        name: "cache-compress",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(name: "cache-disabled", valueKind: .boolean),
                    LogDriverOptionDescriptor(
                        name: "cache-max-file",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(name: "cache-max-size", valueKind: .string),
                    LogDriverOptionDescriptor(name: "env", valueKind: .commaSeparatedNames),
                    LogDriverOptionDescriptor(
                        name: "env-regex",
                        valueKind: .providerRegularExpression,
                        validationPhase: .start
                    ),
                    LogDriverOptionDescriptor(name: "fluentd-address", valueKind: .string),
                    LogDriverOptionDescriptor(name: "fluentd-async", valueKind: .string),
                    LogDriverOptionDescriptor(
                        name: "fluentd-async-reconnect-interval",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(name: "fluentd-buffer-limit", valueKind: .string),
                    // Zero is accepted and normalized by fluent-logger, so the
                    // generic positive-integer grammar would be too narrow.
                    LogDriverOptionDescriptor(name: "fluentd-max-retries", valueKind: .string),
                    LogDriverOptionDescriptor(name: "fluentd-read-timeout", valueKind: .string),
                    LogDriverOptionDescriptor(
                        name: "fluentd-request-ack",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(name: "fluentd-retry-wait", valueKind: .string),
                    LogDriverOptionDescriptor(
                        name: "fluentd-sub-second-precision",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(name: "fluentd-write-timeout", valueKind: .string),
                    LogDriverOptionDescriptor(name: "labels", valueKind: .commaSeparatedNames),
                    LogDriverOptionDescriptor(
                        name: "labels-regex",
                        valueKind: .providerRegularExpression,
                        validationPhase: .start
                    ),
                    LogDriverOptionDescriptor(name: "max-buffer-size", valueKind: .size),
                    LogDriverOptionDescriptor(
                        name: "mode",
                        valueKind: .string,
                        allowedValues: ["", "blocking", "non-blocking"]
                    ),
                    LogDriverOptionDescriptor(
                        name: "tag",
                        valueKind: .tagTemplate,
                        validationPhase: .start
                    ),
                ],
                crossOptionConstraints: [
                    LogDriverCrossOptionConstraint(
                        whenOptionPresent: "max-buffer-size",
                        requiredOption: "mode",
                        requiredAllowedValues: ["non-blocking"]
                    )
                ],
                createValidationProfile: .dockerFluentd29_2_1,
                capabilities: LogDriverCapabilities(
                    deliveryModes: [.blocking, .nonBlocking],
                    nativeRead: false,
                    readFilters: [],
                    supportsDualCache: true,
                    supportsDockerPluginProtocol: false,
                    requiresDeliverySession: true,
                    logPathVisibility: .none,
                    fileDefaults: nil
                )
            )
        } catch {
            preconditionFailure("invalid fluentd logging-driver contract: \(error)")
        }
    }
}

public struct FluentdConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let configuration: FluentdDriverConfiguration

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        configuration: FluentdDriverConfiguration
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.configuration = configuration
    }
}

public protocol FluentdConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> FluentdConfigurationBinding
}

public protocol FluentdEffectTokenGenerating: Sendable {
    func makeEffectToken() throws -> Data
}

public struct RandomFluentdEffectTokenGenerator: FluentdEffectTokenGenerating {
    public static let tokenByteCount = 32

    public init() {}

    public func makeEffectToken() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data()
        data.reserveCapacity(Self.tokenByteCount)
        while data.count < Self.tokenByteCount {
            var value = generator.next()
            withUnsafeBytes(of: &value) { bytes in
                data.append(
                    contentsOf: bytes.prefix(Self.tokenByteCount - data.count)
                )
            }
        }
        return data
    }
}

private actor FluentdReplaySession: ContainerLogDriverSession {
    private var state: FluentdSessionState

    init(state: FluentdSessionState) {
        precondition(state == .writerFenced || state == .closed)
        self.state = state
    }

    func write(_ record: ContainerLogRecordV2) async throws {
        throw FluentdProviderError.transportClosed
    }

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {
        state = .closed
    }

    func observation() -> LogDriverSessionObservationV1 {
        switch state {
        case .writerFenced: return .writerFenced
        case .closed: return .closed
        case .active, .closing:
            preconditionFailure("a fluentd replay session must be terminal")
        }
    }
}

public actor FluentdLogDriverProvider: ContainerLogDriverProvider {
    private struct ActiveSessionEntry: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: FluentdDriverSession
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

    private struct ReplayTombstone: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: FluentdReplaySession
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

    private let descriptorValue: LogDriverDescriptor
    private let configurationResolver: any FluentdConfigurationResolving
    private let transportFactory: any FluentdTransportFactory
    private let chunkIDGenerator: any FluentdChunkIDGenerating
    private let clock: any FluentdClock
    private let tokenGenerator: any FluentdEffectTokenGenerating
    private let maximumReplayTombstones: Int
    private var sessions = [String: ActiveSessionEntry]()
    private var replayTombstones = [String: ReplayTombstone]()
    private var replayTombstoneOrder = [String]()
    private var replayTombstoneHead = 0
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        providerGeneration: UInt64 = 1,
        configurationResolver: any FluentdConfigurationResolving,
        transportFactory: any FluentdTransportFactory,
        chunkIDGenerator: any FluentdChunkIDGenerating = RandomFluentdChunkIDGenerator(),
        clock: any FluentdClock = SystemFluentdClock(),
        tokenGenerator: any FluentdEffectTokenGenerating = RandomFluentdEffectTokenGenerator(),
        maximumReplayTombstones: Int = 4_096
    ) {
        precondition(maximumReplayTombstones > 0)
        self.descriptorValue = FluentdLogDriverContract.descriptor(
            providerGeneration: providerGeneration
        )
        self.configurationResolver = configurationResolver
        self.transportFactory = transportFactory
        self.chunkIDGenerator = chunkIDGenerator
        self.clock = clock
        self.tokenGenerator = tokenGenerator
        self.maximumReplayTombstones = maximumReplayTombstones
    }

    public var descriptor: LogDriverDescriptor {
        get async throws { descriptorValue }
    }

    public func start(
        _ request: LogDriverStartRequestV1
    ) async throws -> StartedLogDriverSessionV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)

        switch existingStart(for: request) {
        case .prepared(let started): return started
        case .conflict: throw FluentdProviderError.idempotencyConflict
        case .absent, .uncertain: break
        }

        let binding = try await configurationResolver.configuration(for: request)
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: tokenGenerator.makeEffectToken()
        )
        let session = try await FluentdDriverSession(
            configuration: binding.configuration,
            transportFactory: transportFactory,
            chunkIDGenerator: chunkIDGenerator,
            clock: clock
        )
        let entry = ActiveSessionEntry(
            request: request,
            token: token,
            session: session,
            fenceReceiptDigest: Self.fenceReceiptDigest(for: request)
        )
        sessions[request.sessionID] = entry
        return entry.started
    }

    public func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        await acquireOperation()
        defer { releaseOperation() }
        try validateProviderIdentity(request)
        return existingStart(for: request)
    }

    public func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            guard let tombstone = replayTombstones[request.sessionID] else {
                return try acknowledgement(request, observation: .absent)
            }
            try validate(request, against: tombstone)
            let observation = await tombstone.session.observation()
            return try acknowledgement(
                request,
                observation: observation,
                fenceReceiptDigest: observation == .writerFenced
                    ? tombstone.fenceReceiptDigest : nil
            )
        }
        try validate(request, against: entry)
        switch await entry.session.currentState() {
        case .active:
            return try acknowledgement(request, observation: .active)
        case .closing:
            return try acknowledgement(request, observation: .draining)
        case .writerFenced:
            compact(entry, state: .writerFenced)
            return try acknowledgement(
                request,
                observation: .writerFenced,
                fenceReceiptDigest: entry.fenceReceiptDigest
            )
        case .closed:
            compact(entry, state: .closed)
            return try acknowledgement(request, observation: .closed)
        }
    }

    public func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            guard let tombstone = replayTombstones[request.sessionID] else {
                return try acknowledgement(request, observation: .absent)
            }
            try validate(request, against: tombstone)
            let observation = await tombstone.session.observation()
            return try acknowledgement(
                request,
                observation: observation,
                fenceReceiptDigest: observation == .writerFenced
                    ? tombstone.fenceReceiptDigest : nil
            )
        }
        try validate(request, against: entry)
        try await entry.session.fence()
        switch await entry.session.currentState() {
        case .active:
            preconditionFailure("fencing returned with an active fluentd session")
        case .closing:
            preconditionFailure("fencing returned with a closing fluentd session")
        case .writerFenced:
            compact(entry, state: .writerFenced)
            return try acknowledgement(
                request,
                observation: .writerFenced,
                fenceReceiptDigest: entry.fenceReceiptDigest
            )
        case .closed:
            compact(entry, state: .closed)
            return try acknowledgement(request, observation: .closed)
        }
    }

    public func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        await acquireOperation()
        defer { releaseOperation() }
        guard let entry = sessions[request.sessionID] else {
            guard let tombstone = replayTombstones[request.sessionID] else {
                return try acknowledgement(request, observation: .absent)
            }
            try validate(request, against: tombstone)
            try await tombstone.session.close(deadline: ContinuousClock().now)
            return try acknowledgement(request, observation: .closed)
        }
        try validate(request, against: entry)
        try await entry.session.closeUsingPolicy()
        compact(entry, state: .closed)
        return try acknowledgement(request, observation: .closed)
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        throw FluentdProviderError.readUnsupported
    }

    public func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        .absent
    }

    public func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: .absent,
            terminalOutcomeDigest: nil
        )
    }

    public func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: .absent,
            terminalOutcomeDigest: nil
        )
    }

    private func existingStart(
        for request: LogDriverStartRequestV1
    ) -> LogDriverStartReconciliationV1 {
        if let entry = sessions[request.sessionID] {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay: return .prepared(entry.started)
            case .conflict, .distinctScope: return .conflict
            }
        }
        if let tombstone = replayTombstones[request.sessionID] {
            switch tombstone.request.idempotencyComparison(to: request) {
            case .identicalReplay: return .prepared(tombstone.started)
            case .conflict, .distinctScope: return .conflict
            }
        }
        for entry in sessions.values {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay: return .prepared(entry.started)
            case .conflict: return .conflict
            case .distinctScope: continue
            }
        }
        for tombstone in replayTombstones.values {
            switch tombstone.request.idempotencyComparison(to: request) {
            case .identicalReplay: return .prepared(tombstone.started)
            case .conflict: return .conflict
            case .distinctScope: continue
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
            throw FluentdProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: FluentdConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration
        else {
            throw FluentdProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ call: LogDriverSessionCallV1,
        against entry: ActiveSessionEntry
    ) throws {
        try validate(call, request: entry.request, token: entry.token)
    }

    private func validate(
        _ call: LogDriverSessionCallV1,
        against tombstone: ReplayTombstone
    ) throws {
        try validate(call, request: tombstone.request, token: tombstone.token)
    }

    private func validate(
        _ call: LogDriverSessionCallV1,
        request: LogDriverStartRequestV1,
        token: LogDriverOpaqueEffectTokenV1
    ) throws {
        guard
            call.containerID == request.containerID,
            call.leaseGeneration == request.leaseGeneration,
            call.providerID == request.providerID,
            call.providerGeneration == request.providerGeneration
        else {
            throw FluentdProviderError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: token) else {
            throw FluentdProviderError.invalidEffectToken
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
                throw FluentdProviderError.invalidSessionFence
            }
        case .active(let processGeneration, let sandboxGeneration):
            guard
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw FluentdProviderError.invalidSessionFence
            }
        }
    }

    private func compact(
        _ entry: ActiveSessionEntry,
        state: FluentdSessionState
    ) {
        guard state == .writerFenced || state == .closed else {
            preconditionFailure("only terminal fluentd sessions can be compacted")
        }
        let sessionID = entry.request.sessionID
        guard sessions.removeValue(forKey: sessionID) != nil else {
            return
        }
        replayTombstones[sessionID] = ReplayTombstone(
            request: entry.request,
            token: entry.token,
            session: FluentdReplaySession(state: state),
            fenceReceiptDigest: entry.fenceReceiptDigest
        )
        replayTombstoneOrder.append(sessionID)
        evictReplayTombstonesIfNeeded()
    }

    private func evictReplayTombstonesIfNeeded() {
        while replayTombstones.count > maximumReplayTombstones {
            let sessionID = replayTombstoneOrder[replayTombstoneHead]
            replayTombstoneHead += 1
            replayTombstones.removeValue(forKey: sessionID)
        }
        if replayTombstoneHead >= 4_096,
            replayTombstoneHead >= replayTombstoneOrder.count / 2
        {
            replayTombstoneOrder.removeFirst(replayTombstoneHead)
            replayTombstoneHead = 0
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

    private static func fenceReceiptDigest(
        for request: LogDriverStartRequestV1
    ) -> String {
        let material = [
            request.sessionID,
            request.containerID,
            String(request.leaseGeneration),
            request.providerID,
            String(request.providerGeneration),
            String(request.candidateProcessGeneration),
            request.candidateSandboxGeneration.map(String.init) ?? "",
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
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
