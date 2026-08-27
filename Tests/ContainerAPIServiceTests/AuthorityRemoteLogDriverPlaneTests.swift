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
import ContainerPersistence
import ContainerResource
import CryptoKit
import DockerSemanticHelper
import Foundation
import Logging
import NIOCore
import NIOPosix
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

private struct AuthorityUnavailableAWSLogsClientFactory:
    AWSLogsClientFactory
{
    func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient {
        throw AWSLogsClientError.requestFailed
    }
}

private enum AuthorityCatalogJournaldServiceError: Error {
    case unavailable
}

private actor AuthorityCatalogJournaldService: JournaldService {
    private var generation: UInt64?
    private(set) var readinessCalls = 0

    init(generation: UInt64?) {
        self.generation = generation
    }

    func setGeneration(_ generation: UInt64?) {
        self.generation = generation
    }

    func activeSandboxGeneration() throws -> UInt64 {
        readinessCalls += 1
        guard let generation else {
            throw AuthorityCatalogJournaldServiceError.unavailable
        }
        return generation
    }

    func openWriter(_ request: JournaldWriterOpenRequest) throws {
        _ = request
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func write(sessionID: String, entry: JournaldEntry) throws {
        _ = sessionID
        _ = entry
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func flushWriter(
        sessionID: String,
        deadline: ContinuousClock.Instant
    ) throws {
        _ = sessionID
        _ = deadline
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func closeWriter(
        sessionID: String,
        fenced: Bool,
        deadline: ContinuousClock.Instant
    ) throws {
        _ = sessionID
        _ = fenced
        _ = deadline
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func reclaimWriter(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        _ = sessionID
        _ = providerID
        _ = providerGeneration
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) throws -> any ContainerLogReader {
        _ = request
        throw AuthorityCatalogJournaldServiceError.unavailable
    }

    func reclaimReader(
        sessionID: String,
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        _ = sessionID
        _ = providerID
        _ = providerGeneration
        throw AuthorityCatalogJournaldServiceError.unavailable
    }
}

private struct AuthorityRecordingAWSLogsClientFactory: AWSLogsClientFactory {
    let client: AuthorityRecordingAWSLogsClient

    func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient {
        client
    }
}

private enum AuthorityRecordingGCPLoggingServiceError: Error {
    case closeFailed
}

private final class AuthorityRecordingGCPLoggingService:
    DockerGCPLoggingServicing, @unchecked Sendable
{
    private let lock = NSLock()
    private var remainingCloseFailures: Int
    private(set) var starts = 0
    private(set) var lines = [Data]()
    private(set) var closeAttempts = 0
    private(set) var closes = 0

    init(closeFailures: Int = 0) {
        self.remainingCloseFailures = closeFailures
    }

    func startGCPLoggingSession(
        sessionID: String,
        configuration: [DockerSemanticBytePair],
        info: DockerLogTemplateInfo,
        timeout: Duration
    ) throws {
        lock.withLock { starts += 1 }
    }

    func logGCPRecord(
        sessionID: String,
        timestampSeconds: Int64,
        timestampNanoseconds: UInt32,
        line: Data,
        timeout: Duration
    ) throws {
        lock.withLock { lines.append(line) }
    }

    func flushGCPLoggingSession(
        sessionID: String,
        timeout: Duration
    ) throws {}

    func closeGCPLoggingSession(
        sessionID: String,
        timeout: Duration
    ) throws {
        try lock.withLock {
            closeAttempts += 1
            if remainingCloseFailures > 0 {
                remainingCloseFailures -= 1
                throw AuthorityRecordingGCPLoggingServiceError.closeFailed
            }
            closes += 1
        }
    }

    func snapshot() -> (
        starts: Int,
        lines: [Data],
        closeAttempts: Int,
        closes: Int
    ) {
        lock.withLock { (starts, lines, closeAttempts, closes) }
    }
}

@Suite(.serialized)
struct AuthorityRemoteLogDriverPlaneTests {
    @Test
    func journaldCatalogAcceptsPrecreatedPluginStateDirectory() async throws {
        try await withPrivateTemporaryRoot { root in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
            let pluginStateDirectory = root.appendingPathComponent(
                "engine-services",
                isDirectory: true
            ).appendingPathComponent(
                "docker-plugins",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: pluginStateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityUnavailableAWSLogsClientFactory(),
                journaldService: AuthorityCatalogJournaldService(generation: 9)
            )

            #expect(
                try await plane.logDriverCatalog()
                    .descriptor(named: "journald") != nil
            )
        }
    }

    @Test
    func journaldCatalogTracksConcreteServiceReadiness() async throws {
        try await withTemporaryRoot { root in
            let service = AuthorityCatalogJournaldService(generation: 9)
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityUnavailableAWSLogsClientFactory(),
                journaldService: service
            )

            #expect(
                try await plane.logDriverCatalog()
                    .descriptor(named: "journald") != nil
            )
            #expect(await service.readinessCalls == 1)
            await service.setGeneration(nil)
            #expect(
                try await plane.logDriverCatalog()
                    .descriptor(named: "journald") == nil
            )
            #expect(await service.readinessCalls == 2)
            #expect(
                try await plane.advertisedLogDriverCatalog()
                    .descriptor(named: "journald") != nil
            )
            #expect(await service.readinessCalls == 2)
            await service.setGeneration(10)
            #expect(
                try await plane.logDriverCatalog()
                    .descriptor(named: "journald") != nil
            )
            #expect(await service.readinessCalls == 3)
        }
    }

    @Test
    func dockerPluginDirectReaderUsesAuthorityLedgerAndTerminalReclamation()
        async throws
    {
        try await withTemporaryRoot { root in
            let frame = try DockerPluginLogEntryCodec.encodeFrame(
                DockerPluginLogEntry(
                    source: "stderr",
                    timeNano: 42_500_000_000,
                    line: Data("plugin-history\n".utf8),
                    partial: false,
                    partialMetadata: nil
                )
            )
            let stream = AuthorityDockerPluginStream(chunks: [frame])
            let transport = AuthorityDockerPluginTransport(stream: stream)
            let lease = AuthorityDockerPluginLease(transport: transport)
            let acquirer = AuthorityDockerPluginAcquirer(lease: lease)
            let fifoFactory = try AuthorityDockerPluginFIFOFactory()
            let installation = DockerPluginLogDriverInstallation(
                driver: "example-plugin",
                providerIdentity: authorityDockerPluginIdentity,
                providerGeneration: authorityDockerPluginGeneration,
                readLogs: true,
                providerAcquirer: acquirer,
                fifoFactory: fifoFactory
            )
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityUnavailableAWSLogsClientFactory(),
                dockerPluginInstallations: [installation]
            )
            #expect(
                try await plane.logDriverCatalog()
                    .descriptor(named: "example-plugin") != nil
            )

            let id = "docker-plugin-reader"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try dockerPluginConfiguration(id: id)
            let reader = try await plane.openReader(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                read: ContainerLogReadRequest(tail: 10)
            )

            #expect(
                try await reader.next()
                    == .record(
                        try ContainerLogReadRecordV1(
                            stream: .stderr,
                            timestamp: ContainerLogTimestamp(
                                secondsSinceUnixEpoch: 42,
                                nanoseconds: 500_000_000
                            ),
                            data: Data("plugin-history\n".utf8),
                            sequence: 1
                        )
                    )
            )
            #expect(try await reader.next() == .endOfStream)
            #expect(await stream.closeCount == 1)
            #expect(await lease.releaseCount == 1)
            #expect(await acquirer.acquireCount == 1)
            #expect(await fifoFactory.createCount == 0)

            let persistence = try FileContainerLogLifecycleLedgerPersistenceV1(
                fileURL: bundle.containerLoggingV2.appendingPathComponent(
                    "provider-lifecycle-1-v1.json"
                )
            )
            let ledger = try await ContainerLogLifecycleLedgerV1.open(
                owningControllerID: controllerID(
                    id: id,
                    leaseGeneration: 1
                ),
                persistence: persistence
            )
            let snapshot = await ledger.snapshot()
            #expect(snapshot.readerOperations.count == 1)
            #expect(
                snapshot.readerOperations[0].result.session?.state
                    == .closed
            )
            #expect(snapshot.pendingEffectRemovals.isEmpty)
        }
    }

    @Test
    func nativeLogsUseDockerPluginAuthorityReader() async throws {
        try await withTemporaryRoot { root in
            let frame = try DockerPluginLogEntryCodec.encodeFrame(
                DockerPluginLogEntry(
                    source: "stdout",
                    timeNano: 42_500_000_000,
                    line: Data("native-plugin-history\n".utf8),
                    partial: false,
                    partialMetadata: nil
                )
            )
            let stream = AuthorityDockerPluginStream(chunks: [frame])
            let transport = AuthorityDockerPluginTransport(stream: stream)
            let lease = AuthorityDockerPluginLease(transport: transport)
            let acquirer = AuthorityDockerPluginAcquirer(lease: lease)
            let fifoFactory = try AuthorityDockerPluginFIFOFactory()
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityUnavailableAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    DockerPluginLogDriverInstallation(
                        driver: "example-plugin",
                        providerIdentity: authorityDockerPluginIdentity,
                        providerGeneration: authorityDockerPluginGeneration,
                        readLogs: true,
                        providerAcquirer: acquirer,
                        fifoFactory: fifoFactory
                    )
                ]
            )

            let id = "native-docker-plugin-reader"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent("containers")
                    .appendingPathComponent(id)
            )
            try FileManager.default.createDirectory(
                at: bundle.containerLoggingV2,
                withIntermediateDirectories: true
            )
            try bundle.set(configuration: dockerPluginConfiguration(id: id))
            try Data("boot-history\n".utf8).write(to: bundle.bootlog)

            let service = try ContainersService(
                appRoot: root,
                pluginLoader: try authorityPluginLoader(appRoot: root),
                containerSystemConfig: ContainerSystemConfig(),
                log: Logger(label: "native-docker-plugin-reader"),
                remoteLogDriverPlane: plane
            )
            let handles = try await service.logs(id: id)
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }

            #expect(
                try handles[0].readToEnd()
                    == Data("native-plugin-history\n".utf8)
            )
            #expect(
                try handles[1].readToEnd()
                    == Data("boot-history\n".utf8)
            )
            #expect(await stream.closeCount == 1)
            #expect(await lease.releaseCount == 1)
            #expect(await acquirer.acquireCount == 1)
        }
    }

    @Test
    func dockerPluginProductionPlanePreservesStdoutAndStderr() async throws {
        try await withTemporaryRoot { root in
            let stream = AuthorityDockerPluginStream(chunks: [])
            let transport = AuthorityDockerPluginTransport(stream: stream)
            let lease = AuthorityDockerPluginLease(transport: transport)
            let acquirer = AuthorityDockerPluginAcquirer(lease: lease)
            let fifoFactory = try AuthorityDockerPluginFIFOFactory()
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory:
                    AuthorityUnavailableAWSLogsClientFactory(),
                dockerPluginInstallations: [
                    DockerPluginLogDriverInstallation(
                        driver: "example-plugin",
                        providerIdentity: authorityDockerPluginIdentity,
                        providerGeneration: authorityDockerPluginGeneration,
                        readLogs: true,
                        providerAcquirer: acquirer,
                        fifoFactory: fifoFactory
                    )
                ]
            )
            let id = "docker-plugin-two-streams"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let runtimeStdio = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: dockerPluginConfiguration(id: id),
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )

            try #require(runtimeStdio[1]).write(
                contentsOf: Data("stdout line\n".utf8)
            )
            try #require(runtimeStdio[2]).write(
                contentsOf: Data("stderr line\n".utf8)
            )
            try await plane.bootstrapSucceeded(containerID: id)
            try await plane.activate(containerID: id)
            try await plane.close(containerID: id)

            let entries = try await fifoFactory.entries()
            #expect(entries.count == 2)
            #expect(
                Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.source, $0.line) }
                ) == [
                    "stdout": Data("stdout line".utf8),
                    "stderr": Data("stderr line".utf8),
                ]
            )
        }
    }

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
            let promise = serverGroup.next().makePromise(of: [Data].self)
            let capture = AuthorityDatagramSequenceCaptureHandler(
                expectedCount: 3,
                promise: promise
            )
            let server = try await DatagramBootstrap(group: serverGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(capture)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            do {
                let port = try #require(server.localAddress?.port)
                let plane = try await AuthorityRemoteLogDriverPlane.create(
                    appRoot: root,
                    awsLogsClientFactory:
                        AuthorityUnavailableAWSLogsClientFactory(),
                    containerSystemConfig: ContainerSystemConfig()
                )
                let id = "gelf-plane"
                let bundle = ContainerResource.Bundle(
                    path: root.appendingPathComponent(id, isDirectory: true)
                )
                try FileManager.default.createDirectory(
                    at: bundle.path,
                    withIntermediateDirectories: true
                )
                var configuration = try gelfConfiguration(
                    id: id,
                    port: port
                )
                configuration.initProcess.terminal = false
                let foreground = Pipe()
                let runtimeStdio = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, foreground.fileHandleForWriting, nil]
                )
                try foreground.fileHandleForWriting.close()

                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("plane-output-one\n".utf8)
                )
                try await Task.sleep(for: .milliseconds(50))
                try #require(runtimeStdio[2]).write(
                    contentsOf: Data("plane-error\n".utf8)
                )
                try await Task.sleep(for: .milliseconds(50))
                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("plane-output-two\n".utf8)
                )
                try await plane.bootstrapSucceeded(containerID: id)
                try await plane.activate(containerID: id)
                try await plane.close(containerID: id)

                let foregroundData = foreground.fileHandleForReading
                    .readDataToEndOfFile()
                #expect(
                    foregroundData
                        == Data("plane-output-one\nplane-output-two\n".utf8)
                )
                let datagrams = try await promise.futureResult.get()
                let messages = try datagrams.map { datagram in
                    let json = try #require(
                        String(data: datagram, encoding: .utf8)
                    )
                    let object = try #require(
                        JSONSerialization.jsonObject(with: Data(json.utf8))
                            as? [String: Any]
                    )
                    return try #require(object["short_message"] as? String)
                }
                #expect(
                    messages
                        == ["plane-output-one", "plane-error", "plane-output-two"]
                )
                #expect(
                    datagrams.allSatisfy { datagram in
                        String(data: datagram, encoding: .utf8)?
                            .contains("\"_image_name\":\"alpine:latest\"") == true
                    }
                )

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
    func awsLogsProductionPlanePublishesProviderBytes() async throws {
        try await withTemporaryRoot { root in
            let client = AuthorityRecordingAWSLogsClient()
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityRecordingAWSLogsClientFactory(
                    client: client
                )
            )
            let id = "awslogs-plane"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try awsLogsConfiguration(id: id)
            let runtimeStdio = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )

            try #require(runtimeStdio[1]).write(
                contentsOf: Data("aws-plane-output\n".utf8)
            )
            try await plane.bootstrapSucceeded(containerID: id)
            try await plane.activate(containerID: id)
            try await plane.close(containerID: id)

            let events = await client.publishedEvents
            #expect(events.count == 1)
            #expect(events[0].message == "aws-plane-output")
        }
    }

    @Test
    func recreatedContainerIDUsesANewProtectedEffectIdentity() async throws {
        try await withTemporaryRoot { root in
            let client = AuthorityRecordingAWSLogsClient()
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityRecordingAWSLogsClientFactory(
                    client: client
                )
            )
            let id = "recreated-remote-logging-container"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )

            for incarnation in [1.0, 2.0] {
                try FileManager.default.createDirectory(
                    at: bundle.path,
                    withIntermediateDirectories: true
                )
                var configuration = try awsLogsConfiguration(id: id)
                configuration.creationDate = Date(
                    timeIntervalSinceReferenceDate: incarnation
                )
                let runtimeStdio = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, nil, nil]
                )
                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("incarnation-\(Int(incarnation))\n".utf8)
                )
                try await plane.bootstrapSucceeded(containerID: id)
                try await plane.activate(containerID: id)
                try await plane.close(containerID: id)
                try FileManager.default.removeItem(at: bundle.path)
            }

            #expect(
                await client.publishedEvents.map(\.message)
                    == ["incarnation-1", "incarnation-2"]
            )
        }
    }

    @Test
    func protectedEffectReconciliationRetainsLiveAndFailsClosedOnCorruption()
        async throws
    {
        try await withTemporaryRoot { root in
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityRecordingAWSLogsClientFactory(
                    client: AuthorityRecordingAWSLogsClient()
                )
            )
            let absentContainerRoot = root.appendingPathComponent(
                "absent-containers",
                isDirectory: true
            )
            let absentReferences =
                try await AuthorityRemoteLogDriverPlane
                .durableProtectedEffectReferences(
                    containerRoot: absentContainerRoot
                )
            #expect(absentReferences.isEmpty)
            try await plane.reconcileProtectedEffects(
                containerRoot: absentContainerRoot
            )
            let containerRoot = root.appendingPathComponent(
                "containers",
                isDirectory: true
            )
            let bundle = ContainerResource.Bundle(
                path: containerRoot.appendingPathComponent("retained-effect")
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try awsLogsConfiguration(
                id: "retained-effect"
            )
            _ = try await plane.prepareBootstrap(
                containerID: configuration.id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )
            try await plane.bootstrapSucceeded(containerID: configuration.id)
            try await plane.activate(containerID: configuration.id)

            let liveReferences =
                try await AuthorityRemoteLogDriverPlane
                .durableProtectedEffectReferences(containerRoot: containerRoot)
            #expect(liveReferences.count == 1)

            let protectedRoot = root.appendingPathComponent(
                "logging-protected-effects",
                isDirectory: true
            )
            func tombstones() throws -> [URL] {
                try FileManager.default.contentsOfDirectory(
                    at: protectedRoot,
                    includingPropertiesForKeys: nil
                ).filter { $0.lastPathComponent.hasSuffix(".removed") }
            }

            try await plane.close(containerID: configuration.id)
            let retainedTombstones = try tombstones()
            #expect(retainedTombstones.count == 1)

            let corruptRoot = containerRoot.appendingPathComponent(
                "corrupt",
                isDirectory: true
            ).appendingPathComponent("logging-v2", isDirectory: true)
            try FileManager.default.createDirectory(
                at: corruptRoot,
                withIntermediateDirectories: true
            )
            try Data("{".utf8).write(
                to: corruptRoot.appendingPathComponent(
                    "provider-lifecycle-1-v1.json"
                )
            )
            try FileManager.default.removeItem(at: bundle.path)

            await #expect(throws: (any Error).self) {
                try await plane.reconcileProtectedEffects(
                    containerRoot: containerRoot
                )
            }
            let corruptionTombstones = try tombstones()
            #expect(corruptionTombstones.count == 1)

            try FileManager.default.removeItem(
                at: corruptRoot.deletingLastPathComponent()
            )
            try await plane.reconcileProtectedEffects(
                containerRoot: containerRoot
            )
            #expect(try tombstones().isEmpty)
        }
    }

    @Test
    func gcpLogsProductionPlanePublishesProviderBytes() async throws {
        try await withTemporaryRoot { root in
            let service = AuthorityRecordingGCPLoggingService()
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityUnavailableAWSLogsClientFactory(),
                gcpLoggingServiceFactory: { _ in service }
            )
            let id = "gcplogs-plane"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try gcpLogsConfiguration(id: id)
            let runtimeStdio = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )

            try #require(runtimeStdio[1]).write(
                contentsOf: Data("gcp-plane-output\n".utf8)
            )
            try await plane.bootstrapSucceeded(containerID: id)
            try await plane.activate(containerID: id)
            try await plane.close(containerID: id)

            let snapshot = service.snapshot()
            #expect(snapshot.starts == 1)
            #expect(snapshot.lines == [Data("gcp-plane-output".utf8)])
            #expect(snapshot.closes == 1)
        }
    }

    @Test
    func failedBootstrapAbortRetainsTheRunForCleanupRetry() async throws {
        try await withTemporaryRoot { root in
            let service = AuthorityRecordingGCPLoggingService(
                closeFailures: 1
            )
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityUnavailableAWSLogsClientFactory(),
                gcpLoggingServiceFactory: { _ in service }
            )
            let id = "gcplogs-abort-retry"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try gcpLogsConfiguration(id: id)

            _ = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )
            try await plane.bootstrapSucceeded(containerID: id)

            await #expect(throws: (any Error).self) {
                try await plane.abortBootstrap(containerID: id)
            }
            await #expect(
                throws: AuthorityRemoteLogDriverPlaneError.runAlreadyPrepared(
                    id
                )
            ) {
                _ = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, nil, nil]
                )
            }

            try await plane.abortBootstrap(containerID: id)
            _ = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )
            try await plane.bootstrapSucceeded(containerID: id)
            try await plane.abortBootstrap(containerID: id)

            let snapshot = service.snapshot()
            #expect(snapshot.closeAttempts == 2)
            #expect(snapshot.closes == 1)
        }
    }

    @Test
    func dockerLogInfoUsesCanonicalDockerIdentityWhenAvailable() throws {
        var configuration = try gcpLogsConfiguration(id: "native-resource-id")
        let dockerID = String(repeating: "a", count: 64)
        configuration.dockerID = dockerID
        configuration.dockerName = "visible-docker-name"

        let info = AuthorityRemoteLogDriverPlane.dockerLogInfo(
            configuration: configuration,
            imageName: "alpine:3.20"
        )

        #expect(info.containerID == dockerID)
        #expect(info.containerName == "visible-docker-name")
        #expect(info.containerImageName == "alpine:3.20")
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
                    appRoot: root,
                    awsLogsClientFactory:
                        AuthorityUnavailableAWSLogsClientFactory()
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

    @Test
    func retiredDockerPluginSandboxClosesAbsentStartBeforeNewWriter() async throws {
        try await withTemporaryRoot { root in
            let stream = AuthorityDockerPluginStream(chunks: [])
            let transport = AuthorityDockerPluginTransport(stream: stream)
            let lease = AuthorityDockerPluginLease(transport: transport)
            let acquirer = AuthorityDockerPluginAcquirer(lease: lease)
            let fifoFactory = try AuthorityDockerPluginFIFOFactory()
            let installation = DockerPluginLogDriverInstallation(
                driver: "example-plugin",
                providerIdentity: authorityDockerPluginIdentity,
                providerGeneration: authorityDockerPluginGeneration,
                readLogs: true,
                providerAcquirer: acquirer,
                fifoFactory: fifoFactory
            )
            let plane = try await AuthorityRemoteLogDriverPlane.create(
                appRoot: root,
                awsLogsClientFactory: AuthorityUnavailableAWSLogsClientFactory(),
                dockerPluginInstallations: [installation]
            )
            let id = "docker-plugin-retired-sandbox"
            let bundle = ContainerResource.Bundle(
                path: root.appendingPathComponent(id, isDirectory: true)
            )
            try FileManager.default.createDirectory(
                at: bundle.path,
                withIntermediateDirectories: true
            )
            let configuration = try dockerPluginConfiguration(id: id)
            let resolved = try #require(configuration.logging.resolved)
            let generationStore = try ContainerLogProcessGenerationStore(
                directoryURL: bundle.containerLoggingV2
            )
            let priorGeneration = try generationStore.next()
            let priorRequest = try recoveryRequest(
                id: id,
                configuration: configuration,
                resolved: resolved,
                generation: priorGeneration,
                candidateSandboxGeneration:
                    authorityDockerPluginSandboxGeneration - 1
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
            _ = try await ledger.reserveWriter(priorRequest)
            _ = try await ledger.markWriterStartRecoveryRequired(
                for: priorRequest
            )

            _ = try await plane.prepareBootstrap(
                containerID: id,
                bundle: bundle,
                configuration: configuration,
                authenticatedProtectedOptions: [:],
                stdio: [nil, nil, nil]
            )
            try await plane.bootstrapSucceeded(containerID: id)
            try await plane.activate(containerID: id)
            try await plane.close(containerID: id)

            let recovered = try await ContainerLogLifecycleLedgerV1.open(
                owningControllerID: controllerID(id: id, leaseGeneration: 1),
                persistence: persistence
            )
            let snapshot = await recovered.snapshot()
            #expect(snapshot.writerOperations.count == 2)
            #expect(snapshot.writerOperations[0].result == .candidateClosed)
            #expect(snapshot.writerOperations[1].request.candidateSandboxGeneration == authorityDockerPluginSandboxGeneration)
            #expect(snapshot.writerOperations[1].result.activation?.state == .closed)
            #expect(try generationStore.current() == 2)
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

    private func dockerPluginConfiguration(
        id: String
    ) throws -> ContainerConfiguration {
        let options = ["arbitrary-option": "preserved"]
        let descriptor = try DockerPluginLogDriverContract.descriptor(
            driver: "example-plugin",
            providerIdentity: authorityDockerPluginIdentity,
            providerGeneration: authorityDockerPluginGeneration,
            readLogs: true
        )
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: descriptor.driver,
            safeOptions: options,
            delivery: LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: descriptor.providerGeneration,
            contractDigest: descriptor.optionContractDigest
        )
        var configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(
                    mediaType:
                        "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "0", count: 64),
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "true"],
                environment: ["ENV=value"],
                terminal: false
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

    private func awsLogsConfiguration(id: String) throws -> ContainerConfiguration {
        let options = [
            "awslogs-group": "container-tests",
            "awslogs-stream": id,
            "awslogs-region": "eu-west-2",
            "awslogs-create-stream": "false",
        ]
        let descriptor = AWSLogsLogDriverContract.descriptor()
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

    private func gcpLogsConfiguration(id: String) throws -> ContainerConfiguration {
        let options = ["gcp-project": "container-tests"]
        let descriptor = GCPLogsLogDriverContract.descriptor()
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
        generation: UInt64,
        candidateSandboxGeneration: UInt64? = nil
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
            candidateSandboxGeneration: candidateSandboxGeneration
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

    private func withPrivateTemporaryRoot(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(
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

    private func authorityPluginLoader(appRoot: URL) throws -> PluginLoader {
        let pluginRoot = appRoot.appendingPathComponent("plugins")
        let runtimeURL = pluginRoot.appendingPathComponent(
            "container-runtime-linux"
        )
        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true
        )
        return try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [pluginRoot],
            pluginFactories: [AuthorityStaticRuntimePluginFactory()]
        )
    }
}

private let authorityDockerPluginGeneration: UInt64 = 7
private let authorityDockerPluginSandboxGeneration: UInt64 = 9
private let authorityDockerPluginIdentity = LogDriverProviderIdentity(
    id: "io.container.logging.plugin.authority-test",
    version: "1.0.0",
    kind: .dockerPlugin
)

private actor AuthorityDockerPluginStream: DockerPluginResponseStream {
    private var chunks: [Data]
    private(set) var closeCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func nextChunk(maximumBytes: Int) async throws -> Data? {
        guard let chunk = chunks.first else {
            return nil
        }
        guard chunk.count <= maximumBytes else {
            throw DockerPluginProtocolError.frameTooLarge(
                maximumBytes: maximumBytes
            )
        }
        chunks.removeFirst()
        return chunk
    }

    func close() async {
        closeCount += 1
    }
}

private actor AuthorityDockerPluginTransport: DockerPluginRPCTransport {
    private let stream: AuthorityDockerPluginStream
    private(set) var endpoints = [DockerPluginEndpoint]()

    init(stream: AuthorityDockerPluginStream) {
        self.stream = stream
    }

    func call(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant?
    ) async throws -> Data {
        _ = request
        _ = maximumResponseBytes
        _ = deadline
        endpoints.append(endpoint)
        switch endpoint {
        case .capabilities:
            return Data(
                "{\"Cap\":{\"ReadLogs\":true},\"Err\":\"\"}".utf8
            )
        case .startLogging, .stopLogging:
            return Data("{}".utf8)
        case .readLogs:
            throw DockerPluginProtocolError.transportFailure(
                endpoint: endpoint
            )
        }
    }

    func openStream(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumChunkBytes: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> any DockerPluginResponseStream {
        _ = request
        _ = maximumChunkBytes
        _ = deadline
        guard endpoint == .readLogs else {
            throw DockerPluginProtocolError.transportFailure(
                endpoint: endpoint
            )
        }
        endpoints.append(endpoint)
        return stream
    }
}

private actor AuthorityDockerPluginLease: DockerPluginProviderLease {
    nonisolated let providerGeneration = authorityDockerPluginGeneration
    nonisolated let transport: any DockerPluginRPCTransport
    private(set) var releaseCount = 0

    init(transport: any DockerPluginRPCTransport) {
        self.transport = transport
    }

    func release() async {
        releaseCount += 1
    }
}

private actor AuthorityDockerPluginAcquirer:
    DockerPluginProviderAcquiring
{
    private let lease: AuthorityDockerPluginLease
    private(set) var acquireCount = 0

    init(lease: AuthorityDockerPluginLease) {
        self.lease = lease
    }

    func activeSandboxGeneration(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> UInt64 {
        try validate(
            providerID: providerID,
            providerGeneration: providerGeneration
        )
        return authorityDockerPluginSandboxGeneration
    }

    func acquire(
        providerID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginProviderLease {
        try validate(
            providerID: providerID,
            providerGeneration: providerGeneration
        )
        acquireCount += 1
        return lease
    }

    private func validate(
        providerID: String,
        providerGeneration: UInt64
    ) throws {
        guard
            providerID == authorityDockerPluginIdentity.id,
            providerGeneration == authorityDockerPluginGeneration
        else {
            throw DockerPluginProtocolError.invalidProviderIdentity
        }
    }
}

private actor AuthorityDockerPluginFIFOFactory: DockerPluginFIFOFactory {
    private let fifo: AuthorityDockerPluginFIFO
    private(set) var createCount = 0

    init() throws {
        self.fifo = try AuthorityDockerPluginFIFO()
    }

    func createFIFO(
        sessionID: String,
        providerGeneration: UInt64
    ) async throws -> any DockerPluginFIFO {
        _ = sessionID
        guard providerGeneration == authorityDockerPluginGeneration else {
            throw DockerPluginProtocolError.providerGenerationMismatch
        }
        createCount += 1
        return fifo
    }

    func entries() async throws -> [DockerPluginLogEntry] {
        try await fifo.entries()
    }
}

private actor AuthorityDockerPluginFIFO: DockerPluginFIFO {
    nonisolated let reference: DockerPluginFIFOReference
    private var frames = [Data]()

    init() throws {
        self.reference = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/authority-test"
        )
    }

    func writeFrame(_ frame: Data) async throws {
        frames.append(frame)
    }

    func entries() throws -> [DockerPluginLogEntry] {
        try frames.map { frame in
            guard frame.count >= 4 else {
                throw DockerPluginProtocolError.malformedFrame
            }
            return try DockerPluginLogEntryCodec.decodeMessage(
                Data(frame.dropFirst(4))
            )
        }
    }

    func closeAndRemove() async {}

    func revokeAndRemove() async {}
}

private struct AuthorityStaticRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux"
        else {
            return nil
        }
        return Plugin(
            binaryURL: installURL.appending(path: "bin/container-runtime-linux"),
            config: runtimeConfig
        )
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }

    private var runtimeConfig: PluginConfig {
        let servicesConfig = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [
                PluginConfig.Service(type: .runtime, description: nil)
            ],
            defaultArguments: []
        )
        return PluginConfig(
            abstract: "runtime",
            author: nil,
            servicesConfig: servicesConfig
        )
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

private actor AuthorityRecordingAWSLogsClient: AWSLogsClient {
    private(set) var publishedEvents = [AWSLogsInputEvent]()

    func createLogGroup(name: String) async throws {}

    func createLogStream(group: String, stream: String) async throws {}

    func putLogEvents(
        group: String,
        stream: String,
        events: [AWSLogsInputEvent],
        sequenceToken: String?
    ) async throws -> AWSLogsPutResult {
        publishedEvents.append(contentsOf: events)
        return AWSLogsPutResult(nextSequenceToken: "next-token")
    }

    func close() async {}
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

private final class AuthorityDatagramSequenceCaptureHandler:
    ChannelInboundHandler, @unchecked Sendable
{
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let expectedCount: Int
    private let promise: EventLoopPromise<[Data]>
    private let lock = NSLock()
    private var datagrams = [Data]()
    private var completed = false

    init(expectedCount: Int, promise: EventLoopPromise<[Data]>) {
        self.expectedCount = expectedCount
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        let bytes = envelope.data.readBytes(length: envelope.data.readableBytes) ?? []
        let result = lock.withLock { () -> Result<[Data], any Error>? in
            guard !completed else {
                return nil
            }
            datagrams.append(Data(bytes))
            guard datagrams.count == expectedCount else {
                return nil
            }
            completed = true
            return .success(datagrams)
        }
        result.map(promise.completeWith)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<[Data], any Error>) {
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
