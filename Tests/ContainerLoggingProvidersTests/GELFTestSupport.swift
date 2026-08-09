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

import Foundation
import NIOPosix
import Testing
import zlib

@testable import ContainerLoggingProviders
@testable import ContainerResource

enum GELFTestFailure: Error, Equatable, Sendable {
    case connect
    case write
    case close
    case exhausted
    case timedOut
}

enum GELFTestWriteOutcome: Sendable {
    case success
    case partial(Int)
    case failure(GELFTestFailure)
    case block
}

enum GELFTestCloseOutcome: Sendable {
    case success
    case successKeepingWriteBlocked
    case failure(GELFTestFailure)
    case block
}

actor RecordingGELFTransport: GELFTransport {
    private(set) var messages = [Data]()
    private(set) var writeTimeouts = [Duration]()
    private(set) var closeTimeouts = [Duration]()
    private var outcomes: [GELFTestWriteOutcome]
    private var closeOutcomes: [GELFTestCloseOutcome]
    private var blockedWrite: CheckedContinuation<Int, any Error>?
    private var blockedClose: CheckedContinuation<Void, any Error>?
    private var blockedWaiters = [CheckedContinuation<Void, Never>]()
    private var blockedCloseWaiters = [CheckedContinuation<Void, Never>]()

    init(
        outcomes: [GELFTestWriteOutcome] = [],
        closeOutcomes: [GELFTestCloseOutcome] = []
    ) {
        self.outcomes = outcomes
        self.closeOutcomes = closeOutcomes
    }

    var closeCallCount: Int { closeTimeouts.count }

    func write(_ message: Data, timeout: Duration) async throws -> Int {
        messages.append(message)
        writeTimeouts.append(timeout)
        guard !outcomes.isEmpty else {
            return message.count
        }
        switch outcomes.removeFirst() {
        case .success:
            return message.count
        case .partial(let count):
            return count
        case .failure(let error):
            throw error
        case .block:
            return try await withCheckedThrowingContinuation { continuation in
                blockedWrite = continuation
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
    }

    func close(timeout: Duration) async throws {
        closeTimeouts.append(timeout)
        let outcome = closeOutcomes.isEmpty ? .success : closeOutcomes.removeFirst()
        switch outcome {
        case .success:
            interruptBlockedWrite()
        case .successKeepingWriteBlocked:
            return
        case .failure(let error):
            interruptBlockedWrite()
            throw error
        case .block:
            interruptBlockedWrite()
            try await withCheckedThrowingContinuation { continuation in
                blockedClose = continuation
                let waiters = blockedCloseWaiters
                blockedCloseWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
    }

    func waitUntilWriteBlocked() async {
        if blockedWrite != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseBlockedWrite() {
        let continuation = blockedWrite
        blockedWrite = nil
        guard let message = messages.last else {
            continuation?.resume(throwing: GELFTestFailure.exhausted)
            return
        }
        continuation?.resume(returning: message.count)
    }

    func waitUntilCloseBlocked() async {
        if blockedClose != nil {
            return
        }
        await withCheckedContinuation { continuation in
            blockedCloseWaiters.append(continuation)
        }
    }

    func releaseBlockedClose() {
        let continuation = blockedClose
        blockedClose = nil
        continuation?.resume()
    }

    private func interruptBlockedWrite() {
        let continuation = blockedWrite
        blockedWrite = nil
        continuation?.resume(throwing: GELFProviderError.transportClosed)
    }
}

enum GELFTestConnectOutcome: Sendable {
    case transport(RecordingGELFTransport)
    case failure(GELFTestFailure)
}

struct GELFTestConnectCall: Equatable, Sendable {
    let endpoint: GELFEndpoint
    let timeout: Duration
}

actor ScriptedGELFTransportFactory: GELFTransportFactory {
    private var outcomes: [GELFTestConnectOutcome]
    private(set) var connectCalls = [GELFTestConnectCall]()

    init(_ outcomes: [GELFTestConnectOutcome]) {
        self.outcomes = outcomes
    }

    var connectCallCount: Int { connectCalls.count }

    func connect(
        to endpoint: GELFEndpoint,
        timeout: Duration
    ) async throws -> any GELFTransport {
        connectCalls.append(GELFTestConnectCall(endpoint: endpoint, timeout: timeout))
        guard !outcomes.isEmpty else {
            throw GELFTestFailure.exhausted
        }
        switch outcomes.removeFirst() {
        case .transport(let transport): return transport
        case .failure(let error): throw error
        }
    }
}

final class GELFTestClock: GELFClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSleeps = [Duration]()

    var sleeps: [Duration] {
        lock.withLock { recordedSleeps }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { recordedSleeps.append(duration) }
    }
}

final class CancellingGELFTestClock: GELFClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSleeps = [Duration]()

    var sleeps: [Duration] {
        lock.withLock { recordedSleeps }
    }

    func sleep(for duration: Duration) async throws {
        lock.withLock { recordedSleeps.append(duration) }
        throw CancellationError()
    }
}

struct FixedGELFChunkIDGenerator: GELFChunkIDGenerating {
    let bytes: Data

    func makeChunkID() throws -> Data {
        bytes
    }
}

func gelfTestConfiguration(
    endpoint: GELFEndpoint = .udp(
        GELFNetworkAddress(host: "127.0.0.1", port: "12201")
    ),
    compressionType: GELFCompressionType = .none,
    compressionLevel: Int32 = 1,
    maximumReconnects: Int = 3,
    reconnectDelay: Duration = .milliseconds(10),
    tag: String = "0123456789ab",
    hostname: String = "test-host",
    containerID: String = "container-id",
    containerName: String = "web",
    imageID: String = "sha256:image-id",
    imageName: String = "example/web:latest",
    command: String = "/bin/server --listen :8080",
    created: Date = Date(timeIntervalSince1970: 1.25),
    metadata: [String: String] = [:],
    policy: GELFConnectionPolicy? = nil
) throws -> GELFDriverConfiguration {
    let resolvedPolicy =
        try policy
        ?? GELFConnectionPolicy(
            connectTimeout: .milliseconds(20),
            writeTimeout: .milliseconds(30),
            closeTimeout: .milliseconds(40)
        )
    return try GELFDriverConfiguration(
        endpoint: endpoint,
        compressionType: compressionType,
        compressionLevel: compressionLevel,
        maximumReconnects: maximumReconnects,
        reconnectDelay: reconnectDelay,
        tag: tag,
        hostname: hostname,
        containerID: containerID,
        containerName: containerName,
        imageID: imageID,
        imageName: imageName,
        command: command,
        created: created,
        metadata: metadata,
        policy: resolvedPolicy
    )
}

func gelfRecord(
    stream: ContainerLogStream = .stdout,
    payload: Data,
    timestamp: ContainerLogTimestamp? = nil,
    partial: ContainerLogPartialMetadataV1? = nil,
    sequence: UInt64 = 1
) throws -> ContainerLogRecordV2 {
    let resolvedTimestamp =
        try timestamp
        ?? ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1,
            nanoseconds: 234_999_999
        )
    return try ContainerLogRecordV2(
        stream: stream,
        observation: ContainerLogObservation(
            wallClock: resolvedTimestamp,
            monotonicInstant: ContinuousClock().now
        ),
        payload: payload,
        partial: partial,
        sequence: sequence,
        processGeneration: 1
    )
}

func withGELFEventLoopGroup<Result: Sendable>(
    _ body: @escaping @Sendable (MultiThreadedEventLoopGroup) async throws -> Result
) async throws -> Result {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let result = try await body(group)
        try await group.shutdownGracefully()
        return result
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

func gelfInflate(_ input: Data, windowBits: Int32) throws -> Data {
    var stream = z_stream()
    guard
        inflateInit2_(
            &stream,
            windowBits,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK
    else {
        throw GELFTestFailure.exhausted
    }
    defer { inflateEnd(&stream) }

    var output = [UInt8](repeating: 0, count: max(input.count * 32, 4_096))
    let outputCapacity = output.count
    let status: Int32 = input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)
            stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(outputCapacity)
            return zlib.inflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END else {
        throw GELFTestFailure.exhausted
    }
    return Data(output.prefix(Int(stream.total_out)))
}

extension Collection {
    var gelfOnly: Element? {
        count == 1 ? first : nil
    }
}
