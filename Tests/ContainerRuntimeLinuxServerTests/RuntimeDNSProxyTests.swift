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

import Containerization
import ContainerizationExtras
import DNSServer
import Darwin
import Foundation
import NIOPosix
import Testing

@testable import ContainerRuntimeLinuxServer

struct RuntimeDNSProxyTests {
    @Test func resolvesScopedAliasThroughItsTargetLookup() async throws {
        let capture = NetworkLookupCapture(addresses: [
            RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil)
        ])
        let resolver = RuntimeDNSResolver(
            scopedAliases: [
                "database": RuntimeDNSResolver.ScopedAlias(
                    target: "db",
                    lookup: { hostname in
                        await capture.lookup(hostname)
                    }
                )
            ],
            networkLookups: [{ _ in throw TestError.unexpectedLookup }],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let expectedAddress = try IPv4Address("192.168.64.2")
        let response = await resolver.resolve(try query(name: "DaTaBaSe.", type: .host))
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "DaTaBaSe.", type: .host)],
            answers: [
                HostRecord(name: "DaTaBaSe.", ttl: 5, ip: expectedAddress)
            ]
        ).serialize()

        #expect(response == expected)
        #expect(await capture.hostnames == ["db"])
    }

    @Test func missingScopedAliasTargetDoesNotLeakToOtherResolvers() async throws {
        let upstream = UpstreamCapture(response: Data())
        let resolver = RuntimeDNSResolver(
            scopedAliases: [
                "database": RuntimeDNSResolver.ScopedAlias(
                    target: "db",
                    lookup: { _ in [] }
                )
            ],
            networkLookups: [{ _ in throw TestError.unexpectedLookup }],
            upstreamNameservers: [],
            upstream: { query, request, nameservers in
                await upstream.resolve(query, request, nameservers: nameservers)
            }
        )

        let response = try Message(
            deserialize: await resolver.resolve(try query(name: "database.", type: .host))
        )

        #expect(response.returnCode == .nonExistentDomain)
        #expect(response.answers.isEmpty)
        #expect(await upstream.callCount == 0)
    }

    @Test func scopedAliasUsesFirstAttachedNetworkContainingItsTarget() async throws {
        let first = NetworkLookupCapture(addresses: [])
        let second = NetworkLookupCapture(addresses: [
            RuntimeDNSAddress(ipv4: try IPv4Address("192.168.65.2"), ipv6: nil)
        ])
        let third = NetworkLookupCapture(addresses: [
            RuntimeDNSAddress(ipv4: try IPv4Address("192.168.66.2"), ipv6: nil)
        ])
        let resolver = RuntimeDNSResolver(
            scopedAliases: [
                "database": RuntimeDNSResolver.ScopedAlias(
                    target: "db",
                    lookups: [
                        { hostname in await first.lookup(hostname) },
                        { hostname in await second.lookup(hostname) },
                        { hostname in await third.lookup(hostname) },
                    ]
                )
            ],
            networkLookups: [{ _ in throw TestError.unexpectedLookup }],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(try query(name: "database.", type: .host))
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "database.", type: .host)],
            answers: [
                HostRecord(
                    name: "database.",
                    ttl: 5,
                    ip: try IPv4Address("192.168.65.2")
                )
            ]
        ).serialize()

        #expect(response == expected)
        #expect(await first.hostnames == ["db"])
        #expect(await second.hostnames == ["db"])
        #expect(await third.hostnames.isEmpty)
    }

    @Test func resolvesIPv4FromFirstAttachedNetwork() async throws {
        let request = try query(name: "web.", type: .host)
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil)]
                },
                { _ in
                    [RuntimeDNSAddress(ipv4: try IPv4Address("192.168.65.2"), ipv6: nil)]
                },
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(request)
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "web.", type: .host)],
            answers: [
                HostRecord(
                    name: "web.",
                    ttl: 5,
                    ip: try IPv4Address("192.168.64.2")
                )
            ]
        ).serialize()

        #expect(response == expected)
    }

    @Test func resolvesEveryIPv4AddressForASharedAlias() async throws {
        let request = try query(name: "api.", type: .host)
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [
                        RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil),
                        RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.3"), ipv6: nil),
                    ]
                }
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(request)
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "api.", type: .host)],
            answers: [
                HostRecord(name: "api.", ttl: 5, ip: try IPv4Address("192.168.64.2")),
                HostRecord(name: "api.", ttl: 5, ip: try IPv4Address("192.168.64.3")),
            ]
        ).serialize()

        #expect(response == expected)
    }

    @Test func rotatesSharedAliasAnswersByTransactionID() async throws {
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [
                        RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil),
                        RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.3"), ipv6: nil),
                    ]
                }
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(try query(id: 0x1235, name: "api.", type: .host))
        let expected = try Message(
            id: 0x1235,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "api.", type: .host)],
            answers: [
                HostRecord(name: "api.", ttl: 5, ip: try IPv4Address("192.168.64.3")),
                HostRecord(name: "api.", ttl: 5, ip: try IPv4Address("192.168.64.2")),
            ]
        ).serialize()

        #expect(response == expected)
    }

    @Test func returnsNoDataForKnownIPv4OnlyHostname() async throws {
        let request = try query(name: "web.", type: .host6)
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil)]
                }
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.returnCode == .noError)
        #expect(response.answers.isEmpty)
    }

    @Test func resolvesIPv6FromAttachedNetwork() async throws {
        let request = try query(name: "web.", type: .host6)
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [
                        RuntimeDNSAddress(
                            ipv4: try IPv4Address("192.168.64.2"),
                            ipv6: try IPv6Address("fd00::2")
                        )
                    ]
                }
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(request)
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: "web.", type: .host6)],
            answers: [
                HostRecord(
                    name: "web.",
                    ttl: 5,
                    ip: try IPv6Address("fd00::2")
                )
            ]
        ).serialize()

        #expect(response == expected)
    }

    @Test func forwardsUnknownNamesWithExplicitNameservers() async throws {
        let request = try query(name: "example.com.", type: .host)
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .nonExistentDomain,
            questions: [Question(name: "example.com.", type: .host)]
        ).serialize()
        let capture = UpstreamCapture(response: expected)
        let resolver = RuntimeDNSResolver(
            networkLookups: [{ _ in [] }],
            upstreamNameservers: ["1.1.1.1", "2606:4700:4700::1111"],
            upstream: { query, request, nameservers in
                await capture.resolve(query, request, nameservers: nameservers)
            }
        )

        #expect(await resolver.resolve(request) == expected)
        #expect(await capture.nameservers == ["1.1.1.1", "2606:4700:4700::1111"])
    }

    @Test func forwardsRootAddressQueryWithoutNetworkLookup() async throws {
        let request = try query(name: ".", type: .host)
        let expected = try Message(
            id: 0x1234,
            type: .response,
            recursionDesired: true,
            recursionAvailable: true,
            returnCode: .noError,
            questions: [Question(name: ".", type: .host)]
        ).serialize()
        let resolver = RuntimeDNSResolver(
            networkLookups: [{ _ in throw TestError.unexpectedLookup }],
            upstreamNameservers: [],
            upstream: { _, _, _ in expected }
        )

        #expect(await resolver.resolve(request) == expected)
    }

    @Test func rejectsMalformedStandardQueriesWithoutForwarding() async throws {
        let capture = UpstreamCapture(response: Data())
        let resolver = RuntimeDNSResolver(
            networkLookups: [],
            upstreamNameservers: [],
            upstream: { query, request, nameservers in
                await capture.resolve(query, request, nameservers: nameservers)
            }
        )
        let request = try Message(
            id: 0x1234,
            type: .query,
            questions: [
                Question(name: "one.", type: .host),
                Question(name: "two.", type: .host),
            ]
        ).serialize()

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.returnCode == .formatError)
        #expect(await capture.callCount == 0)
    }

    @Test func rejectsMismatchedUpstreamTransaction() async throws {
        let request = try query(name: "example.com.", type: .host)
        let poisonedResponse = try Message(
            id: 0x4321,
            type: .response,
            questions: [Question(name: "example.com.", type: .host)]
        ).serialize()
        let resolver = RuntimeDNSResolver(
            networkLookups: [],
            upstreamNameservers: [],
            upstream: { _, _, _ in poisonedResponse }
        )

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.id == 0x1234)
        #expect(response.returnCode == .serverFailure)
    }

    @Test func rejectsMismatchedUpstreamQuestion() async throws {
        let request = try query(name: "example.com.", type: .host)
        let poisonedResponse = try Message(
            id: 0x1234,
            type: .response,
            questions: [Question(name: "attacker.example.", type: .host)]
        ).serialize()
        let resolver = RuntimeDNSResolver(
            networkLookups: [],
            upstreamNameservers: [],
            upstream: { _, _, _ in poisonedResponse }
        )

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.id == 0x1234)
        #expect(response.returnCode == .serverFailure)
    }

    @Test func rejectsUpstreamQueryAsResponse() async throws {
        let request = try query(name: "example.com.", type: .host)
        let queryResponse = try Message(
            id: 0x1234,
            type: .query,
            questions: [Question(name: "example.com.", type: .host)]
        ).serialize()
        let resolver = RuntimeDNSResolver(
            networkLookups: [],
            upstreamNameservers: [],
            upstream: { _, _, _ in queryResponse }
        )

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.id == 0x1234)
        #expect(response.returnCode == .serverFailure)
    }

    @Test func networkLookupFailureReturnsServerFailure() async throws {
        let request = try query(name: "web.", type: .host)
        let resolver = RuntimeDNSResolver(
            networkLookups: [{ _ in throw TestError.lookupFailed }],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = try Message(deserialize: await resolver.resolve(request))

        #expect(response.returnCode == .serverFailure)
    }

    @Test func malformedQueryAlwaysReturnsWireResponse() async throws {
        let resolver = RuntimeDNSResolver(
            networkLookups: [],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )

        let response = await resolver.resolve(Data([0x12]))

        #expect(response.count == Message.headerSize)
        #expect(response[response.startIndex] == 0)
        #expect(response[response.startIndex + 1] == 0)
        #expect(response[response.startIndex + 2] & 0x80 != 0)
        #expect(response[response.startIndex + 3] & 0x0f == ReturnCode.formatError.rawValue)
    }

    @Test func validatesExplicitNameserversBeforeServingQueries() throws {
        try RuntimeDNSUpstream.validate(nameservers: [
            "1.1.1.1",
            "2606:4700:4700::1111",
            "fe80::1%lo0",
        ])

        #expect(throws: Error.self) {
            try RuntimeDNSUpstream.validate(nameservers: ["not-an-address"])
        }
        #expect(throws: Error.self) {
            try RuntimeDNSUpstream.validate(nameservers: [
                "192.0.2.1",
                "192.0.2.2",
                "192.0.2.3",
                "192.0.2.4",
            ])
        }
    }

    @Test func handlesOneFramedRequestPerConnection() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let server = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let client = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        defer { try? client.close() }

        let request = try query(name: "web.", type: .host)
        let resolver = RuntimeDNSResolver(
            networkLookups: [
                { _ in
                    [RuntimeDNSAddress(ipv4: try IPv4Address("192.168.64.2"), ipv6: nil)]
                }
            ],
            upstreamNameservers: [],
            upstream: unexpectedUpstream
        )
        let serverTask = Task {
            try await RuntimeDNSProxy.handleConnection(
                server,
                resolver: resolver,
                eventLoopGroup: MultiThreadedEventLoopGroup.singleton
            )
        }

        try client.write(contentsOf: DNSProxyProtocol.encode(request))
        let received = try client.read(upToCount: DNSProxyProtocol.maximumMessageLength + 2)
        let data = try #require(received)
        let decoded = try DNSProxyProtocol.decode(data)
        let frame = try #require(decoded)
        try await serverTask.value

        #expect(frame.consumedBytes == data.count)
        let response = try Message(deserialize: frame.message)
        #expect(response.id == 0x1234)
        #expect(response.returnCode == .noError)
    }

    private func query(
        id: UInt16 = 0x1234,
        name: String,
        type: ResourceRecordType
    ) throws -> Data {
        try Message(
            id: id,
            type: .query,
            recursionDesired: true,
            questions: [Question(name: name, type: type)]
        ).serialize()
    }
}

private actor UpstreamCapture {
    private let response: Data
    private(set) var nameservers: [String] = []
    private(set) var callCount = 0

    init(response: Data) {
        self.response = response
    }

    func resolve(_: Message, _: Data, nameservers: [String]) -> Data {
        callCount += 1
        self.nameservers = nameservers
        return response
    }
}

private actor NetworkLookupCapture {
    private let addresses: [RuntimeDNSAddress]
    private(set) var hostnames: [String] = []

    init(addresses: [RuntimeDNSAddress]) {
        self.addresses = addresses
    }

    func lookup(_ hostname: String) -> [RuntimeDNSAddress] {
        hostnames.append(hostname)
        return addresses
    }
}

private func unexpectedUpstream(_: Message, _: Data, _: [String]) async throws -> Data {
    throw TestError.unexpectedUpstream
}

private enum TestError: Error {
    case lookupFailed
    case unexpectedLookup
    case unexpectedUpstream
}
