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

import DNSServer
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

    @Test func testReservedAddressIsUnavailableForExplicitAllocation() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 4)
        try await allocator.reserve(index: 102)

        await #expect(throws: Error.self) {
            _ = try await allocator.allocate(hostname: "api", requestedIndex: 102)
        }
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

    @Test func testDeallocateDynamicAllocationReleasesItsSubrangeOnce() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10, dynamicLower: 104, dynamicSize: 3)
        let dynamic = try await allocator.allocate(hostname: "dynamic")

        #expect(try await allocator.deallocate(hostname: "dynamic") == dynamic)
        #expect(try await allocator.lookup(hostname: "dynamic") == nil)
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

    @Test func testHostnameLookupNormalizesCaseAndTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Test-Host.")

        #expect(try await allocator.lookup(hostname: "test-host") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "TEST-HOST.") == allocatedAddress)
        #expect(try await allocator.allocate(hostname: "test-host") == allocatedAddress)
    }

    @Test func testLookupAllocatedAlias() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "api", aliases: ["Web.", "api.internal"])

        #expect(try await allocator.lookup(hostname: "api") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "web") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "WEB.") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "api.internal") == allocatedAddress)
    }

    @Test func testSharedAliasReturnsEveryAllocationInAddressOrder() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let first = try await allocator.allocate(hostname: "api-1", aliases: ["api"])
        let second = try await allocator.allocate(hostname: "api-2", aliases: ["api"])

        #expect(try await allocator.lookupAll(hostname: "api") == [first, second].sorted())
        #expect(try await allocator.lookup(hostname: "api") == min(first, second))
    }

    @Test func testPrimaryHostnameCanShareAnExistingAlias() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let first = try await allocator.allocate(hostname: "api", aliases: ["web"])
        let second = try await allocator.allocate(hostname: "web")

        #expect(try await allocator.lookupAll(hostname: "web") == [first, second].sorted())
        #expect(try await allocator.lookupPrimary(hostname: "web") == second)
        #expect(try await allocator.lookupPrimary(hostname: "api") == first)
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

    @Test func testDeallocateNormalizesEquivalentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "test-host")
        let deallocatedAddress = try await allocator.deallocate(hostname: "TEST-HOST.")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "test-host") == nil)
    }

    @Test func testDeallocateRemovesAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "api", aliases: ["web"])
        let deallocatedAddress = try await allocator.deallocate(hostname: "api")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "api") == nil)
        #expect(try await allocator.lookup(hostname: "web") == nil)
    }

    @Test func testDeallocatingOneSharedAliasOwnerKeepsTheOther() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let first = try await allocator.allocate(hostname: "api-1", aliases: ["api"])
        let second = try await allocator.allocate(hostname: "api-2", aliases: ["api"])

        #expect(try await allocator.deallocate(hostname: "api-1") == first)
        #expect(try await allocator.lookupAll(hostname: "api") == [second])
        #expect(try await allocator.lookup(hostname: "api-1") == nil)
        #expect(try await allocator.lookup(hostname: "api-2") == second)
    }

    @Test func testDeallocateNonExistentHostname() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let deallocatedAddress = try await allocator.deallocate(hostname: "non-existent")

        #expect(deallocatedAddress == nil)
    }

    @Test(arguments: ["", ".", ".host", "host..", "host..internal"])
    func testRejectsInvalidCanonicalHostnames(hostname: String) async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        await #expect(throws: Error.self) {
            _ = try await allocator.allocate(hostname: hostname)
        }
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

    @Test func testLookupIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "FOO.TEST.") == allocatedAddress)
    }

    @Test func testLookupIgnoresTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "foo.test")

        #expect(try await allocator.lookup(hostname: "foo.test.") == allocatedAddress)
    }

    @Test func testAllocateSameHostnameDifferentCaseReusesAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let address1 = try await allocator.allocate(hostname: "foo.test.")
        let address2 = try await allocator.allocate(hostname: "FOO.test.")

        #expect(address1 == address2)
    }

    @Test func testDeallocateIgnoresCase() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let allocatedAddress = try await allocator.allocate(hostname: "Foo.Test.")
        let deallocatedAddress = try await allocator.deallocate(hostname: "foo.test.")

        #expect(deallocatedAddress == allocatedAddress)
        #expect(try await allocator.lookup(hostname: "foo.test.") == nil)
    }

    // MARK: - Aliases

    private func rules(_ strings: String...) throws -> [String] {
        try strings.map { try DNSMatchRule($0).description }
    }

    @Test func testMatchResolvesHostnameAndAliasesToTheSameAddress() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))

        #expect(try await allocator.match(name: "gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .hostname))
        #expect(try await allocator.match(name: "api.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .alias))
        #expect(try await allocator.match(name: "web.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
        #expect(try await allocator.match(name: "a.b.gw.test.") == AttachmentAllocator.Match(index: index, hostname: "gw.test", kind: .subtree(baseLabelCount: 2)))
    }

    @Test func testMatchIgnoresCaseAndTrailingDot() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("API.test", ".GW.test"))

        #expect(try await allocator.match(name: "Api.Test")?.index == index)
        #expect(try await allocator.match(name: "WEB.gw.test.")?.index == index)
    }

    @Test func testSubtreeDoesNotMatchItsBaseOrUnrelatedNames() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        try await allocator.allocate(hostname: "host.test.", aliases: rules(".example.test"))

        #expect(try await allocator.match(name: "example.test.") == nil)
        #expect(try await allocator.match(name: "evilexample.test.") == nil)
        #expect(try await allocator.match(name: "web.example.com.") == nil)
        #expect(try await allocator.match(name: "test.") == nil)
        #expect(try await allocator.match(name: "") == nil)
    }

    @Test func testHostnameBeatsAliasAndAliasBeatsSubtree() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let gateway = try await allocator.allocate(hostname: "gw.test.", aliases: rules(".gw.test"))
        let other = try await allocator.allocate(hostname: "other.test.", aliases: rules("web.gw.test"))
        let api = try await allocator.allocate(hostname: "api.gw.test.")

        #expect(try await allocator.match(name: "api.gw.test.")?.index == api)
        #expect(try await allocator.match(name: "api.gw.test.")?.kind == .hostname)
        #expect(try await allocator.match(name: "web.gw.test.")?.index == other)
        #expect(try await allocator.match(name: "web.gw.test.")?.kind == .alias)
        #expect(try await allocator.match(name: "x.gw.test.")?.index == gateway)
        #expect(try await allocator.match(name: "x.gw.test.")?.kind == .subtree(baseLabelCount: 2))
    }

    @Test func testLongestSubtreeWins() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let outer = try await allocator.allocate(hostname: "example.test.", aliases: rules(".example.test"))
        let inner = try await allocator.allocate(hostname: "sub.example.test.", aliases: rules(".sub.example.test"))

        #expect(try await allocator.match(name: "a.sub.example.test.") == AttachmentAllocator.Match(index: inner, hostname: "sub.example.test", kind: .subtree(baseLabelCount: 3)))
        #expect(try await allocator.match(name: "a.b.sub.example.test.")?.index == inner)
        #expect(try await allocator.match(name: "a.example.test.") == AttachmentAllocator.Match(index: outer, hostname: "example.test", kind: .subtree(baseLabelCount: 2)))
        // The inner base is a hostname, so it resolves as one and not as part of the outer subtree.
        #expect(try await allocator.match(name: "sub.example.test.")?.kind == .hostname)
    }

    @Test func testPrimaryLookupDoesNotConsiderAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        #expect(try await allocator.lookupPrimary(hostname: "api.test.") == nil)
        #expect(try await allocator.lookupPrimary(hostname: "web.gw.test.") == nil)
    }

    @Test func testSharedAliasesRetainEveryOwner() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let first = try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test", ".api.test"))
        let second = try await allocator.allocate(hostname: "two.test.", aliases: rules("fresh.test", "api.test", ".api.test"))
        #expect(try await allocator.lookupAll(hostname: "api.test.") == [first, second].sorted())
        #expect(try await allocator.lookupAll(hostname: "web.api.test.") == [first, second].sorted())
        #expect(try await allocator.match(name: "fresh.test.")?.hostname == "two.test")
        #expect(try await allocator.match(name: "api.test.")?.index == min(first, second))
        try await allocator.deallocate(hostname: "one.test.")
        #expect(try await allocator.lookupAll(hostname: "web.api.test.") == [second])
    }

    @Test func testPrimaryHostnameWinsSingleMatchWithoutRemovingSharedAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        let alias = try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test"))
        let primary = try await allocator.allocate(hostname: "api.test.")
        #expect(try await allocator.lookupAll(hostname: "api.test.") == [alias, primary].sorted())
        #expect(try await allocator.match(name: "api.test.") == AttachmentAllocator.Match(index: primary, hostname: "api.test", kind: .hostname))
    }

    @Test func testAllocatingAgainWithTheSameAliasesIsIdempotent() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index1 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        let index2 = try await allocator.allocate(hostname: "gw.test.", aliases: rules("api.test", ".gw.test"))
        #expect(index1 == index2)

        try await allocator.deallocate(hostname: "gw.test.")
        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.gw.test.") == nil)
    }

    @Test func testAllocatingAgainAddsNewAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)

        let index = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test"))
        _ = try await allocator.allocate(hostname: "gw.test.", aliases: rules("one.test", "two.test"))

        #expect(try await allocator.match(name: "one.test.")?.index == index)
        #expect(try await allocator.match(name: "two.test.")?.index == index)
    }

    @Test func testDeallocateRemovesAliasesAndFreesThemForReuse() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 10)
        try await allocator.allocate(hostname: "one.test.", aliases: rules("api.test", ".one.test"))

        try await allocator.deallocate(hostname: "one.test.")

        #expect(try await allocator.match(name: "api.test.") == nil)
        #expect(try await allocator.match(name: "web.one.test.") == nil)

        let index = try await allocator.allocate(hostname: "two.test.", aliases: rules("api.test", ".one.test"))
        #expect(try await allocator.match(name: "api.test.")?.index == index)
        #expect(try await allocator.match(name: "web.one.test.")?.index == index)
    }

    @Test func testFailedAllocationDoesNotRegisterAliases() async throws {
        let allocator = try AttachmentAllocator(lower: 100, size: 1)
        let first = try await allocator.allocate(hostname: "one.test.", aliases: rules("one-alias.test"))

        await #expect(throws: (any Error).self) {
            try await allocator.allocate(hostname: "two.test.", aliases: rules("two-alias.test"))
        }

        #expect(try await allocator.match(name: "two-alias.test.") == nil)
        #expect(try await allocator.match(name: "one-alias.test.")?.index == first)
    }
}
