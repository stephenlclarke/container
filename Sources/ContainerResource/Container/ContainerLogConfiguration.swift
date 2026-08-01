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

/// Persisted logging policy applied to container stdio.
///
/// Existing containers use the unversioned `storage`/rotation representation.
/// Logging v2 uses an explicit schema with lossless requested and immutable
/// resolved state. The legacy accessors remain available until the v2 runtime
/// writer replaces `ContainerLogFileWriter`.
public struct ContainerLogConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 2

    /// Storage backend used for captured container stdio.
    public enum Storage: String, Codable, Equatable, Sendable {
        /// Store logs in the container bundle on the local host.
        case local

        /// Do not persist captured container stdio.
        case none
    }

    /// Local log storage backend.
    public internal(set) var storage: Storage

    /// Maximum size in bytes for the active local log file before rotation.
    public internal(set) var maxSizeInBytes: UInt64?

    /// Maximum number of local log files to retain, including the active file.
    public internal(set) var maxFileCount: Int?

    /// Nil for the unversioned legacy representation.
    public private(set) var schemaVersion: UInt32?

    /// Redaction-safe durable form of the exact client request for logging v2.
    public private(set) var requested: PersistedContainerLogRequest?

    /// Authority-resolved immutable logging configuration for logging v2.
    public private(set) var resolved: ResolvedContainerLogConfiguration?

    public static let `default` = ContainerLogConfiguration()

    public init(
        storage: Storage = .local,
        maxSizeInBytes: UInt64? = nil,
        maxFileCount: Int? = nil
    ) {
        self.storage = storage
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = maxFileCount
        self.schemaVersion = nil
        self.requested = nil
        self.resolved = nil
    }

    /// Creates a logging-v2 configuration without changing the legacy runtime
    /// writer. The compatibility storage value is used only by old runtime code
    /// during the implementation window and is not encoded into the v2 schema.
    public init(
        requested: ContainerLogRequest,
        resolved: ResolvedContainerLogConfiguration
    ) throws {
        var requestedSafeOptions: [String: String] = [:]
        var requestedProtectedOptionNames: [String] = []
        let protectedNames = Set(resolved.protectedOptionNames)
        for (name, value) in requested.options {
            if resolved.safeOptions[name] == value {
                requestedSafeOptions[name] = value
            } else if protectedNames.contains(name) {
                requestedProtectedOptionNames.append(name)
            } else {
                throw LogDriverContractError.unprotectedRequestedOption(name)
            }
        }
        let persistedRequest = try PersistedContainerLogRequest(
            driver: requested.driver,
            safeOptions: requestedSafeOptions,
            protectedOptionNames: requestedProtectedOptionNames
        )
        try Self.validate(requested: persistedRequest, resolved: resolved)
        self.schemaVersion = Self.currentSchemaVersion
        self.requested = persistedRequest
        self.resolved = resolved
        self.storage = Self.compatibilityStorage(resolved: resolved)
        self.maxSizeInBytes = nil
        self.maxFileCount = nil
    }

    /// True when this value came from the pre-v2 local/none representation.
    public var isLegacy: Bool {
        schemaVersion == nil
    }

    /// Internal driver identity used to retain old stores without inventing
    /// whether `.local` originally meant omission, `json-file`, or `local`.
    public var effectiveDriver: String {
        if isLegacy {
            return storage == .none ? "none" : "legacy-local-v1"
        }
        return resolved?.driver ?? requested?.driver ?? ""
    }

    /// Separates safe values from protected option names and removes the
    /// protected-store reference.
    public var routineInspection: ContainerLogConfigurationInspection {
        guard let schemaVersion, let requested, let resolved else {
            return ContainerLogConfigurationInspection(
                storage: storage,
                maxSizeInBytes: maxSizeInBytes,
                maxFileCount: maxFileCount
            )
        }

        return ContainerLogConfigurationInspection(
            sourceSchemaVersion: schemaVersion,
            requested: ContainerLogRequestInspection(
                sourceSchemaVersion: requested.schemaVersion,
                driver: requested.driver,
                safeOptions: requested.safeOptions,
                protectedOptionNames: requested.protectedOptionNames
            ),
            resolved: resolved.routineInspection
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requested
        case resolved
        case storage
        case maxSizeInBytes
        case maxFileCount
        case diagnosticKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let diagnosticKind = try container.decodeIfPresent(String.self, forKey: .diagnosticKind) {
            throw DecodingError.dataCorruptedError(
                forKey: .diagnosticKind,
                in: container,
                debugDescription:
                    "container logging inspection '\(diagnosticKind)' cannot be used as authoritative configuration"
            )
        }
        guard container.contains(.schemaVersion) else {
            guard !container.contains(.requested), !container.contains(.resolved) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .storage,
                    in: container,
                    debugDescription: "unversioned logging configuration cannot contain v2 state"
                )
            }
            self.storage = try container.decode(Storage.self, forKey: .storage)
            self.maxSizeInBytes = try container.decodeIfPresent(UInt64.self, forKey: .maxSizeInBytes)
            self.maxFileCount = try container.decodeIfPresent(Int.self, forKey: .maxFileCount)
            self.schemaVersion = nil
            self.requested = nil
            self.resolved = nil
            return
        }

        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported container logging schema version \(schemaVersion)"
            )
        }
        guard !container.contains(.storage), !container.contains(.maxSizeInBytes), !container.contains(.maxFileCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "logging v2 configuration cannot contain legacy state"
            )
        }

        let requested = try container.decode(PersistedContainerLogRequest.self, forKey: .requested)
        let resolved = try container.decode(ResolvedContainerLogConfiguration.self, forKey: .resolved)
        try Self.validate(requested: requested, resolved: resolved)
        self.schemaVersion = schemaVersion
        self.requested = requested
        self.resolved = resolved
        self.storage = Self.compatibilityStorage(resolved: resolved)
        self.maxSizeInBytes = nil
        self.maxFileCount = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let schemaVersion else {
            try container.encode(storage, forKey: .storage)
            try container.encodeIfPresent(maxSizeInBytes, forKey: .maxSizeInBytes)
            try container.encodeIfPresent(maxFileCount, forKey: .maxFileCount)
            return
        }

        try container.encode(schemaVersion, forKey: .schemaVersion)
        guard let requested, let resolved else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "logging v2 configuration requires requested and resolved state"
                )
            )
        }
        try container.encode(requested, forKey: .requested)
        try container.encode(resolved, forKey: .resolved)
    }

    private static func compatibilityStorage(resolved: ResolvedContainerLogConfiguration) -> Storage {
        resolved.driver == "none" ? .none : .local
    }

    private static func validate(
        requested: PersistedContainerLogRequest,
        resolved: ResolvedContainerLogConfiguration
    ) throws {
        for (name, requestedValue) in requested.safeOptions {
            guard resolved.safeOptions[name] == requestedValue else {
                throw LogDriverContractError.invalidResolvedConfiguration(
                    "requested safe option '\(name)' does not match resolved state"
                )
            }
        }

        let resolvedProtectedNames = Set(resolved.protectedOptionNames)
        guard Set(requested.protectedOptionNames).isSubset(of: resolvedProtectedNames) else {
            throw LogDriverContractError.invalidResolvedConfiguration(
                "requested protected option names are not contained in resolved state"
            )
        }
    }
}

