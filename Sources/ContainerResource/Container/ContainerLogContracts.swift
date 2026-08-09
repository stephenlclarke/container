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

import CryptoKit
import Foundation

private func decodeCurrentSchemaVersion<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key,
    expected: UInt32,
    type: String
) throws -> UInt32 {
    let version = try container.decode(UInt32.self, forKey: key)
    guard version == expected else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "unsupported \(type) schema version \(version)"
        )
    }
    return version
}

/// A lossless logging request supplied by a Container API client.
///
/// A `nil` driver means "use the daemon default". Empty and arbitrary strings,
/// option names, and option values remain untouched for authority resolution.
public struct ContainerLogRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedTransportBytes = 2 * 1024 * 1024

    public let schemaVersion: UInt32
    public var driver: String?
    public var options: [String: String]

    public init(driver: String? = nil, options: [String: String] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.driver = driver
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "container log request"
        )
        self.driver = try container.decodeIfPresent(String.self, forKey: .driver)
        self.options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }
}

/// Durable, redaction-safe representation of the exact requested logging
/// shape. Protected values live only behind the resolved configuration's
/// protected reference; ordinary container persistence retains their names so
/// a full-authority Engine projection can reconstruct the request later.
public struct PersistedContainerLogRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let driver: String?
    public let safeOptions: [String: String]
    public let protectedOptionNames: [String]

    public init(
        driver: String?,
        safeOptions: [String: String] = [:],
        protectedOptionNames: [String] = []
    ) throws {
        let protectedNames = Set(protectedOptionNames)
        guard protectedNames.count == protectedOptionNames.count else {
            throw LogDriverContractError.invalidResolvedConfiguration(
                "duplicate requested protected option name"
            )
        }
        guard protectedNames.isDisjoint(with: safeOptions.keys) else {
            throw LogDriverContractError.invalidResolvedConfiguration(
                "requested safe and protected option names overlap"
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.driver = driver
        self.safeOptions = safeOptions
        self.protectedOptionNames = protectedOptionNames.sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "persisted container log request"
        )
        try self.init(
            driver: container.decodeIfPresent(String.self, forKey: .driver),
            safeOptions: container.decodeIfPresent([String: String].self, forKey: .safeOptions) ?? [:],
            protectedOptionNames: container.decodeIfPresent([String].self, forKey: .protectedOptionNames) ?? []
        )
    }
}

/// A logging-scoped, non-secret reference to protected option material.
/// The referenced bytes are deliberately not representable by this type.
public struct LoggingProtectedOptionsReference: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let objectID: String
    public let integrityDigest: String

    public init(objectID: String, integrityDigest: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.objectID = objectID
        self.integrityDigest = integrityDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "protected logging options reference"
        )
        self.objectID = try container.decode(String.self, forKey: .objectID)
        self.integrityDigest = try container.decode(String.self, forKey: .integrityDigest)
    }
}

/// Stable identity for a logging provider implementation.
public struct LogDriverProviderIdentity: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public enum Kind: String, Codable, Equatable, Sendable {
        case core
        case native
        case linuxService
        case dockerPlugin
    }

    public let schemaVersion: UInt32
    public let id: String
    public let version: String
    public let kind: Kind

    public init(id: String, version: String, kind: Kind) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.version = version
        self.kind = kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver provider identity"
        )
        self.id = try container.decode(String.self, forKey: .id)
        self.version = try container.decode(String.self, forKey: .version)
        self.kind = try container.decode(Kind.self, forKey: .kind)
    }
}

public enum LogDriverContractError: Error, Equatable, Sendable {
    case invalidDeliveryMode
    case invalidCacheConfiguration
    case invalidReadPolicy
    case invalidResolvedConfiguration(String)
    case duplicateAlias(String)
    case duplicateOption(String)
    case duplicateRegisteredName(String)
    case invalidCapabilities(String)
    case invalidOptionContract(String)
    case contractDigestMismatch(expected: String, actual: String)
    case unprotectedRequestedOption(String)
}

