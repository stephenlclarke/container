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

import Foundation

public enum DockerSemanticHelperProvenance {
    public static let protocolVersion: UInt16 = 1
    public static let helperVersion = "1"
    public static let goVersion = "go1.25.6"
    public static let goDarwinARM64ArchiveSHA256 =
        "984521ae978a5377c7d782fd2dd953291840d7d3d0bd95781a1f32f16d94a006"
    public static let mobyTag = "docker-v29.2.1"
    public static let mobyCommit = "6bc6209b88a7a834c91f77d848e025c79e0227a1"
    public static let mobyTemplatesSHA256 =
        "4c82c12a734e49627c745d24ef54eb658727ead67ac17253ac86f8785e746252"
    public static let mobyLogInfoSHA256 =
        "96565a4bd2db9c7021c7e4a1b16bca100d86ca5a2f892843518add0b86ec8624"
}

public struct DockerSemanticHelperGeneration: Hashable, Sendable {
    public let providerID: String
    public let providerGeneration: UInt64

    public init(providerID: String, providerGeneration: UInt64) {
        precondition(!providerID.isEmpty)
        precondition(providerGeneration > 0)
        self.providerID = providerID
        self.providerGeneration = providerGeneration
    }
}

public enum DockerSemanticHelperRemoteErrorCategory: UInt16, Sendable {
    case invalidRequest = 1
    case parse = 2
    case execute = 3
    case deadlineExceeded = 4
    case cancelled = 5
    case internalFailure = 6
    case outputLimit = 7
}

public struct DockerSemanticHelperRemoteError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    public let category: DockerSemanticHelperRemoteErrorCategory
    /// Exact bytes returned by Go. Callers must not include these bytes in
    /// routine diagnostics because parse errors can contain protected values.
    public let messageBytes: Data

    public init(
        category: DockerSemanticHelperRemoteErrorCategory,
        messageBytes: Data
    ) {
        self.category = category
        self.messageBytes = messageBytes
    }

    public var description: String {
        "DockerSemanticHelperRemoteError(category: \(category), message: <redacted>)"
    }
}

public enum DockerSemanticHelperError: Error, Equatable, Sendable {
    case helperNotFound
    case invalidManifest
    case binaryDigestMismatch
    case invalidCodeSignature
    case spawnFailed(Int32)
    case generationFenced
    case protocolViolation
    case deadlineExceeded
    case cancelled
    case helperExited
    case inputLimitExceeded
}

public struct DockerSemanticHelperManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedBytes = 64 * 1024

    public let schemaVersion: UInt32
    public let helperVersion: String
    public let protocolVersion: UInt16
    public let goVersion: String
    public let goArchiveSHA256: String
    public let mobyTag: String
    public let mobyCommit: String
    public let mobyTemplatesSHA256: String
    public let mobyLogInfoSHA256: String
    public let helperSourceSHA256: String
    public let oracleFixtureSHA256: String
    public let binarySHA256: String
    public let architecture: String

    public func validatePinnedProvenance() throws {
        guard
            schemaVersion == Self.currentSchemaVersion,
            helperVersion == DockerSemanticHelperProvenance.helperVersion,
            protocolVersion == DockerSemanticHelperProvenance.protocolVersion,
            goVersion == DockerSemanticHelperProvenance.goVersion,
            goArchiveSHA256
                == DockerSemanticHelperProvenance.goDarwinARM64ArchiveSHA256,
            mobyTag == DockerSemanticHelperProvenance.mobyTag,
            mobyCommit == DockerSemanticHelperProvenance.mobyCommit,
            mobyTemplatesSHA256
                == DockerSemanticHelperProvenance.mobyTemplatesSHA256,
            mobyLogInfoSHA256
                == DockerSemanticHelperProvenance.mobyLogInfoSHA256,
            architecture == "arm64",
            Self.isSHA256(helperSourceSHA256),
            Self.isSHA256(oracleFixtureSHA256),
            Self.isSHA256(binarySHA256)
        else {
            throw DockerSemanticHelperError.invalidManifest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }
}

public struct DockerSemanticBytePair: Equatable, Sendable {
    public let key: Data
    public let value: Data

    public init(key: Data, value: Data) {
        self.key = key
        self.value = value
    }

    public init(key: String, value: String) {
        self.init(key: Data(key.utf8), value: Data(value.utf8))
    }
}

public struct DockerLogTemplateInfo: Equatable, Sendable {
    public let containerID: Data
    public let containerName: Data
    public let containerEntrypoint: Data
    public let containerArguments: [Data]
    public let containerImageID: Data
    public let containerImageName: Data
    public let containerCreatedSeconds: Int64
    public let containerCreatedNanoseconds: Int32
    public let containerEnvironment: [Data]
    public let containerLabels: [DockerSemanticBytePair]
    public let logPath: Data
    public let daemonName: Data
    public let hostname: Data

