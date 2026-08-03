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
    public let dynamicEnvironment: [String: String]
    public let networkEndpoints: [WorkloadNetworkEndpoint]

    public init(
        context: WorkloadStartContextV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String] = [:],
        networkEndpoints: [WorkloadNetworkEndpoint] = []
    ) {
        self.context = context
        self.workloadRoot = workloadRoot
        self.dynamicEnvironment = dynamicEnvironment
        self.networkEndpoints = networkEndpoints
    }
}

public protocol EngineLinuxSandboxWorkloadRuntimeV1: Sendable {
    func startWorkload(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1,
        stdio: [FileHandle?]
    ) async throws -> WorkloadProcessReceiptV1

    func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1
}

/// Binds one sealed workload intent to the generic transaction resolver.
public struct EngineLinuxSandboxWorkloadProcessStarterV1: WorkloadProcessStarterV1 {
    private let runtime: any EngineLinuxSandboxWorkloadRuntimeV1
    private let workloadRoot: URL
    private let dynamicEnvironment: [String: String]
    private let networkEndpoints: [WorkloadNetworkEndpoint]
    private let stdio: [FileHandle?]

    public init(
        runtime: any EngineLinuxSandboxWorkloadRuntimeV1,
        workloadRoot: URL,
        dynamicEnvironment: [String: String] = [:],
        networkEndpoints: [WorkloadNetworkEndpoint] = [],
        stdio: [FileHandle?] = []
    ) {
        self.runtime = runtime
        self.workloadRoot = workloadRoot
        self.dynamicEnvironment = dynamicEnvironment
        self.networkEndpoints = networkEndpoints
        self.stdio = stdio
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
            dynamicEnvironment: dynamicEnvironment,
            networkEndpoints: networkEndpoints
        )
    }
}
