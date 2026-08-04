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
import Containerization
import CryptoKit
import Foundation

/// Immutable materialization intent bound to one durable workload operation.
///
/// The shared runtime reads the sealed bundle instead of accepting a second,
/// potentially divergent copy of the container configuration. Network
/// endpoints are supplied separately because allocation remains an
/// Engine-owned transactional effect.
public struct EngineLinuxSandboxWorkloadStartRequestV1: Codable, Equatable, Sendable {
    public let context: WorkloadStartContextV1
    public let workloadRoot: URL
    public let workloadConfigurationDigest: String
    public let dynamicEnvironment: [String: String]
    public let networkEndpoints: [WorkloadNetworkEndpoint]
    /// Whether the helper must watch the init process and withdraw protected
    /// service routing as soon as that process terminates.
    public let monitorTerminal: Bool

    public init(
        context: WorkloadStartContextV1,
        workloadRoot: URL,
        workloadConfigurationDigest: String,
        dynamicEnvironment: [String: String] = [:],
        networkEndpoints: [WorkloadNetworkEndpoint] = [],
        monitorTerminal: Bool = false
    ) {
        self.context = context
        self.workloadRoot = workloadRoot
        self.workloadConfigurationDigest = workloadConfigurationDigest
        self.dynamicEnvironment = dynamicEnvironment
        self.networkEndpoints = networkEndpoints
        self.monitorTerminal = monitorTerminal
    }
}

/// Exact authority-owned stop intent for one active workload generation.
/// The runtime retains the matching receipt so a lost response can be
/// reconciled without stopping a replacement generation.
public struct EngineLinuxSandboxWorkloadStopRequestV1: Codable, Equatable,
    Sendable
{
    public let sandboxID: String
    public let sandboxGeneration: UInt64
    public let workloadID: String
    public let workloadProcessGeneration: UInt64
    public let operationGeneration: UInt64
    public let idempotencyKey: String
    public let requestDigest: String

    public init(
        sandboxID: String,
        sandboxGeneration: UInt64,
        workloadID: String,
        workloadProcessGeneration: UInt64,
        operationGeneration: UInt64,
        idempotencyKey: String,
        requestDigest: String
    ) {
        self.sandboxID = sandboxID
        self.sandboxGeneration = sandboxGeneration
        self.workloadID = workloadID
        self.workloadProcessGeneration = workloadProcessGeneration
        self.operationGeneration = operationGeneration
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
    }
}

public struct EngineLinuxSandboxWorkloadStopReceiptV1: Codable, Equatable,
    Sendable
{
    public let request: EngineLinuxSandboxWorkloadStopRequestV1

    public init(request: EngineLinuxSandboxWorkloadStopRequestV1) {
        self.request = request
    }
}

public enum EngineLinuxSandboxWorkloadStopObservationV1: Codable, Equatable,
    Sendable
{
    case stopped(EngineLinuxSandboxWorkloadStopReceiptV1)
    case absent
    case running
    case unknown
}

public protocol EngineLinuxSandboxWorkloadRuntimeV1: Sendable {
    func startWorkload(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1,
        stdio: [FileHandle?]
    ) async throws -> WorkloadProcessReceiptV1

    func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1

    func stopWorkload(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopReceiptV1

    func observeWorkloadStop(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopObservationV1
}

/// Binds one sealed workload intent to the generic transaction resolver.
public struct EngineLinuxSandboxWorkloadProcessStarterV1: WorkloadProcessStarterV1 {
    private let runtime: any EngineLinuxSandboxWorkloadRuntimeV1
    private let workloadRoot: URL
    private let workloadConfigurationDigest: String
    private let dynamicEnvironment: [String: String]
    private let networkEndpoints: [WorkloadNetworkEndpoint]
    private let stdio: [FileHandle?]
    private let monitorTerminal: Bool

    public init(
        runtime: any EngineLinuxSandboxWorkloadRuntimeV1,
        workloadRoot: URL,
        workloadConfigurationDigest: String,
        dynamicEnvironment: [String: String] = [:],
        networkEndpoints: [WorkloadNetworkEndpoint] = [],
        stdio: [FileHandle?] = [],
        monitorTerminal: Bool = false
    ) {
        self.runtime = runtime
        self.workloadRoot = workloadRoot
        self.workloadConfigurationDigest = workloadConfigurationDigest
        self.dynamicEnvironment = dynamicEnvironment
        self.networkEndpoints = networkEndpoints
        self.stdio = stdio
        self.monitorTerminal = monitorTerminal
    }

    public func start(context: WorkloadStartContextV1) async throws -> WorkloadProcessReceiptV1 {
        try await runtime.startWorkload(request(for: context), stdio: stdio)
    }

    public func observe(context: WorkloadStartContextV1) async throws -> WorkloadProcessObservationV1 {
        try await runtime.observeWorkloadStart(request(for: context))
    }

    private func request(for context: WorkloadStartContextV1) -> EngineLinuxSandboxWorkloadStartRequestV1 {
        EngineLinuxSandboxWorkloadStartRequestV1(
            context: context,
            workloadRoot: workloadRoot,
            workloadConfigurationDigest: workloadConfigurationDigest,
            dynamicEnvironment: dynamicEnvironment,
            networkEndpoints: networkEndpoints,
            monitorTerminal: monitorTerminal
        )
    }
}

public enum EngineLinuxSandboxWorkloadIntegrityV1 {
    public static func configurationDigest(at workloadRoot: URL) throws -> String {
        let configuration = try RuntimeConfiguration.readRuntimeConfiguration(from: workloadRoot)
        return try configurationDigest(configuration)
    }

    public static func configurationDigest(_ configuration: RuntimeConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
