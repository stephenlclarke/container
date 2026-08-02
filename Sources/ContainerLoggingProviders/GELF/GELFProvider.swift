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
import OSLog

public enum GELFLogDriverContract {
    public static let providerIdentity = LogDriverProviderIdentity(
        id: "com.apple.container.logging.providers.gelf",
        version: "1",
        kind: .native
    )

    public static func descriptor(providerGeneration: UInt64 = 1) -> LogDriverDescriptor {
        do {
            return try LogDriverDescriptor(
                driver: "gelf",
                providerIdentity: providerIdentity,
                providerGeneration: providerGeneration,
                placement: .macOSHost,
                trust: .signed,
                options: [
                    LogDriverOptionDescriptor(name: "cache-compress", valueKind: .string),
                    LogDriverOptionDescriptor(name: "cache-disabled", valueKind: .boolean),
                    LogDriverOptionDescriptor(name: "cache-max-file", valueKind: .string),
                    LogDriverOptionDescriptor(name: "cache-max-size", valueKind: .string),
                    LogDriverOptionDescriptor(name: "env", valueKind: .commaSeparatedNames),
                    LogDriverOptionDescriptor(
                        name: "env-regex",
                        valueKind: .providerRegularExpression,
                        validationPhase: .start
                    ),
                    LogDriverOptionDescriptor(name: "gelf-address", valueKind: .string),
                    LogDriverOptionDescriptor(
                        name: "gelf-compression-level",
                        valueKind: .string
                    ),
                    LogDriverOptionDescriptor(
                        name: "gelf-compression-type",
                        valueKind: .string,
                        allowedValues: GELFCompressionType.allCases.map(\.rawValue)
                    ),
                    // Moby accepts zero, so positiveInteger is intentionally not used.
                    LogDriverOptionDescriptor(name: "gelf-tcp-max-reconnect", valueKind: .string),
                    LogDriverOptionDescriptor(name: "gelf-tcp-reconnect-delay", valueKind: .string),
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
                createValidationProfile: .dockerGELF29_2_1,
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
            preconditionFailure("invalid GELF logging-driver contract: \(error)")
        }
    }
}

public struct GELFConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let configuration: GELFDriverConfiguration

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        configuration: GELFDriverConfiguration
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.configuration = configuration
    }
}

public protocol GELFConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> GELFConfigurationBinding
}

public protocol GELFEffectTokenGenerating: Sendable {
    func makeEffectToken() throws -> Data
}

public struct RandomGELFEffectTokenGenerator: GELFEffectTokenGenerating {
    public static let tokenByteCount = 32

    public init() {}

    public func makeEffectToken() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data()
        data.reserveCapacity(Self.tokenByteCount)
        while data.count < Self.tokenByteCount {
            var value = generator.next()
            withUnsafeBytes(of: &value) { bytes in
                data.append(contentsOf: bytes.prefix(Self.tokenByteCount - data.count))
            }
        }
        return data
    }
}

public enum GELFSecurityWarning: Equatable, Sendable {
    case plaintextTCP
}

public protocol GELFSecurityWarningEmitting: Sendable {
    func emit(_ warning: GELFSecurityWarning) async
}

public struct SystemGELFSecurityWarningEmitter: GELFSecurityWarningEmitting {
    private static let logger = Logger(
        subsystem: "com.apple.container",
        category: "gelf-logging"
    )

    public init() {}

    public func emit(_ warning: GELFSecurityWarning) async {
        switch warning {
        case .plaintextTCP:
            Self.logger.warning(
                "GELF TCP logging sends records without transport encryption"
            )
        }
    }
}

private actor GELFReplaySession: ContainerLogDriverSession {
    private var state: GELFSessionState

    init(state: GELFSessionState) {
        precondition(state == .writerFenced || state == .closed)
        self.state = state
    }

    func write(_ record: ContainerLogRecordV2) async throws {
        throw GELFProviderError.transportClosed
    }

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {
        state = .closed
    }
}

public actor GELFLogDriverProvider: ContainerLogDriverProvider {
    private struct SessionEntry: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: GELFDriverSession
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
    private let configurationResolver: any GELFConfigurationResolving
    private let transportFactory: any GELFTransportFactory
    private let chunkIDGenerator: any GELFChunkIDGenerating
    private let clock: any GELFClock
    private let tokenGenerator: any GELFEffectTokenGenerating
    private let securityWarningEmitter: any GELFSecurityWarningEmitting
    private let providerState: any GELFProviderStateStoring
    private var effectDerivationKey: SymmetricKey?
    private var sessions = [String: SessionEntry]()
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        providerGeneration: UInt64 = 1,
        configurationResolver: any GELFConfigurationResolving,
        transportFactory: any GELFTransportFactory,
        chunkIDGenerator: any GELFChunkIDGenerating = RandomGELFChunkIDGenerator(),
        clock: any GELFClock = SystemGELFClock(),
        tokenGenerator: any GELFEffectTokenGenerating = RandomGELFEffectTokenGenerator(),
        securityWarningEmitter: any GELFSecurityWarningEmitting =
            SystemGELFSecurityWarningEmitter(),
        providerState: any GELFProviderStateStoring = InMemoryGELFProviderStateStore()
    ) {
        self.descriptorValue = GELFLogDriverContract.descriptor(
            providerGeneration: providerGeneration
        )
        self.configurationResolver = configurationResolver
        self.transportFactory = transportFactory
        self.chunkIDGenerator = chunkIDGenerator
        self.clock = clock
        self.tokenGenerator = tokenGenerator
        self.securityWarningEmitter = securityWarningEmitter
        self.providerState = providerState
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
        case .conflict: throw GELFProviderError.idempotencyConflict
        case .absent, .uncertain: break
        }

        let binding = try await configurationResolver.configuration(for: request)
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: tokenGenerator.makeEffectToken()
        )
        let session = try await GELFDriverSession(
            configuration: binding.configuration,
            transportFactory: transportFactory,
            chunkIDGenerator: chunkIDGenerator,
            clock: clock
        )
        if binding.configuration.endpoint.usesTCP {
            await securityWarningEmitter.emit(.plaintextTCP)
        }
        let entry = SessionEntry(
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
        try await entry.session.fence()
        switch await entry.session.currentState() {
        case .active:
            preconditionFailure("fencing returned with an active GELF session")
        case .closing:
            preconditionFailure("fencing returned with a closing GELF session")
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
        throw GELFProviderError.readUnsupported
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
        for entry in sessions.values {
            switch entry.request.idempotencyComparison(to: request) {
            case .identicalReplay: return .prepared(entry.started)
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
            throw GELFProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: GELFConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration
        else {
            throw GELFProviderError.invalidProviderIdentity
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
            throw GELFProviderError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw GELFProviderError.invalidEffectToken
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
                throw GELFProviderError.invalidSessionFence
            }
        case .active(let processGeneration, let sandboxGeneration):
            guard
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw GELFProviderError.invalidSessionFence
            }
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
