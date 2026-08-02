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

@testable import ContainerLoggingStorage
@testable import ContainerRuntimeLinuxServer

@Suite(.serialized)
struct DockerJSONFileLogStoreTests {
    @Test
    func encodesDockerCanonicalRecordShapeAndAttributeOrder() throws {
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_781_776_800,
            nanoseconds: 123_456_789
        )
        let record = try ordinaryRecord(
            payload: Data("stdout-line".utf8),
            stream: .stdout,
            timestamp: timestamp,
            attributes: ["zeta": "last", "oracle.label": "alpha"]
        )

        let encoded = try DockerJSONFileLogCodec.encode(record)

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"log":"stdout-line\n","stream":"stdout","attrs":{"oracle.label":"alpha","zeta":"last"},"time":"2026-06-18T10:00:00.123456789Z"}"# + "\n"
        )
    }

    @Test
    func matchesDockerByteStringEscapingAndInvalidUTF8Replacement() throws {
        let timestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)
        let payload =
            Data([
                UInt8(ascii: "&"), UInt8(ascii: "<"), UInt8(ascii: ">"),
                UInt8(ascii: "\t"), 0xaf,
            ]) + Data("\u{2028}".utf8)
        let record = try ordinaryRecord(payload: payload, timestamp: timestamp)

        let encoded = try DockerJSONFileLogCodec.encode(record)

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"log":"\u0026\u003c\u003e\u0009\ufffd\u2028\n","stream":"stdout","time":"1970-01-01T00:00:00Z"}"# + "\n"
        )
    }

    @Test
    func jsonFileUsesNewlineStateButDoesNotPersistPartialMetadata() throws {
        let timestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 1)
        let records = try splitRecords(
            Data("abc\n".utf8),
            maximumRecordBytes: 2,
            timestamp: timestamp
        )
        #expect(records.count == 2)

        let first = try DockerJSONFileLogCodec.encode(records[0])
        let last = try DockerJSONFileLogCodec.encode(records[1])

        #expect(String(decoding: first, as: UTF8.self).contains(#""log":"ab""#))
        #expect(!String(decoding: first, as: UTF8.self).contains("partial"))
        #expect(String(decoding: last, as: UTF8.self).contains(#""log":"c\n""#))
        #expect(!String(decoding: last, as: UTF8.self).contains("partial"))
    }

    @Test
    func formatsAndParsesDockerRFC3339Nano() throws {
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_781_776_800,
            nanoseconds: 120_000_000
        )

        #expect(try DockerRFC3339Nano.format(timestamp) == "2026-06-18T10:00:00.12Z")
        #expect(
            try DockerRFC3339Nano.parse("2026-06-18T11:00:00.12+01:00")
                == timestamp
        )
        #expect(
            try DockerRFC3339Nano.parse("2026-06-18T10:00:00.123456789987654321Z")
                == (try ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1_781_776_800,
                    nanoseconds: 123_456_789
                ))
        )
        #expect(throws: DockerJSONFileLogError.malformedTimestamp) {
            try DockerRFC3339Nano.parse("2026-02-29T10:00:00Z")
        }
    }

    @Test
    func appendsAcrossReopenAndReadsPublicLogBytes() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let configuration = try DockerJSONFileLogConfiguration()
        let first = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try first.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try first.close()

        let second = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try second.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try second.close()

        let result = try second.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(result.records.map(\.storageSequence) == [1, 2])
        #expect(result.issues.isEmpty)
        #expect(
            try Data(contentsOf: second.logURL)
                == Data(
                    (#"{"log":"first\n","stream":"stdout","time":"1970-01-01T00:00:00Z"}"# + "\n"
                        + #"{"log":"second\n","stream":"stdout","time":"1970-01-01T00:00:00Z"}"# + "\n").utf8
                )
        )
    }

    @Test
    func createsPrivateDirectoryAndDockerModeCurrentUserFile() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.close()

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.logDirectory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.logURL.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect((fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }

    @Test
    func refusesActiveFileSymlinkWithoutMutatingTarget() throws {
        let fixture = try LogDirectoryFixture(createLogDirectory: true)
        defer { fixture.remove() }
        let victim = fixture.root.appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: fixture.activeURL,
            withDestinationURL: victim
        )

        #expect(throws: DockerJSONFileLogError.self) {
            try DockerJSONFileLogStore(
                directoryURL: fixture.logDirectory,
                activeFileName: fixture.activeFileName
            )
        }
        #expect(try Data(contentsOf: victim) == Data("safe".utf8))
    }

    @Test
    func refusesSymlinkedDirectoryComponents() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let actualDirectory = fixture.root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(
            at: actualDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let linkedDirectory = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: actualDirectory
        )

        #expect(throws: DockerJSONFileLogError.self) {
            try DockerJSONFileLogStore(
                directoryURL: linkedDirectory,
                activeFileName: fixture.activeFileName
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actualDirectory.path).isEmpty)
    }

    @Test
    func refusesRotatedSymlinkWithoutMutatingTarget() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8)))
        let victim = fixture.root.appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: fixture.rotationURL(1),
            withDestinationURL: victim
        )

        #expect(throws: DockerJSONFileLogError.unsafeStorage) {
            try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        }
        try store.close()
        #expect(try Data(contentsOf: victim) == Data("safe".utf8))
    }

    @Test
    func rotatesBeforeNextRecordWithOneRecordOvershootAndSuffixOrder() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.write(ordinaryRecord(payload: Data("third".utf8), sequence: 3))
        try store.close()

        #expect(try logs(in: fixture.rotationURL(2)) == ["first\n"])
        #expect(try logs(in: fixture.rotationURL(1)) == ["second\n"])
        #expect(try logs(in: fixture.activeURL) == ["third\n"])
        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["first\n", "second\n", "third\n"])
    }

    @Test
    func maximumFileCountOneRetainsOnlyActiveFile() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 1
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.close()

        #expect(try logs(in: fixture.activeURL) == ["second\n"])
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
    }

    @Test
    func rotationPrunesStaleSuffixesOutsideCurrentRetention() throws {
        let fixture = try LogDirectoryFixture(createLogDirectory: true)
        defer { fixture.remove() }
        try Data("stale".utf8).write(to: fixture.rotationURL(7))
        try Data("stale".utf8).write(to: fixture.rotationURL(7, compressed: true))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.rotationURL(7).path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.rotationURL(7, compressed: true).path
        )
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 1
            )
        )

        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.close()

        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(7).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(7, compressed: true).path))
        #expect(try logs(in: fixture.activeURL) == ["second\n"])
    }

    @Test
    func thresholdStateSurvivesWriterReopen() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let configuration = try DockerJSONFileLogConfiguration(
            maximumFileSize: 1,
            maximumFileCount: 2
        )
        let first = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try first.write(ordinaryRecord(payload: Data("first".utf8)))
        try first.close()

        let second = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try second.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try second.close()

        #expect(try logs(in: fixture.rotationURL(1)) == ["first\n"])
        #expect(try logs(in: fixture.activeURL) == ["second\n"])
    }

    @Test
    func reopenTruncatesTornTailBeforeAppending() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let first = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try first.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try first.close()
        let completePrefix = try Data(contentsOf: fixture.activeURL)

        let handle = try FileHandle(forWritingTo: fixture.activeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"log":"torn""#.utf8))
        try handle.close()

        let reopened = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        #expect(try Data(contentsOf: fixture.activeURL) == completePrefix)
        try reopened.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try reopened.close()

        let result = try reopened.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(result.issues.isEmpty)
    }

    @Test
    func reopenTruncatesFileWithoutCompleteRecordToZero() throws {
        let fixture = try LogDirectoryFixture(createLogDirectory: true)
        defer { fixture.remove() }
        try Data(#"{"log":"torn""#.utf8).write(to: fixture.activeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: fixture.activeURL.path
        )

        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        #expect(try Data(contentsOf: fixture.activeURL).isEmpty)
        try store.write(ordinaryRecord(payload: Data("recovered".utf8)))
        try store.close()

        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("recovered\n".utf8)])
        #expect(result.issues.isEmpty)
    }

    @Test
    func nonBlockingDeliveryContinuesAfterPartialWriteRollback() async throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let fault = PartialWriteFault()
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(),
            hooks: DockerJSONFileLogStoreHooks(
                writeEncodedRecord: { data, descriptor in
                    try fault.write(data, to: descriptor)
                }
            )
        )
        let delivery = ContainerLogNonBlockingDelivery(destination: store)

        #expect(
            try delivery.enqueue(ordinaryRecord(payload: Data("partial".utf8), sequence: 1))
                == .enqueued
        )
        try await waitUntil { delivery.snapshot.deliveryFailureCount == 1 }
        #expect(try Data(contentsOf: fixture.activeURL).isEmpty)

        #expect(
            try delivery.enqueue(ordinaryRecord(payload: Data("complete".utf8), sequence: 2))
                == .enqueued
        )
        try delivery.close()

        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("complete\n".utf8)])
        #expect(result.issues.isEmpty)
        #expect(delivery.snapshot.deliveryFailureCount == 1)
        #expect(delivery.snapshot.deliveredRecordCount == 1)
    }

    @Test
    func liveSnapshotPinsFilesAndCompletedActiveBoundaryAcrossRotation() async throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let snapshotGate = BlockingTestGate()
        let writeCalls = TestCallCounter()
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2
            ),
            hooks: DockerJSONFileLogStoreHooks(
                didEnumerateSnapshot: { snapshotGate.block() },
                writeWillAcquireCoordinatorLock: { writeCalls.increment() }
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        let reader = try store.makeReader()

        let readTask = Task.detached {
            try reader.read(DockerJSONFileLogReadRequest())
        }
        try snapshotGate.waitUntilEntered()
        let writeTask = Task.detached {
            try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        }
        try writeCalls.waitUntilCount(2)

        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(try logs(in: fixture.activeURL) == ["first\n"])
        snapshotGate.release()

        let snapshot = try await readTask.value
        try await writeTask.value
        #expect(snapshot.records.map(\.log) == [Data("first\n".utf8)])
        #expect(snapshot.issues.isEmpty)

        try store.close()
        let current = try reader.read(DockerJSONFileLogReadRequest())
        #expect(current.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(current.issues.isEmpty)
    }

    @Test
    func compressesRotationsAndReaderReplaysThemOldestFirst() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.write(ordinaryRecord(payload: Data("third".utf8), sequence: 3))
        try store.close()

        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2, compressed: true).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["first\n", "second\n", "third\n"])
    }

    @Test
    func compressedRotationCarriesDocker2921LastTimestampFEXTRA() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_781_776_800,
            nanoseconds: 123_456_789
        )
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(
            ordinaryRecord(
                payload: Data("first".utf8),
                timestamp: timestamp,
                sequence: 1
            )
        )
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.close()

        let compressed = try Data(contentsOf: fixture.rotationURL(1, compressed: true))
        let expectedExtra = Data(
            #"{"lastTime":"2026-06-18T10:00:00.123456789Z"}"#.utf8
        )
        var expectedHeader = Data([
            0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
            UInt8(truncatingIfNeeded: expectedExtra.count),
            UInt8(truncatingIfNeeded: expectedExtra.count >> 8),
        ])
        expectedHeader.append(expectedExtra)

        // Captured against Docker Engine 29.2.1 on this MBP. Moby writes the
        // JSON bytes directly as FEXTRA rather than as a registered subfield.
        #expect(compressed.starts(with: expectedHeader))
    }

    @Test
    func sinceSkipsOlderCompressedRotationBeforeInflation() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let oldTimestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 10, nanoseconds: 1)
        let newTimestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 20, nanoseconds: 2)
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(
            ordinaryRecord(
                payload: Data("old".utf8),
                timestamp: oldTimestamp,
                sequence: 1
            )
        )
        try store.write(
            ordinaryRecord(
                payload: Data("new".utf8),
                timestamp: newTimestamp,
                sequence: 2
            )
        )
        try store.close()
        try corruptFirstDeflateByte(fixture.rotationURL(1, compressed: true))

        let skipped = try store.makeReader().read(
            DockerJSONFileLogReadRequest(
                since: try ContainerLogTimestamp(secondsSinceUnixEpoch: 11, nanoseconds: 0)
            )
        )
        #expect(skipped.records.map(\.log) == [Data("new\n".utf8)])

        #expect(throws: DockerJSONFileLogError.compressionFailed) {
            try store.makeReader().read(
                DockerJSONFileLogReadRequest(since: oldTimestamp)
            )
        }
    }

    @Test
    func asyncCompressionFailureIsInspectableAndRetainsSafeRotations() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            ),
            hooks: DockerJSONFileLogStoreHooks(
                compressionWillStart: {
                    throw DockerJSONFileLogError.io(.read, EIO)
                }
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.write(ordinaryRecord(payload: Data("third".utf8), sequence: 3))
        try store.close()

        let snapshot = store.snapshot
        #expect(snapshot.closed)
        #expect(!snapshot.writePoisoned)
        #expect(!snapshot.compressionRunning)
        #expect(snapshot.successfulCompressionCount == 0)
        #expect(snapshot.compressionFailureCount == 2)
        #expect(
            snapshot.lastCompressionFailure
                == DockerJSONFileCompressionFailure(
                    stage: .preparation,
                    error: .io(.read, EIO)
                )
        )
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8), Data("third\n".utf8)])
    }

    @Test
    func compressionStartsAfterReplacementActiveAndNextRotationFences() async throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let compressionGate = BlockingTestGate()
        let compressionWaits = TestCallCounter()
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            ),
            hooks: DockerJSONFileLogStoreHooks(
                compressionWillStart: { compressionGate.block() },
                compressionWaitDidBegin: { compressionWaits.increment() }
            )
        )

        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try compressionGate.waitUntilEntered()

        #expect(try logs(in: fixture.activeURL) == ["second\n"])
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))

        let writeTask = Task.detached {
            try store.write(ordinaryRecord(payload: Data("third".utf8), sequence: 3))
        }
        try compressionWaits.waitUntilCount(1)
        #expect(try logs(in: fixture.activeURL) == ["second\n"])

        compressionGate.release()
        try await writeTask.value
        try store.close()

        let result = try store.makeReader().read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8), Data("third\n".utf8)])
        #expect(result.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2, compressed: true).path))
    }

    @Test
    func pinnedReaderSurvivesConcurrentGzipPublicationAndSourceUnlink() async throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let compressionGate = BlockingTestGate()
        let readerGate = BlockingTestGate()
        defer {
            compressionGate.release()
            readerGate.release()
        }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            ),
            hooks: DockerJSONFileLogStoreHooks(
                compressionWillStart: { compressionGate.block() },
                readPinnedSnapshotWillBegin: { readerGate.block() }
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try compressionGate.waitUntilEntered()

        let reader = try store.makeReader()
        let readTask = Task.detached {
            try reader.read(DockerJSONFileLogReadRequest())
        }
        try readerGate.waitUntilEntered()

        compressionGate.release()
        let compressedRotationPath = fixture.rotationURL(1, compressed: true).path
        let uncompressedRotationPath = fixture.rotationURL(1).path
        try await waitUntil {
            FileManager.default.fileExists(
                atPath: compressedRotationPath
            )
                && !FileManager.default.fileExists(atPath: uncompressedRotationPath)
        }
        readerGate.release()

        let result = try await readTask.value
        try store.close()
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8)])
        #expect(result.issues.isEmpty)
    }

    @Test
    func closeFencesOutstandingCompression() async throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let compressionGate = BlockingTestGate()
        let compressionWaits = TestCallCounter()
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            ),
            hooks: DockerJSONFileLogStoreHooks(
                compressionWillStart: { compressionGate.block() },
                compressionWaitDidBegin: { compressionWaits.increment() }
            )
        )

        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try compressionGate.waitUntilEntered()

        let closeTask = Task.detached {
            try store.close()
        }
        try compressionWaits.waitUntilCount(1)
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))

        compressionGate.release()
        try await closeTask.value
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
    }

    @Test
    func corruptedCompressedRotationFailsExplicitly() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8)))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.close()
        let compressedURL = fixture.rotationURL(1, compressed: true)
        try corruptFirstDeflateByte(compressedURL)

        #expect(throws: DockerJSONFileLogError.compressionFailed) {
            try store.makeReader().read(DockerJSONFileLogReadRequest())
        }
    }

    @Test
    func malformedOlderRotationDoesNotHideNewerFile() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try DockerJSONFileLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2
            )
        )
        try store.write(ordinaryRecord(payload: Data("old".utf8)))
        try store.write(ordinaryRecord(payload: Data("new".utf8), sequence: 2))
        try store.close()
        let rotation = try FileHandle(forWritingTo: fixture.rotationURL(1))
        try rotation.truncate(atOffset: 0)
        try rotation.write(contentsOf: Data("not-json\n".utf8))
        try rotation.close()

        let result = try stoppedReader(for: fixture, maximumFileCount: 2).read(
            DockerJSONFileLogReadRequest()
        )
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["new\n"])
        #expect(result.issues == [.malformedRecord(fileIndex: 1, byteOffset: 0)])
    }

    @Test
    func tailThenTimeAndStreamFiltersMatchReaderOrdering() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for index in 0..<4 {
            let timestamp = try ContainerLogTimestamp(
                secondsSinceUnixEpoch: Int64(index),
                nanoseconds: 0
            )
            try store.write(
                ordinaryRecord(
                    payload: Data("line-\(index)".utf8),
                    stream: index.isMultiple(of: 2) ? .stdout : .stderr,
                    timestamp: timestamp,
                    sequence: UInt64(index + 1)
                )
            )
        }
        try store.close()

        let result = try store.makeReader().read(
            DockerJSONFileLogReadRequest(
                stdout: false,
                stderr: true,
                tail: 3,
                since: try ContainerLogTimestamp(secondsSinceUnixEpoch: 1, nanoseconds: 0),
                until: try ContainerLogTimestamp(secondsSinceUnixEpoch: 3, nanoseconds: 0)
            )
        )
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["line-1\n", "line-3\n"])
    }

    @Test
    func reportsTruncatedTailAndStopsAtMalformedCompleteRecord() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(ordinaryRecord(payload: Data("before".utf8), sequence: 1))
        try store.close()
        let handle = try FileHandle(forWritingTo: fixture.activeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.write(contentsOf: Data(#"{"log":"after\n","stream":"stdout","time":"1970-01-01T00:00:00Z"}"#.utf8))
        try handle.write(contentsOf: Data("\n{\"log\":".utf8))
        try handle.close()

        let result = try stoppedReader(for: fixture).read(DockerJSONFileLogReadRequest())
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["before\n"])
        #expect(result.issues.count == 1)
        #expect(
            result.issues.first
                == .malformedRecord(
                    fileIndex: 0,
                    byteOffset: UInt64(try DockerJSONFileLogCodec.encode(ordinaryRecord(payload: Data("before".utf8))).count)
                )
        )
    }

    @Test
    func reportsOnlyTruncatedFinalRecordWhenPriorRecordsAreValid() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(ordinaryRecord(payload: Data("complete".utf8)))
        try store.close()
        let handle = try FileHandle(forWritingTo: fixture.activeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"log\":".utf8))
        try handle.close()

        let result = try stoppedReader(for: fixture).read(DockerJSONFileLogReadRequest())
        #expect(result.records.map { String(decoding: $0.log, as: UTF8.self) } == ["complete\n"])
        #expect(result.issues == [.truncatedFinalRecord(fileIndex: 0)])
    }

    @Test
    func enforcesReadByteAndRecordBounds() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(ordinaryRecord(payload: Data("one".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("two".utf8), sequence: 2))
        try store.close()
        let reader = try store.makeReader()

        #expect(throws: DockerJSONFileLogError.storageLimitExceeded) {
            try reader.read(DockerJSONFileLogReadRequest(maximumDecodedBytes: 1))
        }
        #expect(throws: DockerJSONFileLogError.storageLimitExceeded) {
            try reader.read(DockerJSONFileLogReadRequest(maximumRecords: 1))
        }
        let tail = try reader.read(DockerJSONFileLogReadRequest(tail: 1, maximumRecords: 1))
        #expect(tail.records.map { String(decoding: $0.log, as: UTF8.self) } == ["two\n"])
    }

    @Test
    func rejectsCallerInflatedHardReadLimits() {
        #expect(throws: DockerJSONFileLogError.invalidReadRequest) {
            try DockerJSONFileLogReadRequest(
                maximumDecodedBytes: DockerJSONFileLogReadRequest.hardMaximumDecodedBytes + 1
            )
        }
        #expect(throws: DockerJSONFileLogError.invalidReadRequest) {
            try DockerJSONFileLogReadRequest(
                maximumRecords: DockerJSONFileLogReadRequest.hardMaximumRecords + 1
            )
        }
    }

    @Test
    func aggregateReadQuotaBoundsConcurrentMemoryAndCPUAdmission() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(ordinaryRecord(payload: Data("one".utf8)))
        try store.close()

        let quota = try DockerJSONFileReadQuota(
            maximumReservedBytes: 3 * 1024 * 1024,
            maximumConcurrentReads: 1
        )
        let heldLease = try quota.acquire(maximumDecodedBytes: 64)
        let reader = try DockerJSONFileLogReader(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            maximumFileCount: 1,
            readQuota: quota
        )
        _ = withExtendedLifetime(heldLease) {
            #expect(throws: DockerJSONFileLogError.readQuotaExceeded) {
                try reader.read(
                    DockerJSONFileLogReadRequest(maximumDecodedBytes: 64)
                )
            }
        }

        heldLease.release()
        let result = try reader.read(
            DockerJSONFileLogReadRequest(maximumDecodedBytes: 256)
        )
        #expect(result.records.map(\.log) == [Data("one\n".utf8)])
    }

    @Test
    func boundedTailReadsOnlyNewestRawFileSuffix() throws {
        let fixture = try LogDirectoryFixture()
        defer { fixture.remove() }
        let store = try DockerJSONFileLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for index in 0..<100 {
            try store.write(
                ordinaryRecord(
                    payload: Data("line-\(index)".utf8),
                    sequence: UInt64(index + 1)
                )
            )
        }
        try store.close()
        let reader = try store.makeReader()

        #expect(throws: DockerJSONFileLogError.storageLimitExceeded) {
            try reader.read(DockerJSONFileLogReadRequest(maximumDecodedBytes: 256))
        }
        let tail = try reader.read(
            DockerJSONFileLogReadRequest(
                tail: 1,
                maximumDecodedBytes: 256,
                maximumRecords: 1
            )
        )
        #expect(tail.records.map { String(decoding: $0.log, as: UTF8.self) } == ["line-99\n"])
    }

    private func ordinaryRecord(
        payload: Data,
        stream: ContainerLogStream = .stdout,
        timestamp: ContainerLogTimestamp? = nil,
        sequence: UInt64 = 1,
        attributes: [String: String] = [:]
    ) throws -> ContainerLogRecordV2 {
        let timestamp = try timestamp ?? ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)
        let records = try splitRecords(
            payload + Data([UInt8(ascii: "\n")]),
            maximumRecordBytes: ContainerLogRecordSplitterV1.defaultMaximumRecordBytes,
            stream: stream,
            timestamp: timestamp,
            firstSequence: sequence,
            attributes: attributes
        )
        return try #require(records.first)
    }

    private func splitRecords(
        _ data: Data,
        maximumRecordBytes: Int,
        stream: ContainerLogStream = .stdout,
        timestamp: ContainerLogTimestamp,
        firstSequence: UInt64 = 1,
        attributes: [String: String] = [:]
    ) throws -> [ContainerLogRecordV2] {
        var splitter = try ContainerLogRecordSplitterV1(
            stream: stream,
            maximumRecordBytes: maximumRecordBytes
        )
        let observation = ContainerLogObservation(
            wallClock: timestamp,
            monotonicInstant: ContinuousClock().now
        )
        var records: [ContainerLogRecordV2] = []
        try splitter.append(
            data,
            observationProvider: { observation },
            emit: { fragment in
                records.append(
                    try ContainerLogRecordV2(
                        fragment: fragment,
                        sequence: firstSequence + UInt64(records.count),
                        attributes: attributes,
                        processGeneration: 1
                    )
                )
            }
        )
        return records
    }

    private func logs(in url: URL) throws -> [String] {
        try Data(contentsOf: url)
            .split(separator: UInt8(ascii: "\n"))
            .map { line in
                let object = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                return try #require(object["log"] as? String)
            }
    }

    private func corruptFirstDeflateByte(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let header = try #require(try handle.read(upToCount: 12))
        try #require(header.count == 12)
        let extraLength = Int(header[10]) | (Int(header[11]) << 8)
        let deflateOffset = UInt64(12 + extraLength)
        try handle.seek(toOffset: deflateOffset)
        let original = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: deflateOffset)
        try handle.write(contentsOf: Data([original ^ 0xff]))
        try handle.close()
    }

    private func stoppedReader(
        for fixture: LogDirectoryFixture,
        maximumFileCount: Int = 1
    ) throws -> DockerJSONFileLogReader {
        try DockerJSONFileLogReader(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            maximumFileCount: maximumFileCount
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw LogStoreTestError.timeout
    }
}