    public init(
        containerID: Data,
        containerName: Data,
        containerEntrypoint: Data = Data(),
        containerArguments: [Data] = [],
        containerImageID: Data = Data(),
        containerImageName: Data = Data(),
        containerCreatedSeconds: Int64,
        containerCreatedNanoseconds: Int32,
        containerEnvironment: [Data] = [],
        containerLabels: [DockerSemanticBytePair] = [],
        logPath: Data = Data(),
        daemonName: Data,
        hostname: Data
    ) {
        precondition((0...999_999_999).contains(containerCreatedNanoseconds))
        self.containerID = containerID
        self.containerName = containerName
        self.containerEntrypoint = containerEntrypoint
        self.containerArguments = containerArguments
        self.containerImageID = containerImageID
        self.containerImageName = containerImageName
        self.containerCreatedSeconds = containerCreatedSeconds
        self.containerCreatedNanoseconds = containerCreatedNanoseconds
        self.containerEnvironment = containerEnvironment
        self.containerLabels = containerLabels
        self.logPath = logPath
        self.daemonName = daemonName
        self.hostname = hostname
    }

    public init(
        containerID: String,
        containerName: String,
        containerEntrypoint: String = "",
        containerArguments: [String] = [],
        containerImageID: String = "",
        containerImageName: String = "",
        containerCreated: Date,
        containerEnvironment: [String] = [],
        containerLabels: [String: String] = [:],
        logPath: String = "",
        daemonName: String,
        hostname: String
    ) {
        let interval = containerCreated.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        let fractionalNanoseconds = ((interval - seconds) * 1_000_000_000)
            .rounded()
        let normalizedSeconds: Int64
        let normalizedNanoseconds: Int32
        if fractionalNanoseconds >= 1_000_000_000 {
            normalizedSeconds = Int64(seconds) + 1
            normalizedNanoseconds = 0
        } else {
            normalizedSeconds = Int64(seconds)
            normalizedNanoseconds = Int32(fractionalNanoseconds)
        }
        self.init(
            containerID: Data(containerID.utf8),
            containerName: Data(containerName.utf8),
            containerEntrypoint: Data(containerEntrypoint.utf8),
            containerArguments: containerArguments.map { Data($0.utf8) },
            containerImageID: Data(containerImageID.utf8),
            containerImageName: Data(containerImageName.utf8),
            containerCreatedSeconds: normalizedSeconds,
            containerCreatedNanoseconds: normalizedNanoseconds,
            containerEnvironment: containerEnvironment.map { Data($0.utf8) },
            containerLabels: containerLabels.map {
                DockerSemanticBytePair(key: $0.key, value: $0.value)
            },
            logPath: Data(logPath.utf8),
            daemonName: Data(daemonName.utf8),
            hostname: Data(hostname.utf8)
        )
    }
}

public struct DockerParsedURL: Equatable, Sendable {
    public let scheme: Data
    public let opaque: Data
    public let username: Data
    public let password: Data
    public let passwordIsSet: Bool
    public let host: Data
    public let path: Data
    public let rawPath: Data
    public let forceQuery: Bool
    public let rawQuery: Data
    public let fragment: Data
    public let rawFragment: Data
    public let hostname: Data
    public let port: Data

    public init(
        scheme: Data,
        opaque: Data,
        username: Data,
        password: Data,
        passwordIsSet: Bool,
        host: Data,
        path: Data,
        rawPath: Data,
        forceQuery: Bool,
        rawQuery: Data,
        fragment: Data,
        rawFragment: Data,
        hostname: Data,
        port: Data
    ) {
        self.scheme = scheme
        self.opaque = opaque
        self.username = username
        self.password = password
        self.passwordIsSet = passwordIsSet
        self.host = host
        self.path = path
        self.rawPath = rawPath
        self.forceQuery = forceQuery
        self.rawQuery = rawQuery
        self.fragment = fragment
        self.rawFragment = rawFragment
        self.hostname = hostname
        self.port = port
    }
}

public struct DockerFluentdAddress: Equatable, Sendable {
    public let networkProtocol: Data
    public let host: Data
    public let port: UInt16
    public let path: Data

    public init(
        networkProtocol: Data,
        host: Data,
        port: UInt16,
        path: Data
    ) {
        self.networkProtocol = networkProtocol
        self.host = host
        self.port = port
        self.path = path
    }
}

public struct DockerGELFAddress: Equatable, Sendable {
    public let scheme: Data
    public let address: Data
    public let host: Data
    public let port: UInt16

    public init(scheme: Data, address: Data, host: Data, port: UInt16) {
        self.scheme = scheme
        self.address = address
        self.host = host
        self.port = port
    }
}

public struct DockerSyslogAddress: Equatable, Sendable {
    public let networkProtocol: Data
    public let address: Data
    public let host: Data
    public let port: UInt16

    public init(
        networkProtocol: Data,
        address: Data,
        host: Data,
        port: UInt16
    ) {
        self.networkProtocol = networkProtocol
        self.address = address
        self.host = host
        self.port = port
    }
}

public protocol DockerSemanticServicing: Sendable {
    func matchRegularExpression(
        pattern: Data,
        candidates: [Data],
        timeout: Duration
    ) throws -> [Bool]

    func renderLogTemplate(
        template: Data,
        info: DockerLogTemplateInfo,
        configuration: [DockerSemanticBytePair],
        timeout: Duration
    ) throws -> Data

    func parseURL(_ source: Data, timeout: Duration) throws -> DockerParsedURL

    func parseFluentdAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerFluentdAddress

    func parseGELFAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerGELFAddress

    func parseSyslogAddress(
        _ source: Data,
        timeout: Duration
    ) throws -> DockerSyslogAddress
}