/// Delivery policy resolved independently from a driver implementation.
/// `requestedMode == nil` preserves omission, which is observably different
/// from explicit blocking for dual-cache delivery.
public struct LogDeliveryConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let defaultNonBlockingBufferSizeInBytes: UInt64 = 1_000_000

    public enum Mode: String, Codable, Equatable, Sendable {
        case blocking
        case nonBlocking = "non-blocking"
    }

    public let schemaVersion: UInt32
    public let requestedMode: Mode?
    public let effectiveMode: Mode
    /// The exact `max-buffer-size` request. `nil` preserves omission.
    public let maxBufferSizeInBytes: UInt64?
    /// The queue capacity actually applied for non-blocking delivery.
    public let effectiveMaxBufferSizeInBytes: UInt64?

    public init(requestedMode: Mode? = nil, maxBufferSizeInBytes: UInt64? = nil) throws {
        let effectiveMode = requestedMode ?? .blocking
        let effectiveMaxBufferSizeInBytes =
            effectiveMode == .nonBlocking
            ? maxBufferSizeInBytes ?? Self.defaultNonBlockingBufferSizeInBytes
            : nil
        try self.init(
            requestedMode: requestedMode,
            effectiveMode: effectiveMode,
            maxBufferSizeInBytes: maxBufferSizeInBytes,
            effectiveMaxBufferSizeInBytes: effectiveMaxBufferSizeInBytes
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log delivery configuration"
        )
        try self.init(
            requestedMode: container.decodeIfPresent(Mode.self, forKey: .requestedMode),
            effectiveMode: container.decode(Mode.self, forKey: .effectiveMode),
            maxBufferSizeInBytes: container.decodeIfPresent(UInt64.self, forKey: .maxBufferSizeInBytes),
            effectiveMaxBufferSizeInBytes: container.decodeIfPresent(
                UInt64.self,
                forKey: .effectiveMaxBufferSizeInBytes
            )
        )
    }

    private init(
        requestedMode: Mode?,
        effectiveMode: Mode,
        maxBufferSizeInBytes: UInt64?,
        effectiveMaxBufferSizeInBytes: UInt64?
    ) throws {
        guard effectiveMode == requestedMode ?? .blocking else {
            throw LogDriverContractError.invalidDeliveryMode
        }
        switch effectiveMode {
        case .blocking:
            guard maxBufferSizeInBytes == nil, effectiveMaxBufferSizeInBytes == nil else {
                throw LogDriverContractError.invalidDeliveryMode
            }
        case .nonBlocking:
            let expectedCapacity = maxBufferSizeInBytes ?? Self.defaultNonBlockingBufferSizeInBytes
            guard effectiveMaxBufferSizeInBytes == expectedCapacity else {
                throw LogDriverContractError.invalidDeliveryMode
            }
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.requestedMode = requestedMode
        self.effectiveMode = effectiveMode
        self.maxBufferSizeInBytes = maxBufferSizeInBytes
        self.effectiveMaxBufferSizeInBytes = effectiveMaxBufferSizeInBytes
    }
}

/// Local-cache retention selected for a non-reader driver.
public struct LogCacheConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let maxSizeInBytes: UInt64
    public let maxFileCount: Int
    public let compress: Bool

    public init(maxSizeInBytes: UInt64, maxFileCount: Int, compress: Bool) throws {
        guard maxSizeInBytes > 0, maxFileCount > 0 else {
            throw LogDriverContractError.invalidCacheConfiguration
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = maxFileCount
        self.compress = compress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log cache configuration"
        )
        try self.init(
            maxSizeInBytes: container.decode(UInt64.self, forKey: .maxSizeInBytes),
            maxFileCount: container.decode(Int.self, forKey: .maxFileCount),
            compress: container.decode(Bool.self, forKey: .compress)
        )
    }
}

/// Resolved source used for historical log reads.
public struct LogReadPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public enum Source: String, Codable, Equatable, Sendable {
        case unavailable
        case direct
        case dualCache = "dual-cache"
        case legacyLocalV1 = "legacy-local-v1"
    }

    public let schemaVersion: UInt32
    public let source: Source
    public let cache: LogCacheConfiguration?

    public init(source: Source, cache: LogCacheConfiguration? = nil) throws {
        guard (source == .dualCache) == (cache != nil) else {
            throw LogDriverContractError.invalidReadPolicy
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.cache = cache
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log read policy"
        )
        try self.init(
            source: container.decode(Source.self, forKey: .source),
            cache: container.decodeIfPresent(LogCacheConfiguration.self, forKey: .cache)
        )
    }
}

public enum LogDriverHistoryMigrationError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case unsupported
    case receiptMismatch
}

/// Redaction-safe, replay-stable request for provider-owned readable history.
///
/// The authority derives `terminalHistoryDigest` from the fully terminal
/// source lifecycle ledger. Protected option values and provider tokens are
/// deliberately excluded; providers receive those only through their existing
/// authenticated configuration boundary when an implementation needs them.
public struct LogDriverHistoryMigrationRequestV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let containerID: String
    public let sourceLeaseGeneration: UInt64
    public let targetLeaseGeneration: UInt64
    public let providerID: String
    public let sourceProviderGeneration: UInt64
    public let targetProviderGeneration: UInt64
    public let contractDigest: String
    public let terminalHistoryDigest: String

    public init(
        containerID: String,
        sourceLeaseGeneration: UInt64,
        targetLeaseGeneration: UInt64,
        providerID: String,
        sourceProviderGeneration: UInt64,
        targetProviderGeneration: UInt64,
        contractDigest: String,
        terminalHistoryDigest: String
    ) throws {
        guard
            !containerID.isEmpty,
            containerID.utf8.count <= 4_096,
            sourceLeaseGeneration > 0,
            sourceLeaseGeneration < UInt64.max,
            targetLeaseGeneration == sourceLeaseGeneration + 1,
            !providerID.isEmpty,
            providerID.utf8.count <= 4_096,
            sourceProviderGeneration > 0,
            targetProviderGeneration > sourceProviderGeneration,
            !contractDigest.isEmpty,
            contractDigest.utf8.count <= 1_024,
            !terminalHistoryDigest.isEmpty,
            terminalHistoryDigest.utf8.count <= 1_024
        else {
            throw LogDriverHistoryMigrationError.invalidRequest(
                "provider history migration identity is incomplete"
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.containerID = containerID
        self.sourceLeaseGeneration = sourceLeaseGeneration
        self.targetLeaseGeneration = targetLeaseGeneration
        self.providerID = providerID
        self.sourceProviderGeneration = sourceProviderGeneration
        self.targetProviderGeneration = targetProviderGeneration
        self.contractDigest = contractDigest
        self.terminalHistoryDigest = terminalHistoryDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver history migration request"
        )
        try self.init(
            containerID: container.decode(String.self, forKey: .containerID),
            sourceLeaseGeneration: container.decode(
                UInt64.self,
                forKey: .sourceLeaseGeneration
            ),
            targetLeaseGeneration: container.decode(
                UInt64.self,
                forKey: .targetLeaseGeneration
            ),
            providerID: container.decode(String.self, forKey: .providerID),
            sourceProviderGeneration: container.decode(
                UInt64.self,
                forKey: .sourceProviderGeneration
            ),
            targetProviderGeneration: container.decode(
                UInt64.self,
                forKey: .targetProviderGeneration
            ),
            contractDigest: container.decode(
                String.self,
                forKey: .contractDigest
            ),
            terminalHistoryDigest: container.decode(
                String.self,
                forKey: .terminalHistoryDigest
            )
        )
    }
}

