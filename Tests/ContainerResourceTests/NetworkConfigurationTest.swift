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
            guestInterfaceName: "backend0"
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(AttachmentOptions.self, from: data)

        #expect(decoded.hostname == "api")
        #expect(decoded.aliases == ["web", "api.internal"])
        #expect(decoded.mtu == 1500)
        #expect(decoded.guestInterfaceName == "backend0")
    }

    @Test func attachmentOptionsDecodeMissingAliasesAsEmpty() throws {
        let data = #"{"hostname":"api"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AttachmentOptions.self, from: data)

        #expect(decoded.hostname == "api")
        #expect(decoded.aliases == [])
        #expect(decoded.guestInterfaceName == nil)
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
