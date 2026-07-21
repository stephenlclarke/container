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

import ContainerizationError
import ContainerizationExtras
import Foundation

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// The name of the network.
    public let name: String

    /// The unique identifier for the network. Identical to ``name``.
    public var id: String { name }

    /// The network type
    public let mode: NetworkMode

    /// When the network was created.
    public let creationDate: Date

    /// The preferred CIDR address for the IPv4 subnet, if specified
    public let ipv4Subnet: CIDRv4?

    /// The IPv4 gateway address for the network, if specified.
    public let ipv4Gateway: IPv4Address?

    /// The IPv4 CIDR range used for dynamic attachment allocation, if specified.
    public let ipv4AllocationRange: CIDRv4?

    /// IPv4 addresses reserved from attachment allocation.
    public let ipv4ReservedAddresses: [IPv4Address]

    /// The preferred CIDR address for the IPv6 subnet, if specified
    public let ipv6Subnet: CIDRv6?

    /// Whether the network provides IPv6 connectivity.
    public let enableIPv6: Bool

    /// Key-value labels for the network.
    /// Resource labels should not be mutated, except while building a network configurations.
    public let labels: ResourceLabels

    /// The network plugin that manages this network.
    public let plugin: String

    /// Plugin-specific options for this network.
    public let options: [String: String]

    /// Creates a network configuration
    public init(
        name: String,
        mode: NetworkMode,
        ipv4Subnet: CIDRv4? = nil,
        ipv4Gateway: IPv4Address? = nil,
        ipv4AllocationRange: CIDRv4? = nil,
        ipv4ReservedAddresses: [IPv4Address] = [],
        ipv6Subnet: CIDRv6? = nil,
        enableIPv6: Bool = true,
        labels: ResourceLabels = .init(),
        plugin: String,
        options: [String: String] = [:]
    ) throws {
        self.name = name
        self.creationDate = Date()
        self.mode = mode
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv4AllocationRange = ipv4AllocationRange
        self.ipv4ReservedAddresses = ipv4ReservedAddresses
        self.ipv6Subnet = ipv6Subnet
        self.enableIPv6 = enableIPv6
        self.labels = labels
        self.plugin = plugin
        self.options = options
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case name
        // Deprecated: As of 1.0.0. Use ``name`` instead of ``id``.
        // Note: Will be removed in a later release.
        case id
        case creationDate
        case mode
        case ipv4Subnet
        case ipv4Gateway
        case ipv4AllocationRange
        case ipv4ReservedAddresses
        case ipv6Subnet
        case enableIPv6
        case labels
        case plugin
        case options
        // TODO: retain for deserialization compatibility, remove in next major version
        case pluginInfo
        case subnet
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name =
            try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .id)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
        mode = try container.decode(NetworkMode.self, forKey: .mode)
        let subnetText =
            try container.decodeIfPresent(String.self, forKey: .ipv4Subnet)
            ?? container.decodeIfPresent(String.self, forKey: .subnet)
        ipv4Subnet = try subnetText.map { try CIDRv4($0) }
        ipv4Gateway = try container.decodeIfPresent(IPv4Address.self, forKey: .ipv4Gateway)
        ipv4AllocationRange = try container.decodeIfPresent(String.self, forKey: .ipv4AllocationRange)
            .map { try CIDRv4($0) }
        ipv4ReservedAddresses = try container.decodeIfPresent([IPv4Address].self, forKey: .ipv4ReservedAddresses) ?? []
        ipv6Subnet = try container.decodeIfPresent(String.self, forKey: .ipv6Subnet)
            .map { try CIDRv6($0) }
        enableIPv6 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? true
        let decodedLabels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        labels = try .init(decodedLabels)

        if let plugin = try container.decodeIfPresent(String.self, forKey: .plugin) {
            self.plugin = plugin
            self.options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        } else if let legacy = try container.decodeIfPresent(_LegacyPluginInfo.self, forKey: .pluginInfo) {
            // Deprecated: As of 1.0.0. Use ``plugin`` and ``options`` instead.
            // Note: Will be removed in a later release.
            self.plugin = legacy.plugin
            var opts: [String: String] = [:]
            if let variant = legacy.variant { opts["variant"] = variant }
            self.options = opts
        } else {
            self.plugin = "container-network-vmnet"
            self.options = [:]
        }

        try validate()
    }

    /// Encode the configuration to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(ipv4Subnet, forKey: .ipv4Subnet)
        try container.encodeIfPresent(ipv4Gateway, forKey: .ipv4Gateway)
        try container.encodeIfPresent(ipv4AllocationRange, forKey: .ipv4AllocationRange)
        try container.encode(ipv4ReservedAddresses, forKey: .ipv4ReservedAddresses)
        try container.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
        try container.encode(enableIPv6, forKey: .enableIPv6)
        try container.encode(labels, forKey: .labels)
        try container.encode(plugin, forKey: .plugin)
        try container.encode(options, forKey: .options)
    }

    private func validate() throws {
        guard NetworkResource.nameValid(name) else {
            throw ContainerizationError(.invalidArgument, message: "invalid network name: \(name)")
        }
        if let ipv4Gateway {
            guard let ipv4Subnet else {
                throw ContainerizationError(.invalidArgument, message: "an IPv4 gateway requires an IPv4 subnet")
            }
            guard ipv4Subnet.contains(ipv4Gateway), ipv4Gateway != ipv4Subnet.lower, ipv4Gateway != ipv4Subnet.upper else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "IPv4 gateway '\(ipv4Gateway)' must be an allocatable host address in subnet '\(ipv4Subnet)'"
                )
            }
        }

        if let ipv4AllocationRange {
            guard let ipv4Subnet else {
                throw ContainerizationError(.invalidArgument, message: "an IPv4 allocation range requires an IPv4 subnet")
            }
            guard ipv4Subnet.contains(ipv4AllocationRange.lower), ipv4Subnet.contains(ipv4AllocationRange.upper) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "IPv4 allocation range '\(ipv4AllocationRange)' must be contained in IPv4 subnet '\(ipv4Subnet)'"
                )
            }
            guard ipv4Subnet.upper.value - ipv4Subnet.lower.value >= 4 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "IPv4 subnet '\(ipv4Subnet)' has no allocatable host addresses"
                )
            }
            let allocationLower = max(ipv4Subnet.lower.value + 2, ipv4AllocationRange.lower.value)
            let allocationUpper = min(ipv4Subnet.upper.value - 2, ipv4AllocationRange.upper.value)
            guard allocationLower <= allocationUpper else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "IPv4 allocation range '\(ipv4AllocationRange)' contains no allocatable host addresses in subnet '\(ipv4Subnet)'"
                )
            }
        }

        if !ipv4ReservedAddresses.isEmpty {
            guard let ipv4Subnet else {
                throw ContainerizationError(.invalidArgument, message: "IPv4 reserved addresses require an IPv4 subnet")
            }
            guard Set(ipv4ReservedAddresses).count == ipv4ReservedAddresses.count else {
                throw ContainerizationError(.invalidArgument, message: "IPv4 reserved addresses must be unique")
            }
            guard ipv4Subnet.upper.value - ipv4Subnet.lower.value >= 4 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "IPv4 subnet '\(ipv4Subnet)' has no allocatable host addresses"
                )
            }
            let allocationLower = ipv4Subnet.lower.value + 2
            let allocationUpper = ipv4Subnet.upper.value - 2
            for address in ipv4ReservedAddresses {
                guard address.value >= allocationLower, address.value <= allocationUpper else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "IPv4 reserved address '\(address)' must be an allocatable host address in subnet '\(ipv4Subnet)'"
                    )
                }
            }
        }

        if !enableIPv6, ipv6Subnet != nil {
            throw ContainerizationError(
                .invalidArgument,
                message: "an IPv6 subnet requires IPv6 to be enabled"
            )
        }
    }
}

/// Decode helper for stored configurations that used the old `pluginInfo` key.
private struct _LegacyPluginInfo: Codable {
    let plugin: String
    let variant: String?
}
