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

import CDNSResolver
import Containerization
import ContainerizationError
import ContainerizationExtras
import DNSServer
import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix

struct RuntimeDNSAddress: Sendable, Equatable {
    let ipv4: IPv4Address
    let ipv6: IPv6Address?
}

struct RuntimeDNSResolver: Sendable {
    typealias NetworkLookup = @Sendable (String) async throws -> [RuntimeDNSAddress]
    typealias Upstream = @Sendable (Message, Data, [String]) async throws -> Data

    struct ScopedAlias: Sendable {
        let target: String
        let lookup: NetworkLookup
    }

    private let scopedAliases: [String: ScopedAlias]
    private let networkLookups: [NetworkLookup]
    private let upstreamNameservers: [String]
    private let upstream: Upstream
    private let log: Logger?

    init(
        scopedAliases: [String: ScopedAlias] = [:],
        networkLookups: [NetworkLookup],
        upstreamNameservers: [String],
        log: Logger? = nil,
        upstream: @escaping Upstream = RuntimeDNSUpstream.resolve
    ) {
        self.scopedAliases = scopedAliases
        self.networkLookups = networkLookups
        self.upstreamNameservers = upstreamNameservers
        self.upstream = upstream
        self.log = log
    }

    func resolve(_ request: Data) async -> Data {
        let query: Message
        do {
            query = try Message(deserialize: request)
        } catch let error as DNSBindError {
            let returnCode: ReturnCode =
                if case .unsupportedValue = error {
                    .notImplemented
                } else {
                    .formatError
                }
            log?.debug("rejecting malformed DNS query", metadata: ["error": "\(error)"])
            return Self.errorResponse(request: request, returnCode: returnCode)
        } catch {
            log?.debug("rejecting malformed DNS query", metadata: ["error": "\(error)"])
            return Self.errorResponse(request: request, returnCode: .formatError)
        }

        do {
            let handler = StandardQueryValidator(
                handler: RuntimeNetworkDNSHandler(
                    scopedAliases: scopedAliases,
                    lookups: networkLookups
                ))
            if let response = try await handler.answer(query: query) {
                return try response.serialize()
            }

            let response = try await upstream(query, request, upstreamNameservers)
            return try Self.validate(response: response, query: query)
        } catch {
            log?.debug("DNS query failed", metadata: ["error": "\(error)"])
            return Self.errorResponse(query: query, returnCode: .serverFailure)
        }
    }

    static func canonicalHostname(_ hostname: String) -> String {
        let canonical = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        return canonical.lowercased()
    }

    private static func validate(response: Data, query: Message) throws -> Data {
        guard response.count >= Message.headerSize,
            response.count <= DNSProxyProtocol.maximumMessageLength
        else {
            throw RuntimeDNSError.invalidResponseLength(response.count)
        }
        let parsed = try Message(deserialize: response)
        guard parsed.id == query.id else {
            throw RuntimeDNSError.transactionMismatch(expected: query.id, actual: parsed.id)
        }
        guard parsed.type == .response else {
            throw RuntimeDNSError.upstreamReturnedQuery
        }
        guard parsed.operationCode == query.operationCode,
            parsed.questions.count == query.questions.count,
            zip(parsed.questions, query.questions).allSatisfy({
                $0.name.caseInsensitiveCompare($1.name) == .orderedSame
                    && $0.type == $1.type
                    && $0.recordClass == $1.recordClass
            })
        else {
            throw RuntimeDNSError.questionMismatch
        }
        return response
    }

    private static func errorResponse(request: Data, returnCode: ReturnCode) -> Data {
        let id: UInt16 =
            if request.count >= 2 {
                UInt16(request[request.startIndex]) << 8 | UInt16(request[request.startIndex + 1])
            } else {
                0
            }
        return errorResponse(
            query: Message(id: id, type: .query),
            returnCode: returnCode
        )
    }

    private static func errorResponse(query: Message, returnCode: ReturnCode) -> Data {
        let response = Message(
            id: query.id,
            type: .response,
            recursionDesired: query.recursionDesired,
            recursionAvailable: true,
            returnCode: returnCode,
            questions: query.questions
        )
        if let data = try? response.serialize() {
            return data
        }

        var id = query.id.bigEndian
        let flags = UInt16(0x8000 | UInt16(returnCode.rawValue)).bigEndian
        var fallback = withUnsafeBytes(of: &id) { Data($0) }
        withUnsafeBytes(of: flags) { fallback.append(contentsOf: $0) }
        fallback.append(contentsOf: repeatElement(0, count: Message.headerSize - fallback.count))
        return fallback
    }
}

private struct RuntimeNetworkDNSHandler: DNSHandler {
    let scopedAliases: [String: RuntimeDNSResolver.ScopedAlias]
    let lookups: [RuntimeDNSResolver.NetworkLookup]

