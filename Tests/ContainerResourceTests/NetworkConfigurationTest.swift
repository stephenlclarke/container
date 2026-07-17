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
import Testing

@testable import ContainerResource

struct AttachmentConfigurationTest {
    @Test func attachmentOptionsRoundTripAliases() throws {
        let options = AttachmentOptions(
            hostname: "api",
            aliases: ["web", "api.internal"],
            mtu: 1500,
            guestInterfaceName: "backend0",
            additionalIPAddresses: [try CIDR("198.51.100.8/32")],
            requestedIPv4Address: try IPv4Address("198.51.100.9"),
            requestedIPv6Address: try IPv6Address("2001:db8::9")
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(AttachmentOptions.self, from: data)
        let expectedIPv4Address = try IPv4Address("198.51.100.9")
        let expectedIPv6Address = try IPv6Address("2001:db8::9")

        #expect(decoded.hostname == "api")
        #expect(decoded.aliases == ["web", "api.internal"])
        #expect(decoded.mtu == 1500)
        #expect(decoded.guestInterfaceName == "backend0")
        #expect(decoded.additionalIPAddresses == [try CIDR("198.51.100.8/32")])
        #expect(decoded.requestedIPv4Address == expectedIPv4Address)
        #expect(decoded.requestedIPv6Address == expectedIPv6Address)
    }

    @Test func attachmentOptionsDecodeMissingAliasesAsEmpty() throws {
        let data = #"{"hostname":"api"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AttachmentOptions.self, from: data)

        #expect(decoded.hostname == "api")
        #expect(decoded.aliases == [])
        #expect(decoded.guestInterfaceName == nil)
        #expect(decoded.additionalIPAddresses == [])
        #expect(decoded.requestedIPv4Address == nil)
        #expect(decoded.requestedIPv6Address == nil)
    }

    @Test func attachmentRoundTripsAliases() throws {
        let attachment = Attachment(
            network: "default",
            hostname: "api",
            aliases: ["web"],
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )

        let data = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(Attachment.self, from: data)

        #expect(decoded.hostname == "api")
        #expect(decoded.aliases == ["web"])
    }
}

struct NetworkConfigurationTest {
    @Test func networkStatusDecodesLegacyStatusWithoutReservedAddresses() throws {
        let status = NetworkStatus(
            ipv4Subnet: try CIDRv4("192.0.2.0/24"),
            ipv4Gateway: try IPv4Address("192.0.2.1"),
            ipv6Subnet: nil
        )
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        encoded.removeValue(forKey: "ipv4ReservedAddresses")
        let decoded = try JSONDecoder().decode(NetworkStatus.self, from: JSONSerialization.data(withJSONObject: encoded))

        #expect(decoded.ipv4ReservedAddresses == [])
    }

    @Test func networkConfigurationRoundTripsIPv4ReservedAddresses() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let reservedAddresses = [try IPv4Address("192.0.2.10"), try IPv4Address("192.0.2.20")]
        let configuration = try NetworkConfiguration(
            name: "reserved-address-network",
            mode: .nat,
            ipv4Subnet: subnet,
            ipv4ReservedAddresses: reservedAddresses,
            plugin: "container-network-vmnet"
        )

        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: JSONEncoder().encode(configuration))

