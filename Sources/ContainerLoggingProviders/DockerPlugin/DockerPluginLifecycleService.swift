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
import Foundation

/// Complete immutable input claimed by the isolated plugin service before it
/// creates a FIFO, contacts the plugin, or starts any other protected effect.
public struct DockerPluginWriterOpenRequest: Equatable, Sendable {
    public let request: LogDriverStartRequestV1
    public let info: DockerPluginInfo

    public init(
        request: LogDriverStartRequestV1,
        info: DockerPluginInfo
    ) throws {
        guard
            request.candidateSandboxGeneration != nil,
            request.containerID == info.containerID
        else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        self.request = request
        self.info = info
    }
}

/// One durable service-owned writer plus its byte-stable private receipt.
public struct DockerPluginServiceStartedWriter: Sendable {
    public let capabilities: DockerPluginCapabilities
    public let started: StartedLogDriverSessionV1

    public init(
        capabilities: DockerPluginCapabilities,
        started: StartedLogDriverSessionV1
    ) {
        self.capabilities = capabilities
        self.started = started
    }
}

/// Tokenless observation of a service-owned writer claim.
public enum DockerPluginServiceWriterReconciliation: Sendable {
    case absent
    case prepared(DockerPluginServiceStartedWriter)
    case conflict
    case uncertain
}

/// Complete immutable reader input claimed before opening plugin `ReadLogs`.
public struct DockerPluginReaderOpenRequest: Equatable, Sendable {
    public let request: LogDriverReaderOpenRequestV1
    public let info: DockerPluginInfo

    public init(
        request: LogDriverReaderOpenRequestV1,
        info: DockerPluginInfo
    ) throws {
        guard request.containerID == info.containerID else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        self.request = request
        self.info = info
    }
}

/// One durable service-owned reader plus its byte-stable private receipt.
public struct DockerPluginServiceStartedReader: Sendable {
    public let capabilities: DockerPluginCapabilities
    public let started: StartedLogDriverReaderV1

    public init(
        capabilities: DockerPluginCapabilities,
        started: StartedLogDriverReaderV1
    ) {
        self.capabilities = capabilities
        self.started = started
    }
}

/// Tokenless observation of a service-owned reader claim.
public enum DockerPluginServiceReaderReconciliation: Sendable {
    case absent
    case prepared(DockerPluginServiceStartedReader)
    case conflict
    case uncertain
}

/// Durable, generation-pinned boundary implemented by the protected Linux
/// plugin service.
///
/// The service, rather than a macOS actor, owns request claims, effect-token
/// bytes, FIFO identity, plugin calls, reader cursors, and terminal state. It
/// persists each claim before the first protected effect. An identical
/// tokenless reconciliation returns a new local adapter and the same receipt;
/// a conflicting request can never create a second effect.
public protocol DockerPluginLifecycleService: Sendable {
    func activeSandboxGeneration() async throws -> UInt64

    func startWriter(
        _ request: DockerPluginWriterOpenRequest
    ) async throws -> DockerPluginServiceStartedWriter

    func reconcileWriterOpen(
        _ request: LogDriverStartRequestV1
    ) async throws -> DockerPluginServiceWriterReconciliation

    func reconcileWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1

    func fenceWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1