    func answer(query: Message) async throws -> Message? {
        guard let question = query.questions.first,
            question.recordClass == .internet,
            question.type == .host || question.type == .host6,
            !question.name.isEmpty,
            question.name != "."
        else {
            return nil
        }

        if let scopedAlias = scopedAliases[RuntimeDNSResolver.canonicalHostname(question.name)] {
            let addresses = try await scopedAlias.lookup(scopedAlias.target)
            return answer(
                query: query,
                question: question,
                addresses: addresses,
                emptyReturnCode: .nonExistentDomain
            )
        }

        for lookup in lookups {
            let addresses = try await lookup(question.name)
            if let response = answer(query: query, question: question, addresses: addresses) {
                return response
            }
        }
        return nil
    }

    private func answer(
        query: Message,
        question: Question,
        addresses: [RuntimeDNSAddress],
        emptyReturnCode: ReturnCode? = nil
    ) -> Message? {
        guard !addresses.isEmpty else {
            return emptyReturnCode.map {
                Message(
                    id: query.id,
                    type: .response,
                    recursionDesired: query.recursionDesired,
                    recursionAvailable: true,
                    returnCode: $0,
                    questions: query.questions
                )
            }
        }
        let offset = Int(query.id) % addresses.count
        let orderedAddresses = Array(addresses[offset...] + addresses[..<offset])

        let answers: [any ResourceRecord]
        switch question.type {
        case .host:
            answers = orderedAddresses.map {
                HostRecord(name: question.name, ttl: 5, ip: $0.ipv4)
            }
        case .host6:
            answers = orderedAddresses.compactMap {
                guard let ipv6 = $0.ipv6 else {
                    return nil
                }
                return HostRecord(name: question.name, ttl: 5, ip: ipv6)
            }
        default:
            return nil
        }

        return Message(
            id: query.id,
            type: .response,
            recursionDesired: query.recursionDesired,
            recursionAvailable: true,
            returnCode: .noError,
            questions: query.questions,
            answers: answers
        )
    }
}

enum RuntimeDNSUpstream {
    private static let queue = DispatchQueue(
        label: "com.apple.container.runtime.dns",
        qos: .utility,
        attributes: .concurrent
    )
    private static let maximumAddresses = 16
    private static let externalTTL: UInt32 = 30

    static func validate(nameservers: [String]) throws {
        guard !nameservers.isEmpty else {
            return
        }
        let nameserverList = nameservers.joined(separator: ",")
        let status = nameserverList.withCString(cdns_validate_nameservers)
        guard status == CDNS_STATUS_OK else {
            throw ContainerizationError(
                .invalidArgument,
                message: "DNS nameservers must be a list of at most three IPv4 or IPv6 addresses"
            )
        }
    }

    static func resolve(
        query: Message,
        request: Data,
        nameservers: [String]
    ) async throws -> Data {
        guard nameservers.isEmpty,
            let question = query.questions.first,
            question.recordClass == .internet
        else {
            return try await sendRaw(request: request, nameservers: nameservers)
        }

        switch question.type {
        case .host:
            return try await resolveIPv4(query: query, question: question)
        case .host6:
            return try await resolveIPv6(query: query, question: question)
        default:
            return try await sendRaw(request: request, nameservers: nameservers)
        }
    }

    private static func resolveIPv4(query: Message, question: Question) async throws -> Data {
        let addresses = try await resolveAddresses(hostname: question.name, family: AF_INET)
        if !addresses.isEmpty {
            let answers: [any ResourceRecord] = try addresses.map {
                HostRecord(name: question.name, ttl: externalTTL, ip: try IPv4Address(Array($0.prefix(4))))
            }
            return try nativeResponse(query: query, answers: answers, returnCode: .noError)
        }

        let ipv6 = try await resolveAddresses(hostname: question.name, family: AF_INET6)
        return try nativeResponse(
            query: query,
            answers: [],
            returnCode: ipv6.isEmpty ? .nonExistentDomain : .noError
        )
    }

    private static func resolveIPv6(query: Message, question: Question) async throws -> Data {
        let addresses = try await resolveAddresses(hostname: question.name, family: AF_INET6)
        if !addresses.isEmpty {
            let answers: [any ResourceRecord] = try addresses.map {
                HostRecord(name: question.name, ttl: externalTTL, ip: try IPv6Address($0))
            }
            return try nativeResponse(query: query, answers: answers, returnCode: .noError)
        }

        let ipv4 = try await resolveAddresses(hostname: question.name, family: AF_INET)
        return try nativeResponse(
            query: query,
            answers: [],
            returnCode: ipv4.isEmpty ? .nonExistentDomain : .noError
        )
    }

    private static func nativeResponse(
        query: Message,
        answers: [any ResourceRecord],
        returnCode: ReturnCode
    ) throws -> Data {
        try Message(
            id: query.id,
            type: .response,
            recursionDesired: query.recursionDesired,
            recursionAvailable: true,
            returnCode: returnCode,
            questions: query.questions,
            answers: answers
        ).serialize()
    }