/// Provider acknowledgement persisted with the target logging lease before
/// alias cutover. Replaying the exact request must return the same outcome
/// digest; a provider that cannot guarantee history continuity rejects it.
public struct LogDriverHistoryMigrationReceiptV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let request: LogDriverHistoryMigrationRequestV1
    public let providerOutcomeDigest: String

    public init(
        request: LogDriverHistoryMigrationRequestV1,
        providerOutcomeDigest: String
    ) throws {
        guard
            !providerOutcomeDigest.isEmpty,
            providerOutcomeDigest.utf8.count <= 1_024
        else {
            throw LogDriverHistoryMigrationError.invalidRequest(
                "provider history migration outcome is incomplete"
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.request = request
        self.providerOutcomeDigest = providerOutcomeDigest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver history migration receipt"
        )
        try self.init(
            request: container.decode(
                LogDriverHistoryMigrationRequestV1.self,
                forKey: .request
            ),
            providerOutcomeDigest: container.decode(
                String.self,
                forKey: .providerOutcomeDigest
            )
        )
    }
}

/// Immutable logging configuration selected by the Container authority.
/// Secret option values never enter this ordinary persisted object.
public struct ResolvedContainerLogConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let leaseGeneration: UInt64
    public let driver: String
    public let safeOptions: [String: String]
    public let protectedOptionNames: [String]
    public let protectedOptionReference: LoggingProtectedOptionsReference?
    public let delivery: LogDeliveryConfiguration
    public let readPolicy: LogReadPolicy
    public let providerIdentity: LogDriverProviderIdentity
    public let providerGenerationAtResolution: UInt64
    public let contractDigest: String
    public let providerHistoryMigrationReceipt: LogDriverHistoryMigrationReceiptV1?

    public init(
        leaseGeneration: UInt64,
        driver: String,
        safeOptions: [String: String] = [:],
        protectedOptionNames: [String] = [],
        protectedOptionReference: LoggingProtectedOptionsReference? = nil,
        delivery: LogDeliveryConfiguration,
        readPolicy: LogReadPolicy,
        providerIdentity: LogDriverProviderIdentity,
        providerGenerationAtResolution: UInt64,
        contractDigest: String,
        providerHistoryMigrationReceipt:
            LogDriverHistoryMigrationReceiptV1? = nil
    ) throws {
        let protectedNames = Set(protectedOptionNames)
        guard protectedNames.count == protectedOptionNames.count else {
            throw LogDriverContractError.invalidResolvedConfiguration("duplicate protected option name")
        }
        guard protectedNames.isDisjoint(with: safeOptions.keys) else {
            throw LogDriverContractError.invalidResolvedConfiguration("safe and protected option names overlap")
        }
        guard protectedNames.isEmpty == (protectedOptionReference == nil) else {
            throw LogDriverContractError.invalidResolvedConfiguration("protected option reference does not match names")
        }
        if let receipt = providerHistoryMigrationReceipt {
            let request = receipt.request
            guard
                readPolicy.source == .direct,
                request.targetLeaseGeneration == leaseGeneration,
                request.providerID == providerIdentity.id,
                request.targetProviderGeneration
                    == providerGenerationAtResolution,
                request.contractDigest == contractDigest
            else {
                throw LogDriverContractError.invalidResolvedConfiguration(
                    "provider history migration receipt does not match the target lease"
                )
            }
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.leaseGeneration = leaseGeneration
        self.driver = driver
        self.safeOptions = safeOptions
        self.protectedOptionNames = protectedOptionNames.sorted()
        self.protectedOptionReference = protectedOptionReference
        self.delivery = delivery
        self.readPolicy = readPolicy
        self.providerIdentity = providerIdentity
        self.providerGenerationAtResolution = providerGenerationAtResolution
        self.contractDigest = contractDigest
        self.providerHistoryMigrationReceipt =
            providerHistoryMigrationReceipt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "resolved container log configuration"
        )
        try self.init(
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration),
            driver: container.decode(String.self, forKey: .driver),
            safeOptions: container.decodeIfPresent([String: String].self, forKey: .safeOptions) ?? [:],
            protectedOptionNames: container.decodeIfPresent([String].self, forKey: .protectedOptionNames) ?? [],
            protectedOptionReference: container.decodeIfPresent(
                LoggingProtectedOptionsReference.self,
                forKey: .protectedOptionReference
            ),
            delivery: container.decode(LogDeliveryConfiguration.self, forKey: .delivery),
            readPolicy: container.decode(LogReadPolicy.self, forKey: .readPolicy),
            providerIdentity: container.decode(LogDriverProviderIdentity.self, forKey: .providerIdentity),
            providerGenerationAtResolution: container.decode(UInt64.self, forKey: .providerGenerationAtResolution),
            contractDigest: container.decode(String.self, forKey: .contractDigest),
            providerHistoryMigrationReceipt: container.decodeIfPresent(
                LogDriverHistoryMigrationReceiptV1.self,
                forKey: .providerHistoryMigrationReceipt
            )
        )
    }

    public var routineInspection: ResolvedContainerLogInspection {
        ResolvedContainerLogInspection(configuration: self)
    }
}

