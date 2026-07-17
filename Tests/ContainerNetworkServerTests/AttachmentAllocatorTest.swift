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

import Testing

@testable import ContainerNetworkServer

struct AttachmentAllocatorTest {
    @Test func testReservedAddressIsSkippedByDynamicAllocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 4)
        try await allocator.reserve(index: 102)

        let addresses = try await [
            allocator.allocate(hostname: "one"),
            allocator.allocate(hostname: "two"),
            allocator.allocate(hostname: "three"),
        ]

        #expect(addresses == [100, 101, 103])
    }

    @Test func testAllocateSingleHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        #expect(address >= 100)
        #expect(address < 110)
    }

    @Test func testAllocateSameHostnameTwice() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let address2 = try await allocator.allocate(hostname: "test-host")

        #expect(address1 == address2)
    }

    @Test func testAllocateRequestedAddressReservesItFromDynamicAllocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let requested = try await allocator.allocate(hostname: "api", requestedIndex: 105)
        let dynamic = try await allocator.allocate(hostname: "worker")

        #expect(requested == 105)
        #expect(dynamic != requested)
    }

    @Test func testDynamicAllocationUsesConfiguredSubrangeWhileRequestedAddressesUseFullRange() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10, dynamicLower: 104, dynamicSize: 3)
        try await allocator.reserve(index: 105)

        let dynamic = try await allocator.allocate(hostname: "dynamic")
        let requested = try await allocator.allocate(hostname: "static", requestedIndex: 101)

        #expect((104...106).contains(dynamic))
        #expect(dynamic != 105)
        #expect(requested == 101)
    }

    @Test func testExistingHostnameRejectsDifferentRequestedAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        _ = try await allocator.allocate(hostname: "api", requestedIndex: 105)

        await #expect(throws: Error.self) {
            _ = try await allocator.allocate(hostname: "api", requestedIndex: 106)
        }
    }

    @Test func testAllocateMultipleHostnames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        #expect(address1 != address2)
        #expect(address2 != address3)
        #expect(address1 != address3)
    }

    @Test func testLookupAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")

        #expect(lookedUpAddress == allocatedAddress)
    }

    @Test func testLookupAllocatedAlias() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "api", aliases: ["web", "api.internal"])

        #expect(try await allocator.lookup(hostname: "api") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "web") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "api.internal") == allocatedAddress)
    }

    @Test func testAliasConflictThrows() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        _ = try await allocator.allocate(hostname: "api", aliases: ["web"])

        await #expect(throws: Error.self) {
            _ = try await allocator.allocate(hostname: "worker", aliases: ["web"])
        }
    }

    @Test func testHostnameCannotReuseExistingAlias() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        _ = try await allocator.allocate(hostname: "api", aliases: ["web"])

        await #expect(throws: Error.self) {
            _ = try await allocator.allocate(hostname: "web")
        }
    }

    @Test func testDuplicateAliasMapsToSingleAllocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "api", aliases: ["web", "web"])

        #expect(try await allocator.lookup(hostname: "api") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "web") == allocatedAddress)
    }

    @Test func testLookupNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.lookup(hostname: "non-existent")

        #expect(address == nil)
    }

    @Test func testDeallocateAllocatedHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let deallocatedAddress = try await allocator.deallocate(hostname: "test-host")

        #expect(deallocatedAddress == allocatedAddress)

        // After deallocation, lookup should return nil
        let lookedUpAddress = try await allocator.lookup(hostname: "test-host")
        #expect(lookedUpAddress == nil)
    }

    @Test func testDeallocateRemovesAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "api", aliases: ["web"])
        let deallocatedAddress = try await allocator.deallocate(hostname: "api")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "api") == nil)
        #expect(try await allocator.lookup(hostname: "web") == nil)
    }

    @Test func testDeallocateNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let deallocatedAddress = try await allocator.deallocate(hostname: "non-existent")

        #expect(deallocatedAddress == nil)
    }

    @Test func testReallocateAfterDeallocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "test-host")
        let released1 = try await allocator.deallocate(hostname: "test-host")
        #expect(address1 == released1)
        let address2 = try await allocator.allocate(hostname: "test-host")

        // After deallocation, allocating the same hostname should give a new address
        #expect(address2 >= 100)
        #expect(address2 < 110)
    }

    @Test func testAllocateUntilFull() async throws {
        let size = 5
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Allocate up to the limit
        for i in 0..<size {
            _ = try await allocator.allocate(hostname: "host\(i)")
        }

        // Attempting to allocate one more should throw
        await #expect(throws: Error.self) {
            try await allocator.allocate(hostname: "extra-host")
        }
    }

    @Test func testDeallocateAndReallocateDifferentHostname() async throws {
        let size = 3
        let allocator = try AttachmentAllocator(lower: 100, size: size)

        // Fill up the allocator
        let address1 = try await allocator.allocate(hostname: "host1")
        let address2 = try await allocator.allocate(hostname: "host2")
        let address3 = try await allocator.allocate(hostname: "host3")

        // Deallocate one
        let released2 = try await allocator.deallocate(hostname: "host2")
        #expect(address2 == released2)

        // Should be able to allocate a new hostname now
        let newAddress = try await allocator.allocate(hostname: "host4")
        #expect(newAddress >= 100)
        #expect(newAddress < 103)

        // The three remaining allocations should all be different
        let finalAddress1 = try await allocator.lookup(hostname: "host1")
        let finalAddress3 = try await allocator.lookup(hostname: "host3")
        let finalAddress4 = try await allocator.lookup(hostname: "host4")

        #expect(finalAddress1 == address1)
        #expect(finalAddress3 == address3)
        #expect(finalAddress4 == newAddress)
    }

    @Test func testMultipleDeallocationsOfSameHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address = try await allocator.allocate(hostname: "test-host")

        let firstDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(firstDeallocate == address)

        // Second deallocation should return nil since it's already deallocated
        let secondDeallocate = try await allocator.deallocate(hostname: "test-host")
        #expect(secondDeallocate == nil)
    }
}
