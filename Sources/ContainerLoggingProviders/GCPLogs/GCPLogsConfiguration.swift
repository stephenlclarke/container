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
import DockerSemanticHelper
import Foundation

public enum GCPLogsProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case invalidConnectionPolicy
    case transportClosed
    case flushTimedOut
    case closeTimedOut
    case invalidProviderIdentity
    case idempotencyConflict
    case invalidEffectToken
    case invalidSessionFence
    case readUnsupported
}

public struct GCPLogsConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                startTimeout: .seconds(30),
                requestTimeout: .seconds(5),
                closeTimeout: .seconds(30)
            )
        } catch {
            preconditionFailure("invalid built-in gcplogs policy: \(error)")
        }
    }()

    public let startTimeout: Duration
    public let requestTimeout: Duration
    public let closeTimeout: Duration

    public init(
        startTimeout: Duration,
        requestTimeout: Duration,
        closeTimeout: Duration
    ) throws {
        guard
            startTimeout > .zero,
            requestTimeout > .zero,
            closeTimeout > .zero,
            startTimeout <= .seconds(30),
            requestTimeout <= .seconds(30),
            closeTimeout <= .seconds(30)
        else {
            throw GCPLogsProviderError.invalidConnectionPolicy
        }
        self.startTimeout = startTimeout
        self.requestTimeout = requestTimeout
        self.closeTimeout = closeTimeout
    }
}

public typealias GCPLogsContainerInfo = SyslogContainerInfo

public struct GCPLogsDriverConfiguration: Equatable, Sendable {
    public let options: [String: String]
    public let info: GCPLogsContainerInfo
    public let policy: GCPLogsConnectionPolicy

    public init(
        options: [String: String],
        info: GCPLogsContainerInfo,
        policy: GCPLogsConnectionPolicy = .dockerCompatible
    ) throws {
        if let unknown = options.keys.sorted().first(where: {
            !Self.knownOptionNames.contains($0)
        }) {
            throw GCPLogsProviderError.unknownOption(unknown)
        }
        self.options = options
        self.info = info
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: GCPLogsContainerInfo,
        policy: GCPLogsConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        try Self(options: options, info: info, policy: policy)
    }

    public static let knownOptionNames: Set<String> = [
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
        "env",
        "env-regex",
        "gcp-log-cmd",
        "gcp-meta-id",
        "gcp-meta-name",
        "gcp-meta-zone",
        "gcp-project",
        "labels",
        "labels-regex",
        "max-buffer-size",
        "mode",
    ]

    var semanticConfiguration: [DockerSemanticBytePair] {
        options.map { DockerSemanticBytePair(key: $0.key, value: $0.value) }
    }

    var dockerInfo: DockerLogTemplateInfo { info.dockerTemplateInfo }
}

public struct GCPLogsConfigurationBinding: Equatable, Sendable {
    public let semanticRequestDigest: String
    public let containerID: String
    public let leaseGeneration: UInt64
    public let providerID: String
    public let providerGeneration: UInt64
    public let configuration: GCPLogsDriverConfiguration
    public let loggingService: any DockerGCPLoggingServicing

    public init(
        semanticRequestDigest: String,
        containerID: String,
        leaseGeneration: UInt64,
        providerID: String,
        providerGeneration: UInt64,
        configuration: GCPLogsDriverConfiguration,
        loggingService: any DockerGCPLoggingServicing
    ) {
        self.semanticRequestDigest = semanticRequestDigest
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.configuration = configuration
        self.loggingService = loggingService
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

public protocol GCPLogsConfigurationResolving: Sendable {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> GCPLogsConfigurationBinding
}
