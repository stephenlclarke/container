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

import ContainerLoggingProviders
import ContainerResource
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ContainerAPIService

@Suite(.serialized)
struct AuthorityRemoteLogDriverPlaneTests {
    @Test
    func nonBlockingDeliveryPreservesOrderAcrossQueueCompaction() async throws {
        let session = AuthorityRecordingLogDriverSession()
        let delivery = AuthorityRemoteLogDelivery(
            session: session,
            configuration: try LogDeliveryConfiguration(
                requestedMode: .nonBlocking,
                maxBufferSizeInBytes: 2_000_000
            )
        )

        for sequence in 1...4_096 {
            await delivery.submit(try logRecord(sequence: UInt64(sequence)))
        }
        try await delivery.finish()

        #expect(await session.sequences == (1...4_096).map(UInt64.init))
        #expect(
            await delivery.metrics()
                == AuthorityRemoteLogDeliveryMetrics(
                    queuedRecords: 0,
                    queuedBytes: 0,
                    droppedRecords: 0,
                    writeFailures: 0
                )
        )
    }

    @Test
    func nonBlockingDeliveryAdmitsOneOversizedRecordThenDropsNew() async throws {
        let session = AuthorityPausingLogDriverSession()
        let delivery = AuthorityRemoteLogDelivery(
            session: session,
            configuration: try LogDeliveryConfiguration(
                requestedMode: .nonBlocking,
                maxBufferSizeInBytes: 0
            )
        )

        await delivery.submit(try logRecord(sequence: 1))
        await session.waitForWriteCount(1)
        await delivery.submit(try logRecord(sequence: 2))

        #expect((await delivery.metrics()).droppedRecords == 1)
        await session.releaseWrite()
        try await delivery.finish()
        #expect(await session.sequences == [1])
    }

    @Test
    func gelfProductionPlaneForwardsForegroundAndProviderBytes() async throws {
        try await withTemporaryRoot { root in
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let promise = serverGroup.next().makePromise(of: Data.self)
            let capture = AuthorityDatagramCaptureHandler(promise: promise)
            let server = try await DatagramBootstrap(group: serverGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(capture)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            do {
                let port = try #require(server.localAddress?.port)
                let plane = try await AuthorityRemoteLogDriverPlane.create(
                    appRoot: root
                )
                let id = "gelf-plane"
                let bundle = ContainerResource.Bundle(
                    path: root.appendingPathComponent(id, isDirectory: true)
                )
                try FileManager.default.createDirectory(
                    at: bundle.path,
                    withIntermediateDirectories: true
                )
                let configuration = try gelfConfiguration(
                    id: id,
                    port: port
                )
                let foreground = Pipe()
                let runtimeStdio = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, foreground.fileHandleForWriting, nil]
                )

                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("plane-output\n".utf8)
                )
                try await plane.bootstrapSucceeded(containerID: id)
                try await plane.activate(containerID: id)
                try await plane.close(containerID: id)

                let foregroundData = foreground.fileHandleForReading
                    .readDataToEndOfFile()
                #expect(foregroundData == Data("plane-output\n".utf8))
                let datagram = try await promise.futureResult.get()
                let json = try #require(String(data: datagram, encoding: .utf8))
                #expect(json.contains("\"short_message\":\"plane-output\""))

                try await server.close().get()
                capture.cancel()
                try await serverGroup.shutdownGracefully()
            } catch {
                capture.cancel()
                try? await server.close().get()
                try? await serverGroup.shutdownGracefully()
                throw error
            }
        }
    }

    @Test
    func reservedWriterIsReconciledBeforeNextGenerationStarts() async throws {
        try await withTemporaryRoot { root in
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let promise = serverGroup.next().makePromise(of: Data.self)
            let capture = AuthorityDatagramCaptureHandler(promise: promise)
            let server = try await DatagramBootstrap(group: serverGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(capture)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            do {
                let port = try #require(server.localAddress?.port)
                let id = "gelf-reserved-recovery"
                let bundle = ContainerResource.Bundle(
                    path: root.appendingPathComponent(id, isDirectory: true)
                )
                try FileManager.default.createDirectory(
                    at: bundle.path,
                    withIntermediateDirectories: true
                )
                let configuration = try gelfConfiguration(id: id, port: port)
                let resolved = try #require(configuration.logging.resolved)
                let generationStore = try ContainerLogProcessGenerationStore(
                    directoryURL: bundle.containerLoggingV2
                )
                let generation = try generationStore.next()
                #expect(generation == 1)
                let request = try recoveryRequest(
                    id: id,
                    configuration: configuration,
                    resolved: resolved,
                    generation: generation
                )
                let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
                    fileURL: bundle.containerLoggingV2.appendingPathComponent(
                        "provider-lifecycle-1-v1.json"
                    )
                )
                let ledger = try await ContainerLogLifecycleLedgerV1.open(
                    owningControllerID: controllerID(id: id, leaseGeneration: 1),
                    persistence: persistence
                )
                _ = try await ledger.reserveWriter(request)

                let plane = try await AuthorityRemoteLogDriverPlane.create(
                    appRoot: root
                )
                let runtimeStdio = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, nil, nil]
                )
                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("after-recovery\n".utf8)
                )
                try await plane.bootstrapSucceeded(containerID: id)
                try await plane.activate(containerID: id)
                try await plane.close(containerID: id)

                let datagram = try await promise.futureResult.get()
                let json = try #require(String(data: datagram, encoding: .utf8))
                #expect(json.contains("\"short_message\":\"after-recovery\""))
                let recovered = try await ContainerLogLifecycleLedgerV1.open(
                    owningControllerID: controllerID(id: id, leaseGeneration: 1),
                    persistence: persistence
                )
                let snapshot = await recovered.snapshot()
                #expect(snapshot.writerOperations.count == 2)
                #expect(snapshot.writerOperations[0].result == .candidateClosed)
                #expect(snapshot.writerOperations[1].result.activation?.state == .closed)
                #expect(try generationStore.current() == 2)

                try await server.close().get()
                capture.cancel()
                try await serverGroup.shutdownGracefully()
            } catch {
                capture.cancel()
                try? await server.close().get()
                try? await serverGroup.shutdownGracefully()
                throw error
            }
        }
    }

    private func gelfConfiguration(
        id: String,
        port: Int
    ) throws -> ContainerConfiguration {
        let options = [
            "gelf-address": "udp://127.0.0.1:\(port)",
            "gelf-compression-type": "none",
        ]
        let descriptor = GELFLogDriverContract.descriptor()
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: descriptor.driver,
            safeOptions: options,
            delivery: LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .unavailable),
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: descriptor.providerGeneration,
            contractDigest: descriptor.optionContractDigest
        )
        var configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "0", count: 64),
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: [],
                terminal: true
            )
        )
        configuration.logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: descriptor.driver,
                options: options
            ),
            resolved: resolved
        )
        return configuration
    }

    private func logRecord(sequence: UInt64) throws -> ContainerLogRecordV2 {
        try ContainerLogRecordV2(
            stream: .stdout,
            observation: ContainerLogObservation(
                wallClock: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1,
                    nanoseconds: 0
                ),
                monotonicInstant: ContinuousClock().now
            ),
            payload: Data("record-\(sequence)".utf8),
            partial: nil,
            sequence: sequence,
            processGeneration: 1
        )
    }

    private func recoveryRequest(
        id: String,
        configuration: ContainerConfiguration,
        resolved: ResolvedContainerLogConfiguration,
        generation: UInt64
    ) throws -> LogDriverStartRequestV1 {
        let semanticDigest = try semanticDigest(
            id: id,
            configuration: configuration.logging
        )
        let identityDigest = sha256Hex(
            Data("\(id)\u{0}\(resolved.leaseGeneration)\u{0}\(generation)".utf8)
        )
        return try LogDriverStartRequestV1(
            operationGeneration: generation,
            idempotencyKey: "writer-\(identityDigest)",
            semanticRequestDigest: semanticDigest,
            sessionID: "session-\(identityDigest)",
            containerID: id,
            leaseGeneration: resolved.leaseGeneration,
            candidateProcessGeneration: generation,
            providerID: resolved.providerIdentity.id,
            providerGeneration: resolved.providerGenerationAtResolution,
            candidateSandboxGeneration: nil
        )
    }

    private func semanticDigest(
        id: String,
        configuration: ContainerLogConfiguration
    ) throws -> String {
        let binding = try LoggingProtectedOptionsBinding(
            containerID: id,
            configuration: configuration
        )
        let reference = configuration.resolved?.protectedOptionReference
        var data = Data("container.logging.semantic-request.v1\u{0}".utf8)
        data.append(try binding.canonicalData())
        data.append(0)
        data.append(Data((reference?.objectID ?? "-").utf8))
        data.append(0)
        data.append(Data((reference?.integrityDigest ?? "-").utf8))
        return "sha256:" + sha256Hex(data)
    }

    private func controllerID(id: String, leaseGeneration: UInt64) -> String {
        "container-\(sha256Hex(Data(id.utf8)))-lease-\(leaseGeneration)"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func withTemporaryRoot(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authority-remote-log-plane-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private actor AuthorityRecordingLogDriverSession: ContainerLogDriverSession {
    private(set) var sequences = [UInt64]()

    func write(_ record: ContainerLogRecordV2) async throws {
        sequences.append(record.sequence)
    }

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {}
}

private actor AuthorityPausingLogDriverSession: ContainerLogDriverSession {
    private(set) var sequences = [UInt64]()
    private var writeWaiters = [CheckedContinuation<Void, Never>]()
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeReleased = false

    func write(_ record: ContainerLogRecordV2) async throws {
        sequences.append(record.sequence)
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !writeReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            writeContinuation = continuation
        }
    }

    func waitForWriteCount(_ count: Int) async {
        guard sequences.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    func releaseWrite() {
        writeReleased = true
        writeContinuation?.resume()
        writeContinuation = nil
    }

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {}
}

private final class AuthorityDatagramCaptureHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let promise: EventLoopPromise<Data>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        let bytes =
            envelope.data.readBytes(
                length: envelope.data.readableBytes
            ) ?? []
        complete(.success(Data(bytes)))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Data, any Error>) {
        let shouldComplete = lock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
        guard shouldComplete else {
            return
        }
        promise.completeWith(result)
    }
}