private enum LogStoreTestError: Error {
    case timeout
}

private final class BlockingTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func block() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !entered {
            guard condition.wait(until: deadline) else {
                throw LogStoreTestError.timeout
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class TestCallCounter: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    func increment() {
        condition.lock()
        count += 1
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilCount(_ expected: Int, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while count < expected {
            guard condition.wait(until: deadline) else {
                throw LogStoreTestError.timeout
            }
        }
    }
}

private final class PartialWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failNextWrite = true

    func write(_ data: Data, to descriptor: Int32) throws {
        lock.lock()
        let shouldFail = failNextWrite
        failNextWrite = false
        lock.unlock()

        let byteCount = shouldFail ? min(17, data.count) : data.count
        try writePrefix(data, byteCount: byteCount, to: descriptor)
        if shouldFail {
            throw DockerJSONFileLogError.io(.write, EIO)
        }
    }

    private func writePrefix(_ data: Data, byteCount: Int, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < byteCount {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    byteCount - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw DockerJSONFileLogError.io(.write, result < 0 ? errno : EIO)
                }
                written += result
            }
        }
    }
}

private final class LogDirectoryFixture {
    let root: URL
    let logDirectory: URL
    let activeFileName = "container-json.log"

    var activeURL: URL {
        logDirectory.appendingPathComponent(activeFileName)
    }

    init(createLogDirectory: Bool = false) throws {
        let temporaryRootPath = FileManager.default.temporaryDirectory.path
        let canonicalPointer = temporaryRootPath.withCString { Darwin.realpath($0, nil) }
        let canonicalPath = try #require(canonicalPointer.map { String(cString: $0) })
        free(canonicalPointer)
        let temporaryRoot = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        root = temporaryRoot.appendingPathComponent("container-json-file-tests-\(UUID().uuidString)")
        logDirectory = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        if createLogDirectory {
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func rotationURL(_ index: Int, compressed: Bool = false) -> URL {
        URL(fileURLWithPath: "\(activeURL.path).\(index)\(compressed ? ".gz" : "")")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
