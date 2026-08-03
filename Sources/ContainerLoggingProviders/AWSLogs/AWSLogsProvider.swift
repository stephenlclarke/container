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

public enum AWSLogsLogDriverContract {
    public static let providerIdentity = LogDriverProviderIdentity(
        id: "com.apple.container.logging.providers.awslogs",
        version: "1",
        kind: .native
    )

    public static func descriptor(
        providerGeneration: UInt64 = 1
    ) -> LogDriverDescriptor {
        do {
            return try LogDriverDescriptor(
                driver: "awslogs",
                providerIdentity: providerIdentity,
                providerGeneration: providerGeneration,
                placement: .macOSHost,
                trust: .signed,
                options: [
                    option("awslogs-create-group"),
                    option("awslogs-create-stream"),
                    option("awslogs-credentials-endpoint"),
                    option("awslogs-datetime-format"),
                    option("awslogs-endpoint"),
                    option(
                        "awslogs-force-flush-interval-seconds",
                        kind: .positiveInteger
                    ),
                    LogDriverOptionDescriptor(
                        name: "awslogs-format",
                        valueKind: .string,
                        validationPhase: .start,
                        allowedValues: ["", "json/emf"]
                    ),
                    option("awslogs-group"),
                    option(
                        "awslogs-max-buffered-events",
                        kind: .positiveInteger
                    ),
                    option(
                        "awslogs-multiline-pattern",
                        kind: .providerRegularExpression
                    ),
                    option("awslogs-region"),
                    option("awslogs-stream"),
                    option("cache-compress"),
                    option("cache-disabled"),
                    option("cache-max-file"),
                    option("cache-max-size"),
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
            preconditionFailure("invalid awslogs contract: \(error)")
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

public struct AWSLogsConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let configuration: AWSLogsDriverConfiguration
    public let multilineMatcher: any AWSLogsMultilineMatching

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        configuration: AWSLogsDriverConfiguration,
        multilineMatcher: any AWSLogsMultilineMatching
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.configuration = configuration
        self.multilineMatcher = multilineMatcher
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.semanticRequestDigest == rhs.semanticRequestDigest
            && lhs.containerID == rhs.containerID
            && lhs.leaseGeneration == rhs.leaseGeneration
            && lhs.providerID == rhs.providerID
            && lhs.providerGeneration == rhs.providerGeneration
            && lhs.configuration == rhs.configuration
    }
}

public protocol AWSLogsConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> AWSLogsConfigurationBinding
}

public typealias AWSLogsEffectTokenGenerating = SplunkEffectTokenGenerating
public typealias RandomAWSLogsEffectTokenGenerator =
    RandomSplunkEffectTokenGenerator

public actor AWSLogsLogDriverProvider: ContainerLogDriverProvider {
    private struct SessionEntry: Sendable {
        let request: LogDriverStartRequestV1
        let token: LogDriverOpaqueEffectTokenV1
        let session: AWSLogsDriverSession
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
    private let configurationResolver: any AWSLogsConfigurationResolving
    private let clientFactory: any AWSLogsClientFactory
    private let clock: any AWSLogsClock
    private let tokenGenerator: any AWSLogsEffectTokenGenerating
    private var sessions = [String: SessionEntry]()
    private var operationActive = false
    private var operationWaiters = [CheckedContinuation<Void, Never>]()

    public init(
        providerGeneration: UInt64 = 1,
        configurationResolver: any AWSLogsConfigurationResolving,
        clientFactory: any AWSLogsClientFactory,
        clock: any AWSLogsClock = SystemAWSLogsClock(),
        tokenGenerator: any AWSLogsEffectTokenGenerating =
            RandomAWSLogsEffectTokenGenerator()
    ) {
        self.descriptorValue = AWSLogsLogDriverContract.descriptor(
            providerGeneration: providerGeneration
        )
        self.configurationResolver = configurationResolver
        self.clientFactory = clientFactory
        self.clock = clock
        self.tokenGenerator = tokenGenerator
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
        case .prepared(let started):
            return started
        case .conflict:
            throw AWSLogsProviderError.idempotencyConflict
        case .absent, .uncertain:
            break
        }

        let binding = try await configurationResolver.configuration(
            for: request
        )
        try validate(binding, for: request)
        let token = try LogDriverOpaqueEffectTokenV1(
            validating: tokenGenerator.makeEffectToken()
        )
        let session = try await AWSLogsDriverSession(
            configuration: binding.configuration,
            clientFactory: clientFactory,
            matcher: binding.multilineMatcher,
            clock: clock
        )
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
        throw AWSLogsProviderError.readUnsupported
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

    private func validateProviderIdentity(
        _ request: LogDriverStartRequestV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw AWSLogsProviderError.invalidProviderIdentity
        }
    }

    private func validate(
        _ binding: AWSLogsConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        guard
            binding.semanticRequestDigest == request.semanticRequestDigest,
            binding.containerID == request.containerID,
            binding.leaseGeneration == request.leaseGeneration,
            binding.providerID == request.providerID,
            binding.providerGeneration == request.providerGeneration
        else {
            throw AWSLogsProviderError.invalidProviderIdentity
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
            throw AWSLogsProviderError.invalidProviderIdentity
        }
        guard call.effectTokenMaterial.isByteIdentical(to: entry.token) else {
            throw AWSLogsProviderError.invalidEffectToken
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
                throw AWSLogsProviderError.invalidSessionFence
            }
        case .active(let processGeneration, let sandboxGeneration):
            guard
                processGeneration == request.candidateProcessGeneration,
                sandboxGeneration == request.candidateSandboxGeneration
            else {
                throw AWSLogsProviderError.invalidSessionFence
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
