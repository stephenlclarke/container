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

import CVersion
import ContainerVersion
import ContainerizationExtras
import Foundation

/// Top-level configuration decoded from config.toml.
///
/// Each section maps to a nested struct. Missing keys fall back to
/// hardcoded defaults via custom `init(from:)` implementations.
public final class ContainerSystemConfig: Codable, Sendable, Initable {
    public let build: BuildConfig
    public let container: ContainerConfig
    public let dns: DNSConfig
    public let kernel: KernelConfig
    public let logging: LoggingConfig
    public let machine: MachineConfig
    public let network: NetworkConfig
    public let registry: RegistryConfig
    public let vminit: VminitConfig

    public init(
        build: BuildConfig = .init(),
        container: ContainerConfig = .init(),
        dns: DNSConfig = .init(),
        kernel: KernelConfig = .init(),
        logging: LoggingConfig = .init(),
        machine: MachineConfig = MachineConfig.default,
        network: NetworkConfig = .init(),
        registry: RegistryConfig = .init(),
        vminit: VminitConfig = .init()
    ) {
        self.build = build
        self.container = container
        self.dns = dns
        self.kernel = kernel
        self.logging = logging
        self.machine = machine
        self.network = network
        self.registry = registry
        self.vminit = vminit
    }

    public init() {
        self.build = .init()
        self.container = .init()
        self.dns = .init()
        self.kernel = .init()
        self.logging = .init()
        self.machine = MachineConfig.default
        self.network = .init()
        self.registry = .init()
        self.vminit = .init()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.build = try container.decodeIfPresent(BuildConfig.self, forKey: .build) ?? .init()
        self.container = try container.decodeIfPresent(ContainerConfig.self, forKey: .container) ?? .init()
        self.dns = try container.decodeIfPresent(DNSConfig.self, forKey: .dns) ?? .init()
        self.kernel = try container.decodeIfPresent(KernelConfig.self, forKey: .kernel) ?? .init()
        self.logging = try container.decodeIfPresent(LoggingConfig.self, forKey: .logging) ?? .init()
        self.machine = try container.decodeIfPresent(MachineConfig.self, forKey: .machine) ?? MachineConfig.default
        self.network = try container.decodeIfPresent(NetworkConfig.self, forKey: .network) ?? .init()
        self.registry = try container.decodeIfPresent(RegistryConfig.self, forKey: .registry) ?? .init()
        self.vminit = try container.decodeIfPresent(VminitConfig.self, forKey: .vminit) ?? .init()
    }

    /// Audience-specific projection for routine configuration diagnostics.
    public var routineInspection: ContainerSystemConfigInspection {
        ContainerSystemConfigInspection(configuration: self)
    }
}

/// Redaction-safe system configuration projection. It is deliberately
/// encode-only so diagnostic output cannot be loaded as authoritative state.
public struct ContainerSystemConfigInspection: Encodable, Sendable {
    public let diagnosticKind = "container-system-config-inspection-v1"
    public let build: BuildConfig
    public let container: ContainerConfig
    public let dns: DNSConfig
    public let kernel: KernelConfig
    public let logging: LoggingConfigInspection
    public let machine: MachineConfig
    public let network: NetworkConfig
    public let registry: RegistryConfig
    public let vminit: VminitConfig

    fileprivate init(configuration: ContainerSystemConfig) {
        self.build = configuration.build
        self.container = configuration.container
        self.dns = configuration.dns
        self.kernel = configuration.kernel
        self.logging = configuration.logging.routineInspection()
        self.machine = configuration.machine
        self.network = configuration.network
        self.registry = configuration.registry
        self.vminit = configuration.vminit
    }
}

final public class BuildConfig: Codable, Sendable {
    public static let defaultRosetta = true
    public static let defaultCPUs = 2
    public static let defaultMemory = try! MemorySize("2048MB")
    public static var defaultImage: String {
        let repository = String(cString: get_container_builder_shim_repository())
        let digest = String(cString: get_container_builder_shim_digest())
        if !digest.isEmpty {
            return "\(repository)@\(digest)"
        }
        let tag = String(cString: get_container_builder_shim_version())
        return "\(repository):\(tag)"
    }

    public let rosetta: Bool
    public let cpus: Int
    public let memory: MemorySize
    public let image: String

    public init(
        rosetta: Bool = defaultRosetta,
        cpus: Int = defaultCPUs,
        memory: MemorySize = defaultMemory,
        image: String = defaultImage
    ) {
        self.rosetta = rosetta
        self.cpus = cpus
        self.memory = memory
        self.image = image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? Self.defaultRosetta
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? Self.defaultMemory
        self.image = try container.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
    }
}

final public class ContainerConfig: Codable, Sendable {
    public static let defaultCPUs = 4
    public static let defaultMemory = try! MemorySize("1g")

    public let cpus: Int
    public let memory: MemorySize

    public init(cpus: Int = defaultCPUs, memory: MemorySize = defaultMemory) {
        self.cpus = cpus
        self.memory = memory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? Self.defaultCPUs
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? Self.defaultMemory
    }
}

/// System-owned defaults used when a container logging request omits a driver
/// or options. The API authority, not Compose, applies these defaults at create.
final public class LoggingConfig: Codable, Sendable {
    public static let defaultDriver = "json-file"

    public let driver: String
    public let options: [String: String]