        #expect(decoded.ipv4Subnet == subnet)
        #expect(decoded.ipv4ReservedAddresses == reservedAddresses)
    }

    @Test func networkConfigurationRejectsInvalidIPv4ReservedAddresses() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let invalidAddressLists = [
            [try IPv4Address("192.0.2.1")],
            [try IPv4Address("192.0.2.10"), try IPv4Address("192.0.2.10")],
            [try IPv4Address("198.51.100.10")],
        ]

        for reservedAddresses in invalidAddressLists {
            #expect {
                _ = try NetworkConfiguration(
                    name: "reserved-address-network",
                    mode: .nat,
                    ipv4Subnet: subnet,
                    ipv4ReservedAddresses: reservedAddresses,
                    plugin: "container-network-vmnet"
                )
            } throws: { error in
                guard let error = error as? ContainerizationError else { return false }
                return error.code == .invalidArgument
            }
        }

        #expect {
            _ = try NetworkConfiguration(
                name: "reserved-address-network",
                mode: .nat,
                ipv4ReservedAddresses: [try IPv4Address("192.0.2.10")],
                plugin: "container-network-vmnet"
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.code == .invalidArgument
        }

        #expect {
            _ = try NetworkConfiguration(
                name: "reserved-address-network",
                mode: .nat,
                ipv4Subnet: try CIDRv4("192.0.2.0/31"),
                ipv4ReservedAddresses: [try IPv4Address("192.0.2.1")],
                plugin: "container-network-vmnet"
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.code == .invalidArgument
        }
    }

    @Test func networkConfigurationRoundTripsIPv4AllocationRange() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let allocationRange = try CIDRv4("192.0.2.128/25")
        let configuration = try NetworkConfiguration(
            name: "allocation-range-network",
            mode: .nat,
            ipv4Subnet: subnet,
            ipv4AllocationRange: allocationRange,
            plugin: "container-network-vmnet"
        )

        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: JSONEncoder().encode(configuration))

        #expect(decoded.ipv4Subnet == subnet)
        #expect(decoded.ipv4AllocationRange == allocationRange)
    }

    @Test func networkConfigurationRejectsInvalidIPv4AllocationRange() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let invalidRanges = [
            try CIDRv4("198.51.100.0/24"),
            try CIDRv4("192.0.2.0/31"),
        ]

        for allocationRange in invalidRanges {
            #expect {
                _ = try NetworkConfiguration(
                    name: "allocation-range-network",
                    mode: .nat,
                    ipv4Subnet: subnet,
                    ipv4AllocationRange: allocationRange,
                    plugin: "container-network-vmnet"
                )
            } throws: { error in
                guard let error = error as? ContainerizationError else { return false }
                return error.code == .invalidArgument
            }
        }

        #expect {
            _ = try NetworkConfiguration(
                name: "allocation-range-network",
                mode: .nat,
                ipv4AllocationRange: try CIDRv4("192.0.2.0/24"),
                plugin: "container-network-vmnet"
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.code == .invalidArgument
        }
    }

    @Test func networkConfigurationRoundTripsCustomIPv4Gateway() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let gateway = try IPv4Address("192.0.2.254")
        let configuration = try NetworkConfiguration(
            name: "gateway-network",
            mode: .nat,
            ipv4Subnet: subnet,
            ipv4Gateway: gateway,
            plugin: "container-network-vmnet"
        )

        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: JSONEncoder().encode(configuration))

        #expect(decoded.ipv4Subnet == subnet)
        #expect(decoded.ipv4Gateway == gateway)
    }

    @Test func networkConfigurationRejectsInvalidIPv4Gateway() throws {
        let subnet = try CIDRv4("192.0.2.0/24")
        let invalidGateways = [
            try IPv4Address("192.0.2.0"),
            try IPv4Address("192.0.2.255"),
            try IPv4Address("198.51.100.1"),
        ]

        for gateway in invalidGateways {
            #expect {
                _ = try NetworkConfiguration(
                    name: "gateway-network",
                    mode: .nat,
                    ipv4Subnet: subnet,
                    ipv4Gateway: gateway,
                    plugin: "container-network-vmnet"
                )
            } throws: { error in
                guard let error = error as? ContainerizationError else { return false }
                return error.code == .invalidArgument
            }
        }

        #expect {
            _ = try NetworkConfiguration(
                name: "gateway-network",
                mode: .nat,
                ipv4Gateway: try IPv4Address("192.0.2.1"),
                plugin: "container-network-vmnet"
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else { return false }
            return error.code == .invalidArgument
        }
    }

    @Test func testValidationOkDefaults() throws {
        let id = "foo"
        _ = try NetworkConfiguration(
            name: id,
            mode: .nat,
            plugin: "container-network-vmnet"
        )
    }

    @Test func testValidationGoodId() throws {
        let ids = [
            String(repeating: "0", count: 63),
            "0",
            "0-_.1",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            _ = try NetworkConfiguration(
                name: id,
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                labels: labels,
                plugin: "container-network-vmnet"
            )
        }
    }

    @Test func testValidationBadId() throws {
        let ids = [
            String(repeating: "0", count: 64),
            "-foo",
            "foo_",
            "Foo",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            #expect {
                _ = try NetworkConfiguration(
                    name: id,
                    mode: .nat,
                    ipv4Subnet: ipv4Subnet,
                    labels: labels,
                    plugin: "container-network-vmnet"
                )
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid network name"))
                return true
            }
        }
    }

}