/// Redaction-safe native diagnostic projection. Its shape omits the
/// authoritative schema key so it cannot be decoded as resolved state.
public struct ResolvedContainerLogInspection: Encodable, Equatable, Sendable {
    public let diagnosticKind = "resolved-container-log-inspection-v1"
    public let sourceSchemaVersion: UInt32
    public let leaseGeneration: UInt64
    public let driver: String
    public let safeOptions: [String: String]
    public let protectedOptionNames: [String]
    public let protectedOptionCount: Int
    public let delivery: LogDeliveryConfiguration
    public let readPolicy: LogReadPolicy
    public let providerIdentity: LogDriverProviderIdentity
    public let providerGenerationAtResolution: UInt64
    public let contractDigest: String

    fileprivate init(configuration: ResolvedContainerLogConfiguration) {
        self.sourceSchemaVersion = configuration.schemaVersion
        self.leaseGeneration = configuration.leaseGeneration
        self.driver = configuration.driver
        self.safeOptions = configuration.safeOptions
        self.protectedOptionNames = configuration.protectedOptionNames
        self.protectedOptionCount = configuration.protectedOptionNames.count
        self.delivery = configuration.delivery
        self.readPolicy = configuration.readPolicy
        self.providerIdentity = configuration.providerIdentity
        self.providerGenerationAtResolution = configuration.providerGenerationAtResolution
        self.contractDigest = configuration.contractDigest
    }
}

/// Docker-shaped full-authority inspect payload. Construction belongs in the
/// Engine authority after it resolves protected bytes; routine callers cannot
/// derive this value from a resolved configuration.
public struct DockerLogConfigurationInspection: Encodable, Equatable, Sendable {
    public let driver: String
    public let options: [String: String]

    private enum CodingKeys: String, CodingKey {
        case driver = "Type"
        case options = "Config"
    }

    public init(driver: String, options: [String: String]) {
        self.driver = driver
        self.options = options
    }
}

public enum LogDriverOptionValidationPhase: String, Codable, Equatable, Sendable {
    case create
    case start
}

public enum LogDriverOptionValueKind: String, Codable, Equatable, Sendable {
    case string
    case boolean
    case positiveInteger
    case size
    case commaSeparatedNames
    case regularExpression
    /// The provider owns an exact regular-expression dialect that the
    /// authority cannot safely approximate with Swift Regex.
    case providerRegularExpression
    case tagTemplate
}

/// Selects a side-effect-free, driver-specific create grammar when scalar
/// option descriptors cannot express relationships such as an address scheme
/// controlling which companion options are legal.
public enum LogDriverCreateValidationProfile: String, Codable, Equatable, Sendable {
    case standard
    case dockerFluentd29_2_1 = "docker-fluentd-29.2.1"
    case dockerGELF29_2_1 = "docker-gelf-29.2.1"
    case dockerSyslog29_2_1 = "docker-syslog-29.2.1"
}

public struct LogDriverOptionDescriptor: Codable, Equatable, Sendable {
    public let name: String
    public let valueKind: LogDriverOptionValueKind
    public let validationPhase: LogDriverOptionValidationPhase
    public let isSecret: Bool
    /// Empty means the value grammar is fully described by `valueKind`.
    public let allowedValues: [String]

    public init(
        name: String,
        valueKind: LogDriverOptionValueKind,
        validationPhase: LogDriverOptionValidationPhase = .create,
        isSecret: Bool = false,
        allowedValues: [String] = []
    ) {
        self.name = name
        self.valueKind = valueKind
        self.validationPhase = validationPhase
        self.isSecret = isSecret
        self.allowedValues = allowedValues.sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            valueKind: try container.decode(LogDriverOptionValueKind.self, forKey: .valueKind),
            validationPhase: try container.decode(LogDriverOptionValidationPhase.self, forKey: .validationPhase),
            isSecret: try container.decode(Bool.self, forKey: .isSecret),
            allowedValues: try container.decodeIfPresent([String].self, forKey: .allowedValues) ?? []
        )
    }
}

/// A typed relationship between two driver options. When the trigger option
/// is present, the required option must be present with one of these values.
public struct LogDriverCrossOptionConstraint: Codable, Equatable, Sendable {
    public let whenOptionPresent: String
    public let requiredOption: String
    public let requiredAllowedValues: [String]

    public init(
        whenOptionPresent: String,
        requiredOption: String,
        requiredAllowedValues: [String]
    ) {
        self.whenOptionPresent = whenOptionPresent
        self.requiredOption = requiredOption
        self.requiredAllowedValues = requiredAllowedValues.sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            whenOptionPresent: try container.decode(String.self, forKey: .whenOptionPresent),
            requiredOption: try container.decode(String.self, forKey: .requiredOption),
            requiredAllowedValues: try container.decode([String].self, forKey: .requiredAllowedValues)
        )
    }
}

public enum LogDriverPlacement: String, Codable, Equatable, Sendable {
    case macOSHost = "macos-host"
    case engineLinuxSandbox = "engine-linux-sandbox"
}

public enum LogDriverTrust: String, Codable, Equatable, Sendable {
    case builtIn = "built-in"
    case signed
    case approved
}

