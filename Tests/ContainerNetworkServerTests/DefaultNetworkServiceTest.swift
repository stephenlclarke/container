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
import Testing

@testable import ContainerNetworkServer

struct DefaultNetworkServiceTest {
    @Test(
        "Subnets without allocatable addresses are rejected",
        arguments: [
            "0.0.0.0/32",
            "192.0.2.0/31",
            "255.255.255.254/31",
            "192.0.2.0/30",
        ]
    )
    func rejectsSmallSubnet(_ value: String) throws {
        let subnet = try CIDRv4(value)

        #expect(throws: ContainerizationError.self) {
            try DefaultNetworkService.ipv4AllocationBounds(subnet: subnet)
        }
    }

    @Test
    func computesNormalAllocationBounds() throws {
        let bounds = try DefaultNetworkService.ipv4AllocationBounds(
            subnet: CIDRv4("192.0.2.0/29")
        )
        let expectedLower = try IPv4Address("192.0.2.2")
        let expectedUpper = try IPv4Address("192.0.2.5")

        #expect(bounds.lower == expectedLower.value)
        #expect(bounds.upper == expectedUpper.value)
        #expect(bounds.size == 4)
    }

    @Test
    func computesFullAddressSpaceWithoutOverflow() throws {
        let bounds = try DefaultNetworkService.ipv4AllocationBounds(
            subnet: CIDRv4("0.0.0.0/0")
        )

        #expect(bounds.lower == 2)
        #expect(bounds.upper == UInt32.max - 2)
        #expect(bounds.size == Int(UInt32.max) - 3)
    }
}
