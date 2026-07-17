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

import ContainerizationExtras

/// The runtime status of a network — the addresses assigned once the network
/// plugin is active. Only present after the network has started.
public struct NetworkStatus: Codable, Sendable {
    /// The IPv4 subnet assigned to the network.
    public let ipv4Subnet: CIDRv4

    /// The IPv4 gateway address.
    public let ipv4Gateway: IPv4Address

    /// The IPv4 CIDR range used for dynamic attachment allocation, if configured.
    public let ipv4AllocationRange: CIDRv4?

    /// IPv4 addresses reserved from attachment allocation.
    public let ipv4ReservedAddresses: [IPv4Address]

    /// The IPv6 subnet assigned to the network, if IPv6 is enabled.
    public let ipv6Subnet: CIDRv6?

    public init(
        ipv4Subnet: CIDRv4,
        ipv4Gateway: IPv4Address,
        ipv4AllocationRange: CIDRv4? = nil,
        ipv4ReservedAddresses: [IPv4Address] = [],
        ipv6Subnet: CIDRv6?
    ) {
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv4AllocationRange = ipv4AllocationRange
        self.ipv4ReservedAddresses = ipv4ReservedAddresses
        self.ipv6Subnet = ipv6Subnet
    }

    enum CodingKeys: String, CodingKey {
        case ipv4Subnet
        case ipv4Gateway
        case ipv4AllocationRange
        case ipv4ReservedAddresses
        case ipv6Subnet
    }

    /// Decodes a network status, treating statuses written before reserved IPv4
    /// addresses were introduced as having no additional reservations.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ipv4Subnet = try container.decode(CIDRv4.self, forKey: .ipv4Subnet)
        ipv4Gateway = try container.decode(IPv4Address.self, forKey: .ipv4Gateway)
        ipv4AllocationRange = try container.decodeIfPresent(CIDRv4.self, forKey: .ipv4AllocationRange)
        ipv4ReservedAddresses = try container.decodeIfPresent([IPv4Address].self, forKey: .ipv4ReservedAddresses) ?? []
        ipv6Subnet = try container.decodeIfPresent(CIDRv6.self, forKey: .ipv6Subnet)
    }

    /// Encodes the active network status.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ipv4Subnet, forKey: .ipv4Subnet)
        try container.encode(ipv4Gateway, forKey: .ipv4Gateway)
        try container.encodeIfPresent(ipv4AllocationRange, forKey: .ipv4AllocationRange)
        try container.encode(ipv4ReservedAddresses, forKey: .ipv4ReservedAddresses)
        try container.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
    }
}
