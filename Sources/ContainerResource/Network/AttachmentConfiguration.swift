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

/// Configuration information for attaching a container network interface to a network.
public struct AttachmentConfiguration: Codable, Sendable {
    /// The network ID associated with the attachment.
    public let network: String

    /// The option information for the attachment
    public let options: AttachmentOptions

    public init(network: String, options: AttachmentOptions) {
        self.network = network
        self.options = options
    }
}

// Option information for a network attachment.
public struct AttachmentOptions: Codable, Sendable {
    /// The hostname associated with the attachment.
    public let hostname: String

    /// Additional DNS names that resolve to this attachment.
    public let aliases: [String]

    /// The MAC address associated with the attachment (optional).
    public let macAddress: MACAddress?

    /// The MTU for the network interface.
    public let mtu: UInt32?

    /// Optional name for the interface inside the guest.
    public let guestInterfaceName: String?

    /// Additional IPv4 or IPv6 addresses configured on the guest interface.
    public let additionalIPAddresses: [CIDR]

    public init(
        hostname: String,
        aliases: [String] = [],
        macAddress: MACAddress? = nil,
        mtu: UInt32? = nil,
        guestInterfaceName: String? = nil,
        additionalIPAddresses: [CIDR] = []
    ) {
        self.hostname = hostname
        self.aliases = aliases
        self.macAddress = macAddress
        self.mtu = mtu
        self.guestInterfaceName = guestInterfaceName
        self.additionalIPAddresses = additionalIPAddresses
    }

    enum CodingKeys: String, CodingKey {
        case hostname
        case aliases
        case macAddress
        case mtu
        case guestInterfaceName
        case additionalIPAddresses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decode(String.self, forKey: .hostname)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        macAddress = try container.decodeIfPresent(MACAddress.self, forKey: .macAddress)
        mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu)
        guestInterfaceName = try container.decodeIfPresent(String.self, forKey: .guestInterfaceName)
        additionalIPAddresses = try container.decodeIfPresent([CIDR].self, forKey: .additionalIPAddresses) ?? []
    }
}
