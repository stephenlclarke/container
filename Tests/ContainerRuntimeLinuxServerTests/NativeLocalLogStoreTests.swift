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

struct NativeLocalLogStoreTests {
    @Test
    func defaultsMatchDockerLocalPolicy() throws {
        let configuration = try NativeLocalLogConfiguration()

        #expect(configuration.maximumFileSize == 20 * 1024 * 1024)
        #expect(configuration.maximumFileCount == 5)
        #expect(configuration.compress)
    }

    @Test
    func dockerConfigurationAndRequestBoundsHaveNoArtificialFileCountCap() throws {
        let configuration = try NativeLocalLogConfiguration(
            maximumFileSize: 1,
            maximumFileCount: 50_000,
            compress: false
        )
        #expect(configuration.maximumFileCount == 50_000)
        #expect(throws: NativeLocalLogError.invalidConfiguration) {
            try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 1,
                compress: true
            )
        }
        #expect(try NativeLocalLogReadRequest(tail: -1).effectiveTail == nil)
        #expect(try NativeLocalLogReadRequest(tail: -42).effectiveTail == nil)
        #expect(throws: NativeLocalLogError.invalidReadRequest) {
            try NativeLocalLogReadRequest(
                maximumDecodedBytes: NativeLocalLogReadRequest.hardMaximumDecodedBytes + 1
            )
        }
        #expect(throws: NativeLocalLogError.invalidReadRequest) {
            try NativeLocalLogReadRequest(
                maximumStoredBytes: NativeLocalLogReadRequest.hardMaximumStoredBytes + 1
            )
        }
        #expect(throws: NativeLocalLogError.invalidReadRequest) {
            try NativeLocalLogReadRequest(
                maximumRecords: NativeLocalLogReadRequest.hardMaximumRecords + 1
            )
        }
    }

    @Test
    func binaryPartialMetadataAndAttributesSurviveReopenLosslessly() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: -12,
            nanoseconds: 987_654_321
        )
        let firstRecords = try splitRecords(
            Data([0x00, 0xff, 0x80, 0x41, UInt8(ascii: "\n")]),
            maximumRecordBytes: 2,
            stream: .stderr,
            timestamp: timestamp,
            firstSequence: 41,
            attributes: ["zeta": "\u{0}value", "alpha": "β"],
            processGeneration: 7
        )
        #expect(firstRecords.count == 3)
        #expect(firstRecords.allSatisfy { $0.partial != nil })

        let firstStore = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for record in firstRecords {
            try firstStore.write(record)
        }
        try firstStore.close()

        let finalRecord = try ordinaryRecord(
            payload: Data([0x01, 0xfe, 0x42]),
            sequence: 43,
            processGeneration: 8
        )
        let reopened = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try reopened.write(finalRecord)
        try reopened.close()

        let result = try reopened.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.issues.isEmpty)
        #expect(result.records.map(PersistedRecord.init) == (firstRecords + [finalRecord]).map(PersistedRecord.init))
    }

    @Test
    func handoffSnapshotPinsAndExportsExactStoredBytes() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(
            ordinaryRecord(payload: Data("handoff".utf8), sequence: 1)
        )
        try store.close()
        let expected = try Data(contentsOf: store.storageURL)

        let segments = try NativeLocalLogHandoffSegmentExporter.snapshot(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )

        let segment = try #require(segments.first)
        #expect(segments.count == 1)
        #expect(segment.rotationIndex == 0)
        #expect(!segment.compressed)
        #expect(segment.sourceDeviceID > 0)
        #expect(segment.sourceInode > 0)
        #expect(segment.bytes == expected)
        #expect(try Data(contentsOf: store.storageURL) == expected)
    }

    @Test
    func createsCurrentUserPrivateStorageAndRejectsSymlinks() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.close()

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.logDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.storageURL.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())

        let linkedFixture = try NativeLocalLogFixture(createLogDirectory: true)
        defer { linkedFixture.remove() }
        let victim = linkedFixture.root.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: linkedFixture.activeURL,
            withDestinationURL: victim
        )
        #expect(throws: NativeLocalLogError.self) {
            try NativeLocalLogStore(
                directoryURL: linkedFixture.logDirectory,
                activeFileName: linkedFixture.activeFileName
            )
        }
        #expect(try Data(contentsOf: victim) == Data("unchanged".utf8))

        let actual = linkedFixture.root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(
            at: actual,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let linked = linkedFixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        #expect(throws: NativeLocalLogError.self) {
            try NativeLocalLogStore(
                directoryURL: linked,
                activeFileName: linkedFixture.activeFileName
            )
        }
    }

    @Test
    func rotatesAfterOneRecordOvershootCompressesAndReplaysOldestFirst() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            )
        )

        try store.write(ordinaryRecord(payload: Data("one".utf8), sequence: 1))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        try store.write(ordinaryRecord(payload: Data("two".utf8), sequence: 2))
        try store.write(ordinaryRecord(payload: Data("three".utf8), sequence: 3))
        try store.write(ordinaryRecord(payload: Data("four".utf8), sequence: 4))
        try store.close()

        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2, compressed: true).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(3, compressed: true).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))

        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.sequence) == [2, 3, 4])
        #expect(result.records.map { String(decoding: $0.payload, as: UTF8.self) } == ["two", "three", "four"])
    }

    @Test
    func maximumFileCountOneRetainsOnlyTheActiveRecord() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 1,
                compress: false
            )
        )
        for sequence in 1...3 {
            try store.write(
                ordinaryRecord(payload: Data("record-\(sequence)".utf8), sequence: UInt64(sequence))
            )
        }
        try store.close()

        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [3])
        #expect(result.issues.isEmpty)
    }

    @Test
    func tailStreamAndTimeBoundsAreAppliedDeterministically() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 5,
                compress: false
            )
        )
        for sequence in 1...5 {
            try store.write(
                ordinaryRecord(
                    payload: Data("record-\(sequence)".utf8),
                    stream: sequence.isMultiple(of: 2) ? .stderr : .stdout,
                    timestamp: try ContainerLogTimestamp(
                        secondsSinceUnixEpoch: Int64(sequence),
                        nanoseconds: 0
                    ),
                    sequence: UInt64(sequence)
                )
            )
        }
        try store.close()

        let tail = try store.makeReader().read(
            NativeLocalLogReadRequest(
                stdout: true,
                stderr: false,
                tail: 4,
                since: try ContainerLogTimestamp(secondsSinceUnixEpoch: 2, nanoseconds: 0),
                until: try ContainerLogTimestamp(secondsSinceUnixEpoch: 5, nanoseconds: 0)
            )
        )
        #expect(tail.records.map(\.sequence) == [3, 5])
        #expect(tail.issues.isEmpty)

        var streamed: [UInt64] = []
        let issues = try store.makeReader().forEach(
            NativeLocalLogReadRequest(stdout: false, stderr: true)
        ) { record in
            streamed.append(record.sequence)
        }
        #expect(streamed == [2, 4])
        #expect(issues.isEmpty)
    }

    @Test
    func timeFiltersMatchMobyWhenTimestampsRegress() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for (sequence, seconds) in [1, 3, 2, 6, 4].enumerated() {
            try store.write(
                ordinaryRecord(
                    payload: Data("record-\(sequence + 1)".utf8),
                    timestamp: try ContainerLogTimestamp(
                        secondsSinceUnixEpoch: Int64(seconds),
                        nanoseconds: 0
                    ),
                    sequence: UInt64(sequence + 1)
                )
            )
        }
        try store.close()

        let result = try store.makeReader().read(
            NativeLocalLogReadRequest(
                since: try ContainerLogTimestamp(secondsSinceUnixEpoch: 3, nanoseconds: 0),
                until: try ContainerLogTimestamp(secondsSinceUnixEpoch: 5, nanoseconds: 0)
            )
        )
        #expect(result.records.map(\.sequence) == [2, 3])
        #expect(result.issues.isEmpty)
    }

    @Test
    func readerReportsCRCFailureAndReopenRefusesCorruption() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(ordinaryRecord(payload: Data("protected".utf8), sequence: 1))
        try store.close()

        try mutateByte(
            at: UInt64(NativeLocalLogCodec.fileHeaderSize + NativeLocalLogCodec.framePrefixSize + 12),
            in: fixture.activeURL
        )
        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.isEmpty)
        #expect(result.issues == [.corruptFrame(fileIndex: 0, byteOffset: 16)])
        #expect(throws: NativeLocalLogError.malformedFrame) {
            try NativeLocalLogStore(
                directoryURL: fixture.logDirectory,
                activeFileName: fixture.activeFileName
            )
        }
    }

    @Test
    func truncatedFinalFrameIsReportedAndRecoveredOnReopen() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let first = try ordinaryRecord(payload: Data("first".utf8), sequence: 1)
        let second = try ordinaryRecord(payload: Data("second".utf8), sequence: 2)
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try store.write(first)
        try store.write(second)
        try store.close()

        let fileSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: fixture.activeURL.path)[.size] as? NSNumber)?
                .uint64Value
        )
        let handle = try FileHandle(forWritingTo: fixture.activeURL)
        try handle.truncate(atOffset: fileSize - 7)
        try handle.close()

        let beforeRecovery = try store.makeReader().read(NativeLocalLogReadRequest())
        let secondFrameOffset = UInt64(
            NativeLocalLogCodec.fileHeaderSize + (try NativeLocalLogCodec.encode(first)).count
        )
        #expect(beforeRecovery.records.map(\.sequence) == [1])
        #expect(
            beforeRecovery.issues
                == [
                    .truncatedFinalFrame(
                        fileIndex: 0,
                        byteOffset: secondFrameOffset
                    )
                ]
        )

        let recovered = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        let replacement = try ordinaryRecord(payload: Data("replacement".utf8), sequence: 3)
        try recovered.write(replacement)
        try recovered.close()
        let afterRecovery = try recovered.makeReader().read(NativeLocalLogReadRequest())
        #expect(afterRecovery.records.map(\.sequence) == [1, 3])
        #expect(afterRecovery.issues.isEmpty)
    }

    @Test
    func partialHeaderIsRecoveredButNonHeaderBytesFailClosed() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let first = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try first.close()

        let partialHeader = Data(NativeLocalLogCodec.fileHeader.prefix(7))
        try partialHeader.write(to: fixture.activeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.activeURL.path
        )
        let recovered = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        try recovered.write(ordinaryRecord(payload: Data("recovered".utf8), sequence: 1))
        try recovered.close()
        #expect(
            try recovered.makeReader().read(NativeLocalLogReadRequest()).records.map(\.sequence)
                == [1]
        )

        try Data([0xff, 0x00, 0x01]).write(to: fixture.activeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.activeURL.path
        )
        #expect(throws: NativeLocalLogError.malformedHeader) {
            try NativeLocalLogStore(
                directoryURL: fixture.logDirectory,
                activeFileName: fixture.activeFileName
            )
        }
    }

    @Test
    func failedAppendRollsBackAtomicallyAndUnrecoverableRollbackPoisonsWriter() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let fault = NativeLocalPartialWriteFault()
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(),
            hooks: NativeLocalLogStoreHooks(
                writeEncodedFrame: { data, descriptor in
                    try fault.write(data, to: descriptor)
                }
            )
        )
        #expect(throws: NativeLocalLogError.io(.write, EIO)) {
            try store.write(ordinaryRecord(payload: Data("torn".utf8), sequence: 1))
        }
        #expect(
            try fileSize(fixture.activeURL)
                == UInt64(NativeLocalLogCodec.fileHeaderSize)
        )
        try store.write(ordinaryRecord(payload: Data("complete".utf8), sequence: 2))
        try store.close()
        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [2])
        #expect(result.issues.isEmpty)

        let poisonedFixture = try NativeLocalLogFixture()
        defer { poisonedFixture.remove() }
        let poisoned = try NativeLocalLogStore(
            directoryURL: poisonedFixture.logDirectory,
            activeFileName: poisonedFixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(),
            hooks: NativeLocalLogStoreHooks(
                writeEncodedFrame: { data, descriptor in
                    try NativeLocalPartialWriteFault.writePrefix(
                        data,
                        byteCount: min(11, data.count),
                        to: descriptor
                    )
                    throw NativeLocalLogError.io(.write, EIO)
                },
                rollbackFailedWrite: { _, _ in false }
            )
        )
        #expect(throws: NativeLocalLogError.io(.write, EIO)) {
            try poisoned.write(ordinaryRecord(payload: Data("torn".utf8), sequence: 1))
        }
        #expect(throws: NativeLocalLogError.writePoisoned) {
            try poisoned.write(ordinaryRecord(payload: Data("blocked".utf8), sequence: 2))
        }
        try poisoned.close()
        let fencedRead = try poisoned.makeReader().read(NativeLocalLogReadRequest())
        #expect(fencedRead.records.isEmpty)
        #expect(fencedRead.issues.isEmpty)
    }

    @Test
    func corruptEarlierLengthDoesNotDiscardValidSuffix() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let records = try (1...3).map {
            try ordinaryRecord(payload: Data("record-\($0)".utf8), sequence: UInt64($0))
        }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for record in records {
            try store.write(record)
        }
        try store.close()
        let originalSize = try fileSize(fixture.activeURL)

        let handle = try FileHandle(forUpdating: fixture.activeURL)
        try handle.seek(
            toOffset: UInt64(NativeLocalLogCodec.fileHeaderSize + 4)
        )
        try handle.write(contentsOf: Data([0x00, 0x00, 0x02, 0x00]))
        try handle.close()

        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [2, 3])
        #expect(result.issues == [.corruptFrame(fileIndex: 0, byteOffset: 16)])
        #expect(throws: NativeLocalLogError.malformedFrame) {
            try NativeLocalLogStore(
                directoryURL: fixture.logDirectory,
                activeFileName: fixture.activeFileName
            )
        }
        #expect(try fileSize(fixture.activeURL) == originalSize)
    }

    @Test
    func negativeTailReplaysAllRecordsBeforeMixedStreamFiltering() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        for sequence in 1...4 {
            try store.write(
                ordinaryRecord(
                    payload: Data("record-\(sequence)".utf8),
                    stream: sequence.isMultiple(of: 2) ? .stderr : .stdout,
                    sequence: UInt64(sequence)
                )
            )
        }
        try store.close()

        let result = try store.makeReader().read(
            NativeLocalLogReadRequest(stdout: false, stderr: true, tail: -1)
        )
        #expect(result.records.map(\.sequence) == [2, 4])
        #expect(result.issues.isEmpty)
    }

    @Test
    func rotationFaultAfterActiveExchangeRecoversWithoutLosingExistingData() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let fault = NativeLocalRotationFault(checkpoint: .activeExchanged)
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: false
            ),
            hooks: NativeLocalLogStoreHooks(
                rotationCheckpoint: { checkpoint in
                    try fault.reach(checkpoint)
                }
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        #expect(throws: NativeLocalLogError.io(.rename, EIO)) {
            try store.write(ordinaryRecord(payload: Data("not-written".utf8), sequence: 2))
        }
        try store.write(ordinaryRecord(payload: Data("third".utf8), sequence: 3))
        try store.close()

        let reopened = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: false
            )
        )
        try reopened.close()
        let result = try reopened.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [1, 3])
        #expect(result.issues.isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.logDirectory.path)
                .allSatisfy { !$0.contains(".rotate.") }
        )
    }

    @Test
    func startupCompletesCrashInterruptedActiveExchangeTransaction() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let configuration = try NativeLocalLogConfiguration(
            maximumFileSize: 1,
            maximumFileCount: 3,
            compress: false
        )
        let original = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try original.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try original.close()

        let identifier = UUID().uuidString
        let prefix = "\(fixture.activeURL.path).rotate.\(identifier)."
        let replacement = URL(fileURLWithPath: "\(prefix)replacement")
        let marker = URL(fileURLWithPath: "\(prefix)phase-prepared")
        try NativeLocalLogCodec.fileHeader.write(to: replacement)
        try Data().write(to: marker)
        for url in [replacement, marker] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        try exchangeFiles(replacement, fixture.activeURL)

        let recovered = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try recovered.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try recovered.close()
        let result = try recovered.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [1, 2])
        #expect(result.issues.isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.logDirectory.path)
                .allSatisfy { !$0.contains(".rotate.") }
        )
    }

    @Test
    func corruptGzipDoesNotHideNewerActiveRecords() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(ordinaryRecord(payload: Data("old".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("new".utf8), sequence: 2))
        try store.close()
        try mutateByte(at: 12, in: fixture.rotationURL(1, compressed: true))

        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [2])
        #expect(result.issues == [.corruptCompressedFile(fileIndex: 1)])
    }

    @Test
    func decodedStoredAndRecordBudgetsFailClosed() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(ordinaryRecord(payload: Data(repeating: 0x41, count: 1_024), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("active".utf8), sequence: 2))
        try store.close()
        let reader = try store.makeReader()

        #expect(throws: NativeLocalLogError.storageLimitExceeded) {
            try reader.read(
                NativeLocalLogReadRequest(
                    maximumDecodedBytes: 256,
                    maximumStoredBytes: 1_024 * 1_024
                )
            )
        }
        #expect(throws: NativeLocalLogError.storageLimitExceeded) {
            try reader.read(
                NativeLocalLogReadRequest(
                    maximumDecodedBytes: 1_024 * 1_024,
                    maximumStoredBytes: 8
                )
            )
        }
        #expect(throws: NativeLocalLogError.storageLimitExceeded) {
            try reader.read(
                NativeLocalLogReadRequest(
                    maximumDecodedBytes: 1_024 * 1_024,
                    maximumStoredBytes: 1_024 * 1_024,
                    maximumRecords: 1
                )
            )
        }
        let boundedTail = try reader.read(
            NativeLocalLogReadRequest(
                tail: 1,
                maximumDecodedBytes: 256,
                maximumStoredBytes: 256,
                maximumRecords: 1
            )
        )
        #expect(boundedTail.records.map(\.sequence) == [2])
    }

    @Test
    func forgedGzipSizeCannotBypassDecodeBound() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            )
        )
        try store.write(ordinaryRecord(payload: Data(repeating: 0x41, count: 4_096), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("active".utf8), sequence: 2))
        try store.close()

        let compressed = fixture.rotationURL(1, compressed: true)
        let compressedSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? NSNumber)?
                .uint64Value
        )
        let handle = try FileHandle(forUpdating: compressed)
        try handle.seek(toOffset: compressedSize - 4)
        try handle.write(contentsOf: Data(repeating: 0, count: 4))
        try handle.close()

        #expect(throws: NativeLocalLogError.storageLimitExceeded) {
            try store.makeReader().read(
                NativeLocalLogReadRequest(
                    maximumDecodedBytes: 256,
                    maximumStoredBytes: 1_024 * 1_024
                )
            )
        }
    }

    @Test
    func duplicateSuffixPrefersUncompressedAndLowerRetentionRemovesDebris() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let original = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 4,
                compress: false
            )
        )
        for sequence in 1...4 {
            try original.write(
                ordinaryRecord(payload: Data("record-\(sequence)".utf8), sequence: UInt64(sequence))
            )
        }
        try original.close()

        let duplicate = fixture.rotationURL(1, compressed: true)
        try Data("intentionally-not-gzip".utf8).write(to: duplicate)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: duplicate.path
        )
        let beforeCleanup = try original.makeReader().read(NativeLocalLogReadRequest())
        #expect(beforeCleanup.records.map(\.sequence) == [1, 2, 3, 4])
        #expect(beforeCleanup.issues.isEmpty)

        let reduced = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: false
            )
        )
        try reduced.close()

        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(2).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(3).path))
        let afterCleanup = try reduced.makeReader().read(NativeLocalLogReadRequest())
        #expect(afterCleanup.records.map(\.sequence) == [3, 4])
        #expect(afterCleanup.issues.isEmpty)
    }

    @Test
    func suffixParsingAndCompressionTemporaryReconciliationAreCanonical() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let configuration = try NativeLocalLogConfiguration(
            maximumFileSize: 1,
            maximumFileCount: 50_000,
            compress: false
        )
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try store.close()

        let invalidSuffixes = ["01", "+1", "1.GZ", "999999999999999999999999999999"]
        for suffix in invalidSuffixes {
            let url = URL(fileURLWithPath: "\(fixture.activeURL.path).\(suffix)")
            try Data("not-a-local-log".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let temporary = URL(
            fileURLWithPath: "\(fixture.rotationURL(1).path).gz.tmp.\(UUID().uuidString)"
        )
        try Data("incomplete-gzip".utf8).write(to: temporary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )

        let reopened = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: configuration
        )
        try reopened.close()
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        let result = try reopened.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [1, 2])
        #expect(result.issues.isEmpty)
        for suffix in invalidSuffixes {
            #expect(
                FileManager.default.fileExists(
                    atPath: "\(fixture.activeURL.path).\(suffix)"
                )
            )
        }
    }

    @Test
    func liveSnapshotPinsInodesAndCompletedBoundaryAcrossRotation() async throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let snapshotGate = NativeLocalBlockingTestGate()
        let writeCalls = NativeLocalTestCallCounter()
        defer { snapshotGate.release() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: false
            ),
            hooks: NativeLocalLogStoreHooks(
                didEnumerateSnapshot: { snapshotGate.block() },
                writeWillAcquireCoordinatorLock: { writeCalls.increment() }
            )
        )
        let first = try ordinaryRecord(payload: Data("first".utf8), sequence: 1)
        let second = try ordinaryRecord(payload: Data("second".utf8), sequence: 2)
        try store.write(first)
        let reader = try store.makeReader()

        let readTask = Task.detached {
            try reader.read(NativeLocalLogReadRequest())
        }
        try snapshotGate.waitUntilEntered()
        let writeTask = Task.detached {
            try store.write(second)
        }
        try writeCalls.waitUntilCount(2)
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        snapshotGate.release()

        let snapshot = try await readTask.value
        try await writeTask.value
        #expect(snapshot.records.map(\.sequence) == [1])
        #expect(snapshot.issues.isEmpty)

        try store.close()
        let current = try reader.read(NativeLocalLogReadRequest())
        #expect(current.records.map(\.sequence) == [1, 2])
        #expect(current.issues.isEmpty)
    }

    @Test
    func asyncCompressionFailureIsInspectableAndRetainsSafeRotations() throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            ),
            hooks: NativeLocalLogStoreHooks(
                compressionWillStart: {
                    throw NativeLocalLogError.io(.read, EIO)
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
                == NativeLocalLogCompressionFailure(
                    stage: .preparation,
                    error: .io(.read, EIO)
                )
        )
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [1, 2, 3])
        #expect(result.issues.isEmpty)
    }

    @Test
    func asyncCompressionStartsAfterReplacementActiveAndFencesNextRotation() async throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let compressionGate = NativeLocalBlockingTestGate()
        let compressionWaits = NativeLocalTestCallCounter()
        defer { compressionGate.release() }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 3,
                compress: true
            ),
            hooks: NativeLocalLogStoreHooks(
                compressionWillStart: { compressionGate.block() },
                compressionWaitDidBegin: { compressionWaits.increment() }
            )
        )
        let first = try ordinaryRecord(payload: Data("first".utf8), sequence: 1)
        let second = try ordinaryRecord(payload: Data("second".utf8), sequence: 2)
        let third = try ordinaryRecord(payload: Data("third".utf8), sequence: 3)
        try store.write(first)
        try store.write(second)
        try compressionGate.waitUntilEntered()

        let duringCompression = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(duringCompression.records.map(\.sequence) == [1, 2])
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))

        let writeTask = Task.detached {
            try store.write(third)
        }
        try compressionWaits.waitUntilCount(1)
        compressionGate.release()
        try await writeTask.value
        try store.close()

        let result = try store.makeReader().read(NativeLocalLogReadRequest())
        #expect(result.records.map(\.sequence) == [1, 2, 3])
        #expect(result.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(1, compressed: true).path))
        #expect(FileManager.default.fileExists(atPath: fixture.rotationURL(2, compressed: true).path))
    }

    @Test
    func pinnedReaderSurvivesConcurrentGzipPublicationAndSourceUnlink() async throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let compressionGate = NativeLocalBlockingTestGate()
        let readerGate = NativeLocalBlockingTestGate()
        defer {
            compressionGate.release()
            readerGate.release()
        }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName,
            configuration: try NativeLocalLogConfiguration(
                maximumFileSize: 1,
                maximumFileCount: 2,
                compress: true
            ),
            hooks: NativeLocalLogStoreHooks(
                pinnedSnapshotWillRead: { readerGate.block() },
                compressionWillStart: { compressionGate.block() }
            )
        )
        try store.write(ordinaryRecord(payload: Data("first".utf8), sequence: 1))
        try store.write(ordinaryRecord(payload: Data("second".utf8), sequence: 2))
        try compressionGate.waitUntilEntered()

        let reader = try store.makeReader()
        let readTask = Task.detached {
            try reader.read(NativeLocalLogReadRequest())
        }
        try readerGate.waitUntilEntered()
        compressionGate.release()

        let compressedPath = fixture.rotationURL(1, compressed: true).path
        let sourcePath = fixture.rotationURL(1).path
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline,
            !FileManager.default.fileExists(atPath: compressedPath)
                || FileManager.default.fileExists(atPath: sourcePath)
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: compressedPath))
        #expect(!FileManager.default.fileExists(atPath: sourcePath))
        readerGate.release()

        let result = try await readTask.value
        try store.close()
        #expect(result.records.map(\.sequence) == [1, 2])
        #expect(result.issues.isEmpty)
    }

    @Test
    func concurrentReadWriteAndCloseLeaveOnlyCompleteFrames() async throws {
        let fixture = try NativeLocalLogFixture()
        defer { fixture.remove() }
        let records = try (1...500).map { sequence in
            try ordinaryRecord(
                payload: Data("record-\(sequence)".utf8),
                sequence: UInt64(sequence)
            )
        }
        let store = try NativeLocalLogStore(
            directoryURL: fixture.logDirectory,
            activeFileName: fixture.activeFileName
        )
        let reader = try store.makeReader()

        let writerTask = Task { () -> NativeLocalLogError? in
            for record in records {
                do {
                    try store.write(record)
                } catch let error as NativeLocalLogError {
                    return error
                } catch {
                    return .unsafeStorage
                }
                await Task.yield()
            }
            return nil
        }
        let readerTask = Task { () -> NativeLocalLogError? in
            for _ in 0..<100 {
                do {
                    _ = try reader.read(
                        NativeLocalLogReadRequest(
                            tail: 8,
                            maximumDecodedBytes: 64 * 1024,
                            maximumStoredBytes: 64 * 1024,
                            maximumRecords: 8
                        )
                    )
                } catch let error as NativeLocalLogError {
                    return error
                } catch {
                    return .unsafeStorage
                }
                await Task.yield()
            }
            return nil
        }

        try await Task.sleep(for: .milliseconds(1))
        try store.close()
        let writerError = await writerTask.value
        let readerError = await readerTask.value
        #expect(writerError == nil || writerError == .closed)
        #expect(readerError == nil)

        let final = try reader.read(NativeLocalLogReadRequest())
        #expect(final.issues.isEmpty)
        #expect(
            final.records.map(\.sequence)
                == (1...final.records.count).map(UInt64.init)
        )
    }

    private func ordinaryRecord(
        payload: Data,
        stream: ContainerLogStream = .stdout,
        timestamp: ContainerLogTimestamp? = nil,
        sequence: UInt64,
        attributes: [String: String] = [:],
        processGeneration: UInt64 = 1
    ) throws -> ContainerLogRecordV2 {
        let timestamp = try timestamp ?? ContainerLogTimestamp(secondsSinceUnixEpoch: 0, nanoseconds: 0)
        return try #require(
            splitRecords(
                payload + Data([UInt8(ascii: "\n")]),
                maximumRecordBytes: ContainerLogRecordSplitterV1.defaultMaximumRecordBytes,
                stream: stream,
                timestamp: timestamp,
                firstSequence: sequence,
                attributes: attributes,
                processGeneration: processGeneration
            ).first
        )
    }

    private func splitRecords(
        _ data: Data,
        maximumRecordBytes: Int,
        stream: ContainerLogStream,
        timestamp: ContainerLogTimestamp,
        firstSequence: UInt64,
        attributes: [String: String],
        processGeneration: UInt64
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
                        processGeneration: processGeneration
                    )
                )
            }
        )
        return records
    }

    private func mutateByte(at offset: UInt64, in url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let original = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([original ^ 0xff]))
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        try #require(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .uint64Value
        )
    }

    private func exchangeFiles(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPointer in
            second.path.withCString { secondPointer in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    firstPointer,
                    AT_FDCWD,
                    secondPointer,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw NativeLocalLogError.io(.rename, errno)
        }
    }
}