public enum LogDriverReadFilter: String, Codable, Equatable, Sendable {
    case stdout, stderr, follow, tail, since, until, timestamps, details
}

public enum LogDriverLogPathVisibility: String, Codable, Equatable, Sendable {
    case none
    case publicActiveFile = "public-active-file"
    case privateStore = "private-store"
}

/// Operational defaults for a native file store. These are not injected into
/// Docker-visible resolved option maps.
public struct LogDriverFileDefaults: Codable, Equatable, Sendable {
    public let maxSizeInBytes: UInt64?
    public let maxFileCount: Int
    public let compress: Bool

    public init(maxSizeInBytes: UInt64?, maxFileCount: Int, compress: Bool) {
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = maxFileCount
        self.compress = compress
    }
}

public struct LogDriverCapabilities: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let deliveryModes: [LogDeliveryConfiguration.Mode]
    public let nativeRead: Bool
    public let readFilters: [LogDriverReadFilter]
    public let supportsDualCache: Bool
    public let supportsDockerPluginProtocol: Bool
    public let requiresDeliverySession: Bool
    public let logPathVisibility: LogDriverLogPathVisibility
    public let fileDefaults: LogDriverFileDefaults?

    public init(
        deliveryModes: [LogDeliveryConfiguration.Mode],
        nativeRead: Bool,
        readFilters: [LogDriverReadFilter],
        supportsDualCache: Bool,
        supportsDockerPluginProtocol: Bool,
        requiresDeliverySession: Bool,
        logPathVisibility: LogDriverLogPathVisibility,
        fileDefaults: LogDriverFileDefaults?
    ) throws {
        guard Set(deliveryModes.map(\.rawValue)).count == deliveryModes.count else {
            throw LogDriverContractError.invalidCapabilities("duplicate delivery mode")
        }
        guard Set(readFilters.map(\.rawValue)).count == readFilters.count else {
            throw LogDriverContractError.invalidCapabilities("duplicate read filter")
        }
        guard nativeRead || readFilters.isEmpty else {
            throw LogDriverContractError.invalidCapabilities("non-reader advertises read filters")
        }
        guard (logPathVisibility == .none) == (fileDefaults == nil) else {
            throw LogDriverContractError.invalidCapabilities("path visibility does not match file defaults")
        }
        if let fileDefaults {
            guard
                fileDefaults.maxFileCount > 0,
                fileDefaults.maxSizeInBytes.map({ $0 > 0 }) ?? true
            else {
                throw LogDriverContractError.invalidCapabilities("file defaults require positive retention bounds")
            }
        }
        guard requiresDeliverySession || deliveryModes.isEmpty else {
            throw LogDriverContractError.invalidCapabilities("sessionless driver advertises delivery modes")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.deliveryModes = deliveryModes.sorted { $0.rawValue < $1.rawValue }
        self.nativeRead = nativeRead
        self.readFilters = readFilters.sorted { $0.rawValue < $1.rawValue }
        self.supportsDualCache = supportsDualCache
        self.supportsDockerPluginProtocol = supportsDockerPluginProtocol
        self.requiresDeliverySession = requiresDeliverySession
        self.logPathVisibility = logPathVisibility
        self.fileDefaults = fileDefaults
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver capabilities"
        )
        try self.init(
            deliveryModes: container.decode([LogDeliveryConfiguration.Mode].self, forKey: .deliveryModes),
            nativeRead: container.decode(Bool.self, forKey: .nativeRead),
            readFilters: container.decode([LogDriverReadFilter].self, forKey: .readFilters),
            supportsDualCache: container.decode(Bool.self, forKey: .supportsDualCache),
            supportsDockerPluginProtocol: container.decode(Bool.self, forKey: .supportsDockerPluginProtocol),
            requiresDeliverySession: container.decode(Bool.self, forKey: .requiresDeliverySession),
            logPathVisibility: container.decode(LogDriverLogPathVisibility.self, forKey: .logPathVisibility),
            fileDefaults: container.decodeIfPresent(LogDriverFileDefaults.self, forKey: .fileDefaults)
        )
    }
}

