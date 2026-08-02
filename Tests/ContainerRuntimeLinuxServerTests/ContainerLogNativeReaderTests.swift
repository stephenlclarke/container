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
import Containerization
import Darwin
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

@Suite(.serialized)
struct ContainerLogNativeReaderTests {
    @Test
    func jsonFileReaderPreservesPresentationAndEmitsOneTerminalEvent() async throws {
        let fixture = try NativeReaderFixture()
        defer { fixture.remove() }
        let configuration = try loggingV2Configuration(driver: "json-file")
        let capture = try ContainerLogRuntimePlan(configuration: configuration).activate(
            bundle: fixture.bundle,
            terminal: false
        )
        try #require(capture.stdout).write(Data("first\nsecond\n".utf8))
        capture.close()

        let reader = try ContainerLogNativeReaderFactory.makeReader(
            bundle: fixture.bundle,
            configuration: configuration,
            request: ContainerLogReadRequest(follow: true),
            source: .stoppedContainer
        )
        let records = try await drain(reader)

        #expect(records.map(\.stream) == [.stdout, .stdout])
        #expect(records.map(\.data) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(records.map(\.sequence) == [1, 2])
        #expect(records.allSatisfy { $0.processGeneration == nil })
        await #expect(throws: ContainerLogReaderError.alreadyEnded) {
            try await reader.next()
        }
    }

    @Test
    func localReaderRetainsPartialBoundariesAndProcessGeneration() async throws {
        let fixture = try NativeReaderFixture()
        defer { fixture.remove() }
        let configuration = try loggingV2Configuration(
            driver: "local",
            options: [
                "compress": "false",
                "max-file": "2",
                "max-size": "1m",
            ]
        )
        let capture = try ContainerLogRuntimePlan(configuration: configuration).activate(
            bundle: fixture.bundle,
            terminal: false
        )
        let firstChunk = Data(
            repeating: UInt8(ascii: "a"),
            count: ContainerLogRecordSplitterV1.maximumSupportedRecordBytes
        )
        let finalChunk = Data("end".utf8)
        try #require(capture.stderr).write(firstChunk + finalChunk)
        capture.close()

        let reader = try ContainerLogNativeReaderFactory.makeReader(
            bundle: fixture.bundle,
            configuration: configuration,
            request: ContainerLogReadRequest(),
            source: .stoppedContainer
        )
        let records = try await drain(reader)

        #expect(records.map(\.stream) == [.stderr, .stderr])
        #expect(records[0].data == firstChunk)
        #expect(records[1].data == finalChunk)
        #expect(records.map(\.processGeneration) == [1, 1])
    }

    @Test
    func remoteDriverReadsOnlyItsDockerDefaultLocalCache() async throws {
        let fixture = try NativeReaderFixture()
        defer { fixture.remove() }
        try fixture.createSecureDirectory(at: fixture.bundle.containerLoggingV2)
        let cacheConfiguration = try LogCacheConfiguration(
            maxSizeInBytes: 20 * 1024 * 1024,
            maxFileCount: 5,
            compress: true
        )
        let configuration = try loggingV2Configuration(
            driver: "syslog",
            readPolicy: LogReadPolicy(source: .dualCache, cache: cacheConfiguration)
        )
        let store = try NativeLocalLogStore(
            directoryURL: fixture.bundle.containerNativeLogCacheDirectory,
            activeFileName: ContainerResource.Bundle.nativeLogCacheName,
            configuration: NativeLocalLogConfiguration()
        )
        let timestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 20, nanoseconds: 30)
        try store.write(
            ContainerLogRecordV2(
                stream: .stdout,
                observation: ContainerLogObservation(
                    wallClock: timestamp,
                    monotonicInstant: ContinuousClock().now
                ),
                payload: Data("cached".utf8),
                partial: nil,
                sequence: 4,
                attributes: ["source": "remote"],
                processGeneration: 7
            )
        )
        try store.close()

        let reader = try ContainerLogNativeReaderFactory.makeReader(
            bundle: fixture.bundle,
            configuration: configuration,
            request: ContainerLogReadRequest(details: true),
            source: .stoppedContainer
        )
        let records = try await drain(reader)

        #expect(records.count == 1)
        #expect(records[0].data == Data("cached\n".utf8))
        #expect(records[0].attributes == ["source": "remote"])
        #expect(records[0].sequence == 4)
        #expect(records[0].processGeneration == 7)
    }

    @Test
    func unreadableAndProviderReadersAreNeverCollapsedOntoLocalFiles() throws {
        let fixture = try NativeReaderFixture()
        defer { fixture.remove() }

        #expect(throws: ContainerLogReaderError.configuredDriverDoesNotSupportReading) {
            try ContainerLogNativeReaderFactory.makeReader(
                bundle: fixture.bundle,
                configuration: try loggingV2Configuration(driver: "none"),
                request: ContainerLogReadRequest(follow: true),
                source: try activeReaderSource()
            )
        }
        #expect(throws: ContainerLogNativeReaderFactoryError.providerReaderRequired("journald")) {
            try ContainerLogNativeReaderFactory.makeReader(
                bundle: fixture.bundle,
                configuration: try loggingV2Configuration(
                    driver: "journald",
                    readPolicy: LogReadPolicy(source: .direct)
                ),
                request: ContainerLogReadRequest(follow: true),
                source: try activeReaderSource()
            )
        }
        #expect(throws: ContainerLogReaderError.activeReaderRequired) {
            try ContainerLogNativeReaderFactory.makeReader(
                bundle: fixture.bundle,
                configuration: try loggingV2Configuration(driver: "json-file"),
                request: ContainerLogReadRequest(follow: true),
                source: try activeReaderSource()
            )
        }
    }

    @Test
    func legacyReaderKeepsMigrationBytesFiltersAndSymlinkFence() async throws {
        let fixture = try NativeReaderFixture()
        defer { fixture.remove() }
        var configuration = baseConfiguration()
        configuration.logging = ContainerLogConfiguration(maxFileCount: 2)
        let writer = try ContainerLogFileWriter(
            rawLogURL: fixture.bundle.containerLog,
            recordLogURL: fixture.bundle.containerLogRecords,
            maxFileCount: 2,
            dateProvider: { Date(timeIntervalSince1970: 42) }
        )
        let stdout = writer.writer(for: .stdout)
        let stderr = writer.writer(for: .stderr)
        try stdout.write(Data("ignored\n".utf8))
        try stderr.write(Data("legacy\n".utf8))
        try stdout.close()
        try stderr.close()

        let reader = try ContainerLogNativeReaderFactory.makeReader(
            bundle: fixture.bundle,
            configuration: configuration,
            request: ContainerLogReadRequest(
                stdout: false,
                stderr: true,
                follow: true,
                tail: 1,
                since: Date(timeIntervalSince1970: 40),
                until: Date(timeIntervalSince1970: 44)
            ),
            source: .stoppedContainer
        )
        let records = try await drain(reader)
        #expect(records.map(\.data) == [Data("legacy\n".utf8)])
        #expect(records.map(\.stream) == [.stderr])
        #expect(records.map(\.timestamp.secondsSinceUnixEpoch) == [42])

        try FileManager.default.removeItem(at: fixture.bundle.containerLogRecords)
        try FileManager.default.createSymbolicLink(
            at: fixture.bundle.containerLogRecords,
            withDestinationURL: fixture.bundle.containerLog
        )
        #expect(throws: ContainerLogNativeReaderFactoryError.legacyIO(ELOOP)) {
            try ContainerLogNativeReaderFactory.makeReader(
                bundle: fixture.bundle,
                configuration: configuration,
                request: ContainerLogReadRequest(),
                source: .stoppedContainer
            )
        }
    }

    @Test
    func bufferedReaderRejectsConcurrentCallAndTaskCancellationEndsIt() async throws {
        let gate = NativeReaderAsyncGate()
        let reader: any ContainerLogReader = ContainerLogBufferedReader(
            records: [
                try ContainerLogReadRecordV1(
                    stream: .stdout,
                    timestamp: ContainerLogTimestamp(
                        secondsSinceUnixEpoch: 1,
                        nanoseconds: 0
                    ),
                    data: Data("buffered\n".utf8),
                    sequence: 1
                )
            ],
            nextCallAdmitted: { await gate.block() }
        )
        let first = Task {
            try await reader.next()
        }
        await gate.waitUntilEntered()

        await #expect(throws: ContainerLogReaderError.concurrentReadNotSupported) {
            try await reader.next()
        }
        first.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        await #expect(throws: ContainerLogReaderError.alreadyEnded) {
            try await reader.next()
        }
    }

    private func drain(
        _ reader: any ContainerLogReader
    ) async throws -> [ContainerLogReadRecordV1] {
        var records: [ContainerLogReadRecordV1] = []
        while true {
            switch try await reader.next() {
            case .record(let record):
                records.append(record)
            case .endOfStream:
                return records
            }
        }
    }

    private func activeReaderSource() throws -> LoggingReaderSourceV1 {
        try LoggingReaderSourceV1(
            activeWriterSessionID: "writer-session",
            writerProviderID: "provider",
            writerProviderGeneration: 1,
            activeProcessGeneration: 1,
            activeSandboxGeneration: nil
        )
    }

    private func loggingV2Configuration(
        driver: String,
        options: [String: String] = [:],
        readPolicy: LogReadPolicy? = nil
    ) throws -> ContainerConfiguration {
        let descriptor = BuiltinLogDriverDescriptors.current.descriptor(named: driver)
        let identity =
            descriptor?.providerIdentity
            ?? LogDriverProviderIdentity(
                id: "test.logging.\(driver)",
                version: "1",
                kind: .native
            )
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: driver,
            safeOptions: options,
            delivery: LogDeliveryConfiguration(),
            readPolicy: try readPolicy
                ?? LogReadPolicy(source: driver == "none" ? .unavailable : .direct),
            providerIdentity: identity,
            providerGenerationAtResolution: descriptor?.providerGeneration ?? 1,
            contractDigest: descriptor?.optionContractDigest ?? "sha256:test-\(driver)"
        )
        let logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: driver, options: options),
            resolved: resolved
        )
        var configuration = baseConfiguration()
        configuration.logging = logging
        return configuration
    }

    private func baseConfiguration() -> ContainerConfiguration {
        ContainerConfiguration(
            id: "native-reader-test",
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
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0),
                supplementalGroups: [],
                rlimits: []
            )
        )
    }
}

private struct NativeReaderFixture {
    let bundle: ContainerResource.Bundle

    init() throws {
        let temporaryRootPath = FileManager.default.temporaryDirectory.path
        let canonicalPointer = temporaryRootPath.withCString { Darwin.realpath($0, nil) }
        guard let canonicalPointer else {
            throw NativeReaderFixtureError.canonicalTemporaryDirectory(errno)
        }
        let canonicalTemporaryRoot = URL(
            fileURLWithPath: String(cString: canonicalPointer),
            isDirectory: true
        )
        free(canonicalPointer)
        bundle = ContainerResource.Bundle(
            path: canonicalTemporaryRoot.appendingPathComponent(
                "container-log-native-reader-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        try createSecureDirectory(at: bundle.path)
    }

    func createSecureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: bundle.path)
    }
}

private enum NativeReaderFixtureError: Error {
    case canonicalTemporaryDirectory(Int32)
}

private actor NativeReaderAsyncGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