private struct PersistedRecord: Equatable {
    let stream: ContainerLogStream
    let timestamp: ContainerLogTimestamp
    let payload: Data
    let partial: ContainerLogPartialMetadataV1?
    let sequence: UInt64
    let attributes: [String: String]
    let processGeneration: UInt64

    init(_ record: ContainerLogRecordV2) {
        stream = record.stream
        timestamp = record.observation.wallClock
        payload = record.payload
        partial = record.partial
        sequence = record.sequence
        attributes = record.attributes
        processGeneration = record.processGeneration
    }
}

private final class NativeLocalPartialWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failNextWrite = true

    func write(_ data: Data, to descriptor: Int32) throws {
        lock.lock()
        let shouldFail = failNextWrite
        failNextWrite = false
        lock.unlock()

        let byteCount = shouldFail ? min(17, data.count) : data.count
        try Self.writePrefix(data, byteCount: byteCount, to: descriptor)
        if shouldFail {
            throw NativeLocalLogError.io(.write, EIO)
        }
    }

    static func writePrefix(_ data: Data, byteCount: Int, to descriptor: Int32) throws {
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
                    throw NativeLocalLogError.io(.write, result < 0 ? errno : EIO)
                }
                written += result
            }
        }
    }
}

private final class NativeLocalRotationFault: @unchecked Sendable {
    private let checkpoint: NativeLocalLogRotationCheckpoint
    private let lock = NSLock()
    private var pending = true