/// Redaction-safe request projection. It is deliberately not Decodable.
public struct ContainerLogRequestInspection: Encodable, Equatable, Sendable {
    public let diagnosticKind = "container-log-request-inspection-v1"
    public let sourceSchemaVersion: UInt32
    public let driver: String?
    public let safeOptions: [String: String]
    public let protectedOptionNames: [String]
    public let protectedOptionCount: Int

    fileprivate init(
        sourceSchemaVersion: UInt32,
        driver: String?,
        safeOptions: [String: String],
        protectedOptionNames: [String]
    ) {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.driver = driver
        self.safeOptions = safeOptions
        self.protectedOptionNames = protectedOptionNames
        self.protectedOptionCount = protectedOptionNames.count
    }
}

/// Redaction-safe logging projection. Its diagnostic discriminator prevents
/// both legacy and v2 output from becoming authoritative state.
public struct ContainerLogConfigurationInspection: Encodable, Equatable, Sendable {
    public let diagnosticKind = "container-log-configuration-inspection-v1"
    public let sourceSchemaVersion: UInt32?
    public let requested: ContainerLogRequestInspection?
    public let resolved: ResolvedContainerLogInspection?
    public let storage: ContainerLogConfiguration.Storage?
    public let maxSizeInBytes: UInt64?
    public let maxFileCount: Int?

    fileprivate init(
        sourceSchemaVersion: UInt32,
        requested: ContainerLogRequestInspection,
        resolved: ResolvedContainerLogInspection
    ) {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.requested = requested
        self.resolved = resolved
        self.storage = nil
        self.maxSizeInBytes = nil
        self.maxFileCount = nil
    }

    fileprivate init(
        storage: ContainerLogConfiguration.Storage,
        maxSizeInBytes: UInt64?,
        maxFileCount: Int?
    ) {
        self.sourceSchemaVersion = nil
        self.requested = nil
        self.resolved = nil
        self.storage = storage
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = maxFileCount
    }

    private enum CodingKeys: String, CodingKey {
        case diagnosticKind, sourceSchemaVersion, requested, resolved, storage, maxSizeInBytes, maxFileCount
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(diagnosticKind, forKey: .diagnosticKind)
        if let sourceSchemaVersion {
            try container.encode(sourceSchemaVersion, forKey: .sourceSchemaVersion)
            try container.encode(requested, forKey: .requested)
            try container.encode(resolved, forKey: .resolved)
        } else {
            try container.encode(storage, forKey: .storage)
            try container.encodeIfPresent(maxSizeInBytes, forKey: .maxSizeInBytes)
            try container.encodeIfPresent(maxFileCount, forKey: .maxFileCount)
        }
    }
}
