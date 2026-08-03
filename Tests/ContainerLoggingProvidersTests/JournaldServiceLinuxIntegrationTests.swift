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
import Darwin
import Foundation
import Testing

@testable import ContainerLoggingProviders

@Suite("Packaged journald-service cross-language integration")
struct JournaldServiceLinuxIntegrationTests {
    @Test("Swift client writes and reads through the real Linux service")
    func realServiceRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let connector: JournaldServiceFileHandleTransportV1.Connector
        if let socketPath = environment["CONTAINER_JOURNALD_SERVICE_SOCKET"] {
            connector = { try connectJournaldServiceUnixSocket(at: socketPath) }
        } else if let portValue = environment["CONTAINER_JOURNALD_SERVICE_TCP_PORT"],
            let port = UInt16(portValue)
        {
            connector = { try connectJournaldServiceLoopbackTCP(port: port) }
        } else {
            return
        }
        let transport = JournaldServiceFileHandleTransportV1(connector: connector)
        let client = JournaldServiceWireClientV1(transport: transport)
        #expect(try await client.activeSandboxGeneration() == 13)

        let identity = UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "")
        let containerID = identity + identity
        let sessionID = "writer-\(identity)"
        let epoch = "epoch-\(identity)"
        let providerID = JournaldLogDriverContract.providerIdentity.id
        let start = try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "writer-operation-\(identity)",
            semanticRequestDigest: "sha256:writer-\(identity)",
            sessionID: sessionID,
            containerID: containerID,
            leaseGeneration: 2,
            candidateProcessGeneration: 4,
            providerID: providerID,
            providerGeneration: 1,
            candidateSandboxGeneration: 13
        )
        let configuration = try JournaldDriverConfiguration(
            containerID: containerID,
            fields: [
                JournaldField.containerID: String(containerID.prefix(12)),
                JournaldField.containerIDFull: containerID,
                JournaldField.containerTag: "integration-service",
                JournaldField.syslogIdentifier: "integration-service",
            ]
        )
        try await client.openWriter(
            JournaldWriterOpenRequest(
                request: start,
                configuration: configuration,
                epoch: epoch
            )
        )
        try await client.write(
            sessionID: sessionID,
            entry: integrationEntry(
                containerID: containerID,
                epoch: epoch,
                ordinal: 1,
                message: "swift-stdout",
                priority: .informational
            )
        )
        try await client.write(
            sessionID: sessionID,
            entry: integrationEntry(
                containerID: containerID,
                epoch: epoch,
                ordinal: 2,
                message: "swift-stderr",
                priority: .error
            )
        )
        try await client.flushWriter(
            sessionID: sessionID,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )
        try await client.closeWriter(
            sessionID: sessionID,
            fenced: true,
            deadline: ContinuousClock.now.advanced(by: .seconds(2))
        )

        let reader = try await client.openReader(
            LogDriverReaderOpenRequestV1(
                operationGeneration: 1,
                idempotencyKey: "reader-operation-\(identity)",
                semanticRequestDigest: "sha256:reader-\(identity)",
                readerSessionID: "reader-\(identity)",
                containerID: containerID,
                leaseGeneration: 2,
                providerID: providerID,
                providerGeneration: 1,
                source: .stoppedContainer,
                read: ContainerLogReadRequest(
                    stdout: true,
                    stderr: true,
                    details: true
                )
            )
        )
        let first = try await reader.next()
        let second = try await reader.next()
        #expect(try await reader.next() == .endOfStream)

        guard
            case .record(let stdout) = first,
            case .record(let stderr) = second
        else {
            Issue.record("expected two ordered records")
            return
        }
        #expect(stdout.stream == .stdout)
        #expect(stdout.data == Data("swift-stdout\n".utf8))
        #expect(stdout.sequence == 1)
        #expect(stdout.processGeneration == 4)
        #expect(stdout.attributes == ["INTEGRATION_ATTRIBUTE": "preserved"])
        #expect(stderr.stream == .stderr)
        #expect(stderr.data == Data("swift-stderr\n".utf8))
        #expect(stderr.sequence == 2)
        #expect(stderr.processGeneration == 4)
        #expect(stderr.attributes == ["INTEGRATION_ATTRIBUTE": "preserved"])
    }

    private func integrationEntry(
        containerID: String,
        epoch: String,
        ordinal: UInt64,
        message: String,
        priority: JournaldPriority
    ) throws -> JournaldEntry {
        try JournaldEntry(
            message: Data(message.utf8),
            priority: priority,
            fields: [
                JournaldField.containerIDFull: containerID,
                JournaldField.logEpoch: epoch,
                JournaldField.logOrdinal: String(ordinal),
                "INTEGRATION_ATTRIBUTE": "preserved",
            ],
            receivedTimestamp: ContainerLogTimestamp(
                secondsSinceUnixEpoch: Int64(Date().timeIntervalSince1970),
                nanoseconds: 0
            ),
            processGeneration: 4
        )
    }
}

private func connectJournaldServiceUnixSocket(at path: String) throws -> FileHandle {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
        destination[pathBytes.count] = 0
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        Darwin.close(descriptor)
        throw POSIXError(code)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func connectJournaldServiceLoopbackTCP(port: UInt16) throws -> FileHandle {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    let conversion = "127.0.0.1".withCString {
        Darwin.inet_pton(AF_INET, $0, &address.sin_addr)
    }
    guard conversion == 1 else {
        throw POSIXError(.EINVAL)
    }
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    }
    guard result == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        Darwin.close(descriptor)
        throw POSIXError(code)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}