    func closeWriter(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1

    func openReader(
        _ request: DockerPluginReaderOpenRequest
    ) async throws -> DockerPluginServiceStartedReader

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> DockerPluginServiceReaderReconciliation

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1

    func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async throws
}

/// Production provider facade for one installed service generation.
///
/// All mutable lifecycle ownership remains behind
/// ``DockerPluginLifecycleService``. Reconstructing this actor after an API
/// service restart therefore cannot forget an uncertain claim or mint a new
/// token for an existing FIFO/reader.
public actor DockerPluginServiceLogDriverProvider: ContainerLogDriverProvider {
    private let descriptorValue: LogDriverDescriptor
    private let configurationResolver: any DockerPluginConfigurationResolving
    private let service: any DockerPluginLifecycleService

    public init(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        readLogs: Bool,
        trust: LogDriverTrust = .approved,
        configurationResolver: any DockerPluginConfigurationResolving,
        service: any DockerPluginLifecycleService
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
        self.service = service
    }

    public var descriptor: LogDriverDescriptor {
        get async throws { descriptorValue }
    }

    public func activeSandboxGeneration() async throws -> UInt64 {
        let generation = try await service.activeSandboxGeneration()
        guard generation > 0 else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        return generation
    }

    public func start(
        _ request: LogDriverStartRequestV1
    ) async throws -> StartedLogDriverSessionV1 {
        try validateProviderIdentity(request)
        guard
            let sandboxGeneration = request.candidateSandboxGeneration,
            sandboxGeneration == (try await activeSandboxGeneration())
        else {
            throw DockerPluginProtocolError.invalidSessionFence
        }
        let binding = try await configurationResolver.configuration(for: request)
        try validate(binding, for: request)
        let result = try await service.startWriter(
            DockerPluginWriterOpenRequest(request: request, info: binding.info)
        )
        try validate(result, request: request)
        return result.started
    }

    public func reconcileStart(
        _ request: LogDriverStartRequestV1
    ) async throws -> LogDriverStartReconciliationV1 {
        try validateProviderIdentity(request)
        switch try await service.reconcileWriterOpen(request) {
        case .absent:
            return .absent
        case .prepared(let result):
            try validate(result, request: request)
            return .prepared(result.started)
        case .conflict:
            return .conflict
        case .uncertain:
            return .uncertain
        }
    }

    public func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validateProviderIdentity(request)
        return try await service.reconcileWriter(request)
    }

    public func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validateProviderIdentity(request)
        return try await service.fenceWriter(request)
    }

    public func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try validateProviderIdentity(request)
        return try await service.closeWriter(request)
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> StartedLogDriverReaderV1 {
        try validateProviderIdentity(request)
        guard descriptorValue.capabilities.nativeRead else {
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
        }
        let binding = try await configurationResolver.configuration(for: request)
        try validate(binding, for: request)
        let result = try await service.openReader(
            DockerPluginReaderOpenRequest(request: request, info: binding.info)
        )
        try validate(result, request: request)
        return result.started
    }

    public func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        try validateProviderIdentity(request)
        switch try await service.reconcileReaderOpen(request) {
        case .absent:
            return .absent
        case .prepared(let result):
            try validate(result, request: request)
            return .prepared(result.started)
        case .conflict:
            return .conflict
        case .uncertain:
            return .uncertain
        }
    }

    public func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try validateProviderIdentity(request)
        return try await service.reconcileReader(request)
    }

    public func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try validateProviderIdentity(request)
        return try await service.closeReader(request)
    }

    public func reclaimTerminalEffect(
        _ request: LogDriverTerminalEffectReclaimV1
    ) async throws {
        try validateProviderIdentity(request)
        try await service.reclaimTerminalEffect(request)
    }

    private func validate(
        _ result: DockerPluginServiceStartedWriter,
        request: LogDriverStartRequestV1
    ) throws {
        guard
            result.started.receipt.request == request,
            result.capabilities.readLogs
                == descriptorValue.capabilities.nativeRead
        else {
            throw DockerPluginProtocolError.capabilityMismatch
        }
    }

    private func validate(
        _ result: DockerPluginServiceStartedReader,
        request: LogDriverReaderOpenRequestV1
    ) throws {
        guard
            result.started.receipt.request == request,
            result.capabilities.readLogs,
            result.capabilities.readLogs
                == descriptorValue.capabilities.nativeRead
        else {
            throw DockerPluginProtocolError.capabilityMismatch
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

    private func validateProviderIdentity(
        _ request: LogDriverSessionCallV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }

    private func validateProviderIdentity(
        _ request: LogDriverReaderCallV1
    ) throws {
        guard
            request.providerID == descriptorValue.providerIdentity.id,
            request.providerGeneration == descriptorValue.providerGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }

    private func validateProviderIdentity(
        _ request: LogDriverTerminalEffectReclaimV1
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
}
