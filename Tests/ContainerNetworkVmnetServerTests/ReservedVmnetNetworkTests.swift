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
import ContainerizationExtras
import Testing

@testable import ContainerNetworkVmnetServer

struct ReservedVmnetNetworkTests {
    @Test
    func resolvesConfiguredIPv6GatewayForReservation() throws {
        let subnet = try CIDRv6("fd00::/64")
        let configuredGateway = try IPv6Address("fd00::42")

        let gateway = resolvedIPv6Gateway(
            configuredGateway: configuredGateway,
            subnet: subnet
        )

        #expect(gateway == configuredGateway)
    }

    @Test
    func natIPv6NetworkReportsConfiguredOrDefaultGateway() throws {
        let subnet = try CIDRv6("fd00::/64")
        let configuredGateway = try IPv6Address("fd00::42")

        #expect(
            resolvedIPv6Gateway(
                configuredGateway: configuredGateway,
                subnet: subnet
            ) == configuredGateway
        )
        #expect(
            resolvedIPv6Gateway(
                configuredGateway: nil,
                subnet: subnet
            ) == IPv6Address(subnet.lower.value + 1)
        )
    }
}