/// Versioned data-only descriptor for one registered logging-driver name.
public struct LogDriverDescriptor: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let driver: String
    public let aliases: [String]
    public let providerIdentity: LogDriverProviderIdentity
    /// A loaded-provider fencing generation. It is deliberately excluded from
    /// the behavior digest so a provider reload does not change its contract.
    public let providerGeneration: UInt64
    public let placement: LogDriverPlacement
    public let trust: LogDriverTrust
    public let optionContractDigest: String
    public let options: [LogDriverOptionDescriptor]
    public let crossOptionConstraints: [LogDriverCrossOptionConstraint]
    public let createValidationProfile: LogDriverCreateValidationProfile
    public let acceptsUnknownOptions: Bool
    public let capabilities: LogDriverCapabilities

    public init(
        driver: String,
        aliases: [String] = [],
        providerIdentity: LogDriverProviderIdentity,
        providerGeneration: UInt64,
        placement: LogDriverPlacement,
        trust: LogDriverTrust,
        optionContractDigest: String? = nil,
        options: [LogDriverOptionDescriptor],
        crossOptionConstraints: [LogDriverCrossOptionConstraint] = [],
        createValidationProfile: LogDriverCreateValidationProfile = .standard,
        acceptsUnknownOptions: Bool = false,
        capabilities: LogDriverCapabilities
    ) throws {
        guard Set(aliases).count == aliases.count, !aliases.contains(driver) else {
            throw LogDriverContractError.duplicateAlias(driver)
        }
        let optionNames = options.map(\.name)
        guard Set(optionNames).count == optionNames.count else {
            let duplicate = optionNames.first { name in optionNames.filter { $0 == name }.count > 1 } ?? ""
            throw LogDriverContractError.duplicateOption(duplicate)
        }
        for option in options {
            guard Set(option.allowedValues).count == option.allowedValues.count else {
                throw LogDriverContractError.invalidOptionContract(
                    "option '\(option.name)' contains duplicate allowed values"
                )
            }
        }

        let optionNamesSet = Set(optionNames)
        var seenConstraints: [LogDriverCrossOptionConstraint] = []
        for constraint in crossOptionConstraints {
            guard optionNamesSet.contains(constraint.whenOptionPresent) else {
                throw LogDriverContractError.invalidOptionContract(
                    "constraint trigger '\(constraint.whenOptionPresent)' is not a declared option"
                )
            }
            guard optionNamesSet.contains(constraint.requiredOption) else {
                throw LogDriverContractError.invalidOptionContract(
                    "constraint requirement '\(constraint.requiredOption)' is not a declared option"
                )
            }
            guard !constraint.requiredAllowedValues.isEmpty else {
                throw LogDriverContractError.invalidOptionContract(
                    "constraint for '\(constraint.whenOptionPresent)' has no allowed values"
                )
            }
            guard Set(constraint.requiredAllowedValues).count == constraint.requiredAllowedValues.count else {
                throw LogDriverContractError.invalidOptionContract(
                    "constraint for '\(constraint.whenOptionPresent)' contains duplicate allowed values"
                )
            }
            if let requiredDescriptor = options.first(where: { $0.name == constraint.requiredOption }),
                !requiredDescriptor.allowedValues.isEmpty,
                !Set(constraint.requiredAllowedValues).isSubset(of: Set(requiredDescriptor.allowedValues))
            {
                throw LogDriverContractError.invalidOptionContract(
                    "constraint for '\(constraint.whenOptionPresent)' permits an undeclared '\(constraint.requiredOption)' value"
                )
            }
            guard !seenConstraints.contains(constraint) else {
                throw LogDriverContractError.invalidOptionContract(
                    "duplicate constraint for '\(constraint.whenOptionPresent)'"
                )
            }
            seenConstraints.append(constraint)
        }

        let normalizedAliases = aliases.sorted()
        let normalizedOptions = options.sorted { $0.name < $1.name }
        let normalizedConstraints = crossOptionConstraints.sorted(by: Self.constraintPrecedes)
        let canonicalForm = Self.makeCanonicalForm(
            driver: driver,
            aliases: normalizedAliases,
            providerIdentity: providerIdentity,
            placement: placement,
            trust: trust,
            options: normalizedOptions,
            crossOptionConstraints: normalizedConstraints,
            createValidationProfile: createValidationProfile,
            acceptsUnknownOptions: acceptsUnknownOptions,
            capabilities: capabilities
        )
        let computedDigest = Self.digest(for: canonicalForm)
        if let optionContractDigest, optionContractDigest != computedDigest {
            throw LogDriverContractError.contractDigestMismatch(
                expected: computedDigest,
                actual: optionContractDigest
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.driver = driver
        self.aliases = normalizedAliases
        self.providerIdentity = providerIdentity
        self.providerGeneration = providerGeneration
        self.placement = placement
        self.trust = trust
        self.optionContractDigest = computedDigest
        self.options = normalizedOptions
        self.crossOptionConstraints = normalizedConstraints
        self.createValidationProfile = createValidationProfile
        self.acceptsUnknownOptions = acceptsUnknownOptions
        self.capabilities = capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver descriptor"
        )
        try self.init(
            driver: container.decode(String.self, forKey: .driver),
            aliases: container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            providerIdentity: container.decode(LogDriverProviderIdentity.self, forKey: .providerIdentity),
            providerGeneration: container.decode(UInt64.self, forKey: .providerGeneration),
            placement: container.decode(LogDriverPlacement.self, forKey: .placement),
            trust: container.decode(LogDriverTrust.self, forKey: .trust),
            optionContractDigest: container.decode(String.self, forKey: .optionContractDigest),
            options: container.decode([LogDriverOptionDescriptor].self, forKey: .options),
            crossOptionConstraints: container.decodeIfPresent(
                [LogDriverCrossOptionConstraint].self,
                forKey: .crossOptionConstraints
            ) ?? [],
            createValidationProfile: container.decodeIfPresent(
                LogDriverCreateValidationProfile.self,
                forKey: .createValidationProfile
            ) ?? .standard,
            acceptsUnknownOptions: container.decode(Bool.self, forKey: .acceptsUnknownOptions),
            capabilities: container.decode(LogDriverCapabilities.self, forKey: .capabilities)
        )
    }

    public var registeredNames: [String] { [driver] + aliases }

    public var optionContractCanonicalForm: String {
        Self.makeCanonicalForm(
            driver: driver,
            aliases: aliases,
            providerIdentity: providerIdentity,
            placement: placement,
            trust: trust,
            options: options,
            crossOptionConstraints: crossOptionConstraints,
            createValidationProfile: createValidationProfile,
            acceptsUnknownOptions: acceptsUnknownOptions,
            capabilities: capabilities
        )
    }

    private static func constraintPrecedes(
        _ lhs: LogDriverCrossOptionConstraint,
        _ rhs: LogDriverCrossOptionConstraint
    ) -> Bool {
        if lhs.whenOptionPresent != rhs.whenOptionPresent {
            return lhs.whenOptionPresent < rhs.whenOptionPresent
        }
        if lhs.requiredOption != rhs.requiredOption {
            return lhs.requiredOption < rhs.requiredOption
        }
        return lhs.requiredAllowedValues.lexicographicallyPrecedes(rhs.requiredAllowedValues)
    }

    private static func makeCanonicalForm(
        driver: String,
        aliases: [String],
        providerIdentity: LogDriverProviderIdentity,
        placement: LogDriverPlacement,
        trust: LogDriverTrust,
        options: [LogDriverOptionDescriptor],
        crossOptionConstraints: [LogDriverCrossOptionConstraint],
        createValidationProfile: LogDriverCreateValidationProfile,
        acceptsUnknownOptions: Bool,
        capabilities: LogDriverCapabilities
    ) -> String {
        var writer = LogDriverCanonicalWriter()
        writer.append("contract", "logging-driver-contract-v2")
        writer.append("descriptor.schemaVersion", String(Self.currentSchemaVersion))
        writer.append("driver", driver)
        writer.append("aliases.count", String(aliases.count))
        for (index, alias) in aliases.enumerated() {
            writer.append("aliases[\(index)]", alias)
        }
        writer.append("provider.schemaVersion", String(providerIdentity.schemaVersion))
        writer.append("provider.id", providerIdentity.id)
        writer.append("provider.version", providerIdentity.version)
        writer.append("provider.kind", providerIdentity.kind.rawValue)
        writer.append("placement", placement.rawValue)
        writer.append("trust", trust.rawValue)
        if createValidationProfile != .standard {
            writer.append("createValidationProfile", createValidationProfile.rawValue)
        }
        writer.append("acceptsUnknownOptions", String(acceptsUnknownOptions))
        writer.append("options.count", String(options.count))
        for (index, option) in options.enumerated() {
            let prefix = "options[\(index)]"
            writer.append("\(prefix).name", option.name)
            writer.append("\(prefix).valueKind", option.valueKind.rawValue)
            writer.append("\(prefix).validationPhase", option.validationPhase.rawValue)
            writer.append("\(prefix).isSecret", String(option.isSecret))
            writer.append("\(prefix).allowedValues.count", String(option.allowedValues.count))
            for (valueIndex, value) in option.allowedValues.enumerated() {
                writer.append("\(prefix).allowedValues[\(valueIndex)]", value)
            }
        }
        writer.append("crossOptionConstraints.count", String(crossOptionConstraints.count))
        for (index, constraint) in crossOptionConstraints.enumerated() {
            let prefix = "crossOptionConstraints[\(index)]"
            writer.append("\(prefix).whenOptionPresent", constraint.whenOptionPresent)
            writer.append("\(prefix).requiredOption", constraint.requiredOption)
            writer.append("\(prefix).requiredAllowedValues.count", String(constraint.requiredAllowedValues.count))
            for (valueIndex, value) in constraint.requiredAllowedValues.enumerated() {
                writer.append("\(prefix).requiredAllowedValues[\(valueIndex)]", value)
            }
        }
        writer.append("capabilities.schemaVersion", String(capabilities.schemaVersion))
        writer.append("capabilities.deliveryModes.count", String(capabilities.deliveryModes.count))
        for (index, mode) in capabilities.deliveryModes.enumerated() {
            writer.append("capabilities.deliveryModes[\(index)]", mode.rawValue)
        }
        writer.append("capabilities.nativeRead", String(capabilities.nativeRead))
        writer.append("capabilities.readFilters.count", String(capabilities.readFilters.count))
        for (index, filter) in capabilities.readFilters.enumerated() {
            writer.append("capabilities.readFilters[\(index)]", filter.rawValue)
        }
        writer.append("capabilities.supportsDualCache", String(capabilities.supportsDualCache))
        writer.append(
            "capabilities.supportsDockerPluginProtocol",
            String(capabilities.supportsDockerPluginProtocol)
        )
        writer.append("capabilities.requiresDeliverySession", String(capabilities.requiresDeliverySession))
        writer.append("capabilities.logPathVisibility", capabilities.logPathVisibility.rawValue)
        writer.append("capabilities.fileDefaults.present", String(capabilities.fileDefaults != nil))
        if let defaults = capabilities.fileDefaults {
            writer.append("capabilities.fileDefaults.maxSize.present", String(defaults.maxSizeInBytes != nil))
            if let maxSizeInBytes = defaults.maxSizeInBytes {
                writer.append("capabilities.fileDefaults.maxSizeInBytes", String(maxSizeInBytes))
            }
            writer.append("capabilities.fileDefaults.maxFileCount", String(defaults.maxFileCount))
            writer.append("capabilities.fileDefaults.compress", String(defaults.compress))
        }
        return writer.value
    }

    private static func digest(for canonicalForm: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalForm.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct LogDriverCanonicalWriter {
    private var output = ""

    mutating func append(_ name: String, _ value: String) {
        output += "\(name.utf8.count):\(name)\(value.utf8.count):\(value)\n"
    }

    var value: String { output }
}

public struct LogDriverCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let descriptors: [LogDriverDescriptor]

    public init(descriptors: [LogDriverDescriptor]) throws {
        var names = Set<String>()
        for name in descriptors.flatMap(\.registeredNames) {
            guard names.insert(name).inserted else {
                throw LogDriverContractError.duplicateRegisteredName(name)
            }
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.descriptors = descriptors.sorted { $0.driver < $1.driver }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try decodeCurrentSchemaVersion(
            from: container,
            forKey: .schemaVersion,
            expected: Self.currentSchemaVersion,
            type: "log driver catalog"
        )
        try self.init(descriptors: container.decode([LogDriverDescriptor].self, forKey: .descriptors))
    }

    public func descriptor(named name: String) -> LogDriverDescriptor? {
        descriptors.first { $0.registeredNames.contains(name) }
    }

    public var registeredNames: [String] {
        descriptors.flatMap(\.registeredNames).sorted()
    }
}

/// Data-only catalogue boundary. Effectful writer/reader provider protocols
/// are intentionally deferred until their generation-fenced lifecycle lands.
public protocol LogDriverCatalogProviding: Sendable {
    func logDriverCatalog() async throws -> LogDriverCatalog

    /// Returns the drivers that this authority can advertise without probing
    /// or activating provider workloads.
    ///
    /// Create and start boundaries use ``logDriverCatalog()`` so dynamic
    /// readiness is still revalidated before effects. Discovery surfaces such
    /// as Docker `/info` use this catalogue and must remain side-effect free.
    func advertisedLogDriverCatalog() async throws -> LogDriverCatalog
}

extension LogDriverCatalogProviding {
    public func advertisedLogDriverCatalog() async throws -> LogDriverCatalog {
        try await logDriverCatalog()
    }
}

/// Immutable catalogue source used by the built-in authority and tests.
///
/// Dynamic registries can implement ``LogDriverCatalogProviding`` directly;
/// callers deliberately query the provider again at each create and start
/// boundary so a staged provider-generation change is revalidated instead of
/// being hidden behind a process-lifetime snapshot.
public struct StaticLogDriverCatalogProvider: LogDriverCatalogProviding {
    private let catalog: LogDriverCatalog

    public init(catalog: LogDriverCatalog) {
        self.catalog = catalog
    }

    public func logDriverCatalog() async throws -> LogDriverCatalog {
        catalog
    }
}

/// Built-in core descriptors used when no dynamic provider registry is wired.
/// A production registry appends provider-backed descriptors without changing
/// these canonical core contracts.
public enum BuiltinLogDriverDescriptors {
    public static let coreProvider = LogDriverProviderIdentity(
        id: "com.apple.container.logging.core",
        version: "1",
        kind: .core
    )

    public static let none: LogDriverDescriptor = required {
        try LogDriverDescriptor(
            driver: "none",
            providerIdentity: coreProvider,
            providerGeneration: 1,
            placement: .macOSHost,
            trust: .builtIn,
            options: [],
            acceptsUnknownOptions: true,
            capabilities: LogDriverCapabilities(
                deliveryModes: [],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: false,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: false,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    public static let jsonFile = fileDriver(
        name: "json-file",
        defaults: LogDriverFileDefaults(maxSizeInBytes: nil, maxFileCount: 1, compress: false),
        pathVisibility: .publicActiveFile
    )

    public static let local = fileDriver(
        name: "local",
        defaults: LogDriverFileDefaults(maxSizeInBytes: 20 * 1024 * 1024, maxFileCount: 5, compress: true),
        pathVisibility: .privateStore
    )

    public static let current = required {
        try LogDriverCatalog(descriptors: [none, jsonFile, local])
    }

    private static func fileDriver(
        name: String,
        defaults: LogDriverFileDefaults,
        pathVisibility: LogDriverLogPathVisibility
    ) -> LogDriverDescriptor {
        required {
            try LogDriverDescriptor(
                driver: name,
                providerIdentity: coreProvider,
                providerGeneration: 1,
                placement: .macOSHost,
                trust: .builtIn,
                options: [
                    LogDriverOptionDescriptor(name: "compress", valueKind: .boolean, validationPhase: .start),
                    LogDriverOptionDescriptor(name: "env", valueKind: .commaSeparatedNames),
                    LogDriverOptionDescriptor(name: "env-regex", valueKind: .regularExpression, validationPhase: .start),
                    LogDriverOptionDescriptor(name: "labels", valueKind: .commaSeparatedNames),
                    LogDriverOptionDescriptor(name: "labels-regex", valueKind: .regularExpression, validationPhase: .start),
                    LogDriverOptionDescriptor(name: "max-buffer-size", valueKind: .size),
                    LogDriverOptionDescriptor(name: "max-file", valueKind: .positiveInteger, validationPhase: .start),
                    LogDriverOptionDescriptor(name: "max-size", valueKind: .size, validationPhase: .start),
                    LogDriverOptionDescriptor(
                        name: "mode",
                        valueKind: .string,
                        allowedValues: ["", "blocking", "non-blocking"]
                    ),
                    LogDriverOptionDescriptor(name: "tag", valueKind: .tagTemplate, validationPhase: .start),
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
                    nativeRead: true,
                    readFilters: [.stdout, .stderr, .follow, .tail, .since, .until, .timestamps, .details],
                    supportsDualCache: false,
                    supportsDockerPluginProtocol: false,
                    requiresDeliverySession: true,
                    logPathVisibility: pathVisibility,
                    fileDefaults: defaults
                )
            )
        }
    }

    private static func required<Value>(_ body: () throws -> Value) -> Value {
        do {
            return try body()
        } catch {
            preconditionFailure("invalid built-in logging-driver contract: \(error)")
        }
    }
}