    public init(driver: String = defaultDriver, options: [String: String] = [:]) {
        self.driver = driver
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case driver
        case options
        case diagnosticKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let diagnosticKind = try container.decodeIfPresent(String.self, forKey: .diagnosticKind) {
            throw DecodingError.dataCorruptedError(
                forKey: .diagnosticKind,
                in: container,
                debugDescription: "logging inspection '\(diagnosticKind)' cannot be used as authoritative configuration"
            )
        }
        self.driver = try container.decodeIfPresent(String.self, forKey: .driver) ?? Self.defaultDriver

        // ConfigSnapshotReader cannot enumerate dictionary keys. config.toml
        // therefore carries arbitrary defaults as adjacent name/value pairs,
        // while ordinary JSON Codable callers continue to use a map.
        if let dictionary = try? container.decode([String: String].self, forKey: .options) {
            self.options = dictionary
            return
        }

        let entries = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        guard entries.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorruptedError(
                forKey: .options,
                in: container,
                debugDescription: "logging options must contain adjacent name and value pairs"
            )
        }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: entries.count, by: 2) {
            let name = entries[index]
            guard options[name] == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .options,
                    in: container,
                    debugDescription: "duplicate logging option '\(name)'"
                )
            }
            options[name] = entries[index + 1]
        }
        self.options = options
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(driver, forKey: .driver)
        try container.encode(options, forKey: .options)
    }

    /// Routine configuration diagnostics expose only values the authority has
    /// classified as safe and report protected option names separately.
    public func routineInspection(
        revealing safeOptionNames: Set<String> = []
    ) -> LoggingConfigInspection {
        var safeOptions: [String: String] = [:]
        var protectedOptionNames: [String] = []
        for (name, value) in options {
            if safeOptionNames.contains(name) {
                safeOptions[name] = value
            } else {
                protectedOptionNames.append(name)
            }
        }
        return LoggingConfigInspection(
            driver: driver,
            safeOptions: safeOptions,
            protectedOptionNames: protectedOptionNames.sorted()
        )
    }
}

/// Redaction-safe daemon-default projection. It cannot be decoded back into
/// authoritative configuration.
public struct LoggingConfigInspection: Encodable, Equatable, Sendable {
    public let diagnosticKind = "logging-config-inspection-v1"
    public let driver: String
    public let safeOptions: [String: String]
    public let protectedOptionNames: [String]
    public let protectedOptionCount: Int

    public init(
        driver: String,
        safeOptions: [String: String],
        protectedOptionNames: [String]
    ) {
        self.driver = driver
        self.safeOptions = safeOptions
        self.protectedOptionNames = protectedOptionNames.sorted()
        self.protectedOptionCount = protectedOptionNames.count
    }
}

final public class DNSConfig: Codable, Sendable {
    public let domain: String?

    public init(domain: String? = nil) {
        self.domain = domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain)
    }
}

final public class VminitConfig: Codable, Sendable {
    public static var defaultImage: String {
        ReleaseVersion.vminitImage()
    }

    public let image: String

    public init(image: String = defaultImage) {
        self.image = image
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try container.decodeIfPresent(String.self, forKey: .image) ?? Self.defaultImage
    }
}

final public class KernelConfig: Codable, Sendable {
    public static let defaultBinaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
    public static let defaultURL: URL =
        URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")!
    public static let defaultDigest = "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"

    private enum CodingKeys: String, CodingKey {
        case binaryPath
        case url
        case digest
    }

    public let binaryPath: String
    public let url: URL
    public let digest: String

    public init(binaryPath: String = defaultBinaryPath, url: URL = defaultURL, digest: String = defaultDigest) {
        self.binaryPath = binaryPath
        self.url = url
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.binaryPath =
            try container.decodeIfPresent(String.self, forKey: .binaryPath)
            ?? Self.defaultBinaryPath
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            guard let parsed = URL(string: urlString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: "invalid kernel URL '\(urlString)'")
            }
            self.url = parsed
        } else {
            self.url = Self.defaultURL
        }
        if let digest = try container.decodeIfPresent(String.self, forKey: .digest) {
            self.digest = digest
        } else if self.url.absoluteString == Self.defaultURL.absoluteString {
            self.digest = Self.defaultDigest
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .digest,
                in: container,
                debugDescription: "kernel.digest is required when kernel.url is not the default URL")
        }
    }

    // JSONEncoder special-cases URL to encode as absoluteString, but third-party
    // encoders (e.g. TOMLEncoder) hit Foundation's default Codable conformance which
    // encodes into a keyed container with a "relative" key. Encode as a plain string
    // so all formats produce a consistent URL representation.
    // If more config types start using URL, consider a property wrapper or a wrapper
    // type (like MemorySize) that encodes/decodes URL as a string uniformly.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(binaryPath, forKey: .binaryPath)
        try container.encode(url.absoluteString, forKey: .url)
        try container.encode(digest, forKey: .digest)
    }
}

final public class NetworkConfig: Codable, Sendable {
    public let subnet: CIDRv4?
    public let subnetv6: CIDRv6?

    public init(subnet: CIDRv4? = nil, subnetv6: CIDRv6? = nil) {
        self.subnet = subnet
        self.subnetv6 = subnetv6
    }
}

final public class RegistryConfig: Codable, Sendable {
    public static let defaultDomain = "docker.io"

    public let domain: String

    public init(domain: String = defaultDomain) {
        self.domain = domain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? Self.defaultDomain
    }
}