    init(checkpoint: NativeLocalLogRotationCheckpoint) {
        self.checkpoint = checkpoint
    }

    func reach(_ observed: NativeLocalLogRotationCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard pending, matches(observed) else {
            return
        }
        pending = false
        throw NativeLocalLogError.io(.rename, EIO)
    }

    private func matches(_ observed: NativeLocalLogRotationCheckpoint) -> Bool {
        switch (checkpoint, observed) {
        case (.replacementSynchronized, .replacementSynchronized),
            (.activeExchanged, .activeExchanged),
            (.rotationsStaged, .rotationsStaged),
            (.rotationsPublished, .rotationsPublished):
            true
        default:
            false
        }
    }
}

private enum NativeLocalStoreTestError: Error {
    case timeout
}

private final class NativeLocalBlockingTestGate: @unchecked Sendable {
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
                throw NativeLocalStoreTestError.timeout
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

private final class NativeLocalTestCallCounter: @unchecked Sendable {
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
                throw NativeLocalStoreTestError.timeout
            }
        }
    }
}

private final class NativeLocalLogFixture {
    let root: URL
    let logDirectory: URL
    let activeFileName = "container-local.log"

    var activeURL: URL {
        logDirectory.appendingPathComponent(activeFileName)
    }

    init(createLogDirectory: Bool = false) throws {
        let temporaryRootPath = FileManager.default.temporaryDirectory.path
        let canonicalPointer = temporaryRootPath.withCString { Darwin.realpath($0, nil) }
        let canonicalPath = try #require(canonicalPointer.map { String(cString: $0) })
        free(canonicalPointer)
        let temporaryRoot = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        root = temporaryRoot.appendingPathComponent("container-local-log-tests-\(UUID().uuidString)")
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