    private static func resolveAddresses(hostname: String, family: Int32) async throws -> [[UInt8]] {
        try await offload {
            var storage = [UInt8](
                repeating: 0,
                count: maximumAddresses * Int(CDNS_ADDRESS_STRIDE)
            )
            var count = 0
            var resolverError: Int32 = 0
            let status = hostname.withCString { hostnamePointer in
                storage.withUnsafeMutableBytes { buffer in
                    cdns_resolve_addresses(
                        hostnamePointer,
                        family,
                        buffer.bindMemory(to: UInt8.self).baseAddress,
                        buffer.count,
                        &count,
                        &resolverError
                    )
                }
            }

            if status == CDNS_STATUS_NOT_FOUND {
                return []
            }
            guard status == CDNS_STATUS_OK else {
                throw RuntimeDNSError.systemResolver(status: status, detail: resolverError)
            }

            return (0..<count).map { index in
                let start = index * Int(CDNS_ADDRESS_STRIDE)
                return Array(storage[start..<start + Int(CDNS_ADDRESS_STRIDE)])
            }
        }
    }

    private static func sendRaw(request: Data, nameservers: [String]) async throws -> Data {
        try await offload {
            var response = [UInt8](
                repeating: 0,
                count: DNSProxyProtocol.maximumMessageLength
            )
            var responseLength = 0
            var resolverError: Int32 = 0
            let nameserverList = nameservers.isEmpty ? nil : nameservers.joined(separator: ",")

            let status = request.withUnsafeBytes { requestBuffer in
                response.withUnsafeMutableBytes { responseBuffer in
                    let send: (UnsafePointer<CChar>?) -> Int32 = { nameserverPointer in
                        cdns_send_query(
                            requestBuffer.bindMemory(to: UInt8.self).baseAddress,
                            requestBuffer.count,
                            nameserverPointer,
                            responseBuffer.bindMemory(to: UInt8.self).baseAddress,
                            responseBuffer.count,
                            &responseLength,
                            &resolverError
                        )
                    }
                    if let nameserverList {
                        return nameserverList.withCString(send)
                    }
                    return send(nil)
                }
            }

            guard status == CDNS_STATUS_OK else {
                throw RuntimeDNSError.systemResolver(status: status, detail: resolverError)
            }
            return Data(response.prefix(responseLength))
        }
    }

    private static func offload<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}

final class RuntimeDNSProxy: Sendable {
    private static let maximumConcurrentConnections = 64
    private static let connectionTimeout = Duration.seconds(3)

    private let listener: VsockListener
    private let resolver: RuntimeDNSResolver
    private let eventLoopGroup: any EventLoopGroup
    private let log: Logger

    init(
        listener: VsockListener,
        resolver: RuntimeDNSResolver,
        eventLoopGroup: any EventLoopGroup,
        log: Logger
    ) {
        self.listener = listener
        self.resolver = resolver
        self.eventLoopGroup = eventLoopGroup
        self.log = log
    }

    func run() async {
        await withTaskGroup(of: Void.self) { connections in
            var activeConnections = 0
            for await connection in listener {
                if activeConnections == Self.maximumConcurrentConnections {
                    _ = await connections.next()
                    activeConnections -= 1
                }

                connections.addTask {
                    do {
                        try await Self.handleConnection(
                            connection,
                            resolver: self.resolver,
                            eventLoopGroup: self.eventLoopGroup
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        self.log.debug(
                            "host DNS proxy connection failed",
                            metadata: ["error": "\(error)"]
                        )
                    }
                }
                activeConnections += 1
            }
            connections.cancelAll()
            await connections.waitForAll()
        }
    }

    func stop() {
        try? listener.finish()
    }

    static func handleConnection(
        _ connection: FileHandle,
        resolver: RuntimeDNSResolver,
        eventLoopGroup: any EventLoopGroup
    ) async throws {
        try await Timeout.run(for: connectionTimeout) {
            let descriptor = dup(connection.fileDescriptor)
            guard descriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try? connection.close()
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .withConnectedSocket(descriptor) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: channel
                        )
                    }
                }

            try await channel.executeThenClose { inbound, outbound in
                var request = Data()
                for try await var chunk in inbound {
                    if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                        request.append(contentsOf: bytes)
                    }
                    guard request.count <= DNSProxyProtocol.maximumMessageLength + MemoryLayout<UInt16>.size else {
                        throw RuntimeDNSError.requestTooLarge
                    }
                    guard let frame = try DNSProxyProtocol.decode(request) else {
                        continue
                    }
                    guard frame.consumedBytes == request.count else {
                        throw RuntimeDNSError.trailingRequestData
                    }

                    let response = await resolver.resolve(frame.message)
                    let framedResponse = try DNSProxyProtocol.encode(response)
                    try await outbound.write(ByteBuffer(bytes: framedResponse))
                    return
                }
                throw RuntimeDNSError.unexpectedEndOfStream
            }
        }
    }
}

private enum RuntimeDNSError: Error {
    case invalidResponseLength(Int)
    case questionMismatch
    case requestTooLarge
    case systemResolver(status: Int32, detail: Int32)
    case trailingRequestData
    case transactionMismatch(expected: UInt16, actual: UInt16)
    case unexpectedEndOfStream
    case upstreamReturnedQuery
}
