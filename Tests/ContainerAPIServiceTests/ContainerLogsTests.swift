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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerXPC
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct ContainerLogsTests {
    @Test func decodesAndFiltersTimestampedLogRecords() throws {
        let first = ContainerLogRecord(
            timestamp: date("2026-01-02T00:00:00Z"),
            stream: .stdout,
            data: Data("first\n".utf8)
        )
        let second = ContainerLogRecord(
            timestamp: date("2026-01-03T00:00:00Z"),
            stream: .stderr,
            data: Data("second\n".utf8)
        )
        let third = ContainerLogRecord(
            timestamp: date("2026-01-04T00:00:00Z"),
            stream: .stdout,
            data: Data("third\n".utf8)
        )
        let options = ContainerLogOptions(
            tail: 1,
            since: date("2026-01-02T12:00:00Z"),
            until: date("2026-01-04T00:00:00Z")
        )

        let records = try ContainersService.filteredLogRecords(
            logRecordData([first, second, third]),
            options: options
        )

        #expect(records == [third])
    }

    @Test func recordTailZeroDropsExistingRecords() {
        let records = [
            ContainerLogRecord(
                timestamp: date("2026-01-02T00:00:00Z"),
                stream: .stdout,
                data: Data("first".utf8)
            ),
            ContainerLogRecord(
                timestamp: date("2026-01-03T00:00:00Z"),
                stream: .stdout,
                data: Data("-line\n".utf8)
            ),
        ]

        let filtered = ContainersService.filteredLogRecords(records, options: ContainerLogOptions(tail: 0))

        #expect(filtered.isEmpty)
    }

    @Test func recordTailFiltersAfterRebuildingLogicalLines() {
        let first = date("2026-01-01T00:00:00Z")
        let second = date("2026-01-02T00:00:00Z")
        let records = [
            ContainerLogRecord(timestamp: first, stream: .stdout, data: Data("one\npa".utf8)),
            ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("rt\ntwo\nthree".utf8)),
            ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("-tail\n".utf8)),
        ]

        let filtered = ContainersService.filteredLogRecords(records, options: ContainerLogOptions(tail: 2))

        #expect(
            filtered == [
                ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("two\n".utf8)),
                ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("three-tail\n".utf8)),
            ])
    }

    @Test func recordTimeFiltersAfterRebuildingLogicalLines() {
        let before = date("2026-01-01T00:00:00Z")
        let inside = date("2026-01-02T00:00:00Z")
        let after = date("2026-01-03T00:00:00Z")
        let records = [
            ContainerLogRecord(timestamp: before, stream: .stdout, data: Data("old".utf8)),
            ContainerLogRecord(timestamp: inside, stream: .stdout, data: Data("-line\ninside".utf8)),
            ContainerLogRecord(timestamp: after, stream: .stdout, data: Data("-line\nnew\n".utf8)),
        ]

        let filtered = ContainersService.filteredLogRecords(
            records,
            options: ContainerLogOptions(since: inside, until: inside)
        )

        #expect(
            filtered == [
                ContainerLogRecord(timestamp: inside, stream: .stdout, data: Data("inside-line\n".utf8))
            ])
    }

    @Test func filtersLogsBySinceUntilAndTail() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z first
            2026-01-03T00:00:00Z second
            2026-01-04T00:00:00Z new

            """
        let options = ContainerLogOptions(
            tail: 1,
            since: date("2026-01-02T00:00:00Z"),
            until: date("2026-01-03T00:00:00Z")
        )

        let data = ContainersService.filteredLogData(Data(content.utf8), options: options)

        #expect(String(data: data, encoding: .utf8) == "2026-01-03T00:00:00Z second\n")
    }

    @Test func preservesUnparseableLinesEmptyLinesAndTrailingNewline() throws {
        let content = """
            2026-01-01T00:00:00Z old
            unparseable

            2026-01-03T00:00:00Z retained

            """
        let options = ContainerLogOptions(
            since: date("2026-01-02T00:00:00Z")
        )

        let data = ContainersService.filteredLogData(Data(content.utf8), options: options)

        #expect(String(data: data, encoding: .utf8) == "unparseable\n\n2026-01-03T00:00:00Z retained\n")
    }

    @Test func tailZeroReturnsEmptyLogData() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: 0))

        #expect(data.isEmpty)
    }

    @Test func negativeTailDoesNotDropLogs() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: -1))

        #expect(String(data: data, encoding: .utf8) == content)
    }

    @Test func nonUTF8LogsCanBeTailedWithoutDecoding() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let data = ContainersService.filteredLogData(bytes, options: ContainerLogOptions(tail: 1))

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func nonUTF8LogsApplyTailWhenOpeningFilteredHandle() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let handle = try fileHandle(containing: bytes)

        let filtered = ContainersService.applyLogOptions(to: handle, options: ContainerLogOptions(tail: 1))
        let data = try #require(try filtered.readToEnd())

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func logRecordTailReturnsNewestRecords() {
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("second\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("third\n".utf8))

        let records = ContainersService.filteredLogRecords(
            [first, second, third],
            options: ContainerLogOptions(tail: 2)
        )

        #expect(records == [second, third])
    }

    @Test func logRecordTailZeroReturnsNoRecords() {
        let record = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))

        let records = ContainersService.filteredLogRecords([record], options: ContainerLogOptions(tail: 0))

        #expect(records.isEmpty)
    }

    @Test func logRecordNegativeTailDoesNotDropRecords() {
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("second\n".utf8))

        let records = ContainersService.filteredLogRecords(
            [first, second],
            options: ContainerLogOptions(tail: -1)
        )

        #expect(records == [first, second])
    }

    @Test func harnessDecodesLogOptions() {
        let message = XPCMessage(route: .containerLogs)
        let since = Date(timeIntervalSince1970: 0)
        let until = Date(timeIntervalSince1970: -1)
        message.set(key: .logTail, value: Int64(0))
        message.set(key: .logSince, value: since)
        message.set(key: .logUntil, value: until)
        message.set(key: .logIncludeRotated, value: true)

        let options = ContainersHarness.logOptions(from: message)
        let replay = ContainersHarness.logReplayOptions(from: message)

        #expect(options.tail == 0)
        #expect(options.since == since)
        #expect(options.until == until)
        #expect(replay.includeRotated)
    }

    @Test func harnessLeavesAbsentLogOptionsUnset() {
        let message = XPCMessage(route: .containerLogs)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(!ContainersHarness.logReplayOptions(from: message).includeRotated)
    }

    @Test func rotatedLogURLsSortOldestToNewestAndIgnoreInvalidSuffixes() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-url-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let activeURL = tempURL.appendingPathComponent("stdio.log")
        let expectedNames = ["stdio.log.10", "stdio.log.2", "stdio.log.1"]
        for name in expectedNames + ["stdio.log", "stdio.log.0", "stdio.log.old", "other.log.3"] {
            _ = FileManager.default.createFile(atPath: tempURL.appendingPathComponent(name).path, contents: nil)
        }
        try FileManager.default.createDirectory(at: tempURL.appendingPathComponent("stdio.log.4"), withIntermediateDirectories: true)

        let urls = ContainersService.rotatedLogURLs(for: activeURL)

        #expect(urls.map(\.lastPathComponent) == expectedNames)
    }

    @Test func staticLogReplayIncludesRotatedFilesInChronologicalOrder() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("newer\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("older\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 2))
        try Data("oldest\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 3))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-log-replay-test")
        let handles = try await service.logs(
            id: id,
            options: .default,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        defer {
            handles.forEach { try? $0.close() }
        }

        let stdio = try #require(try handles[0].readToEnd())
        let boot = try #require(try handles[1].readToEnd())

        #expect(String(data: stdio, encoding: .utf8) == "oldest\nolder\nnewer\nactive\n")
        #expect(String(data: boot, encoding: .utf8) == "boot\n")
    }

    @Test func staticLogReplayAppliesTailAfterCombiningRotatedFiles() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-tail-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("newer\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("older\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 2))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-log-tail-test")
        let handles = try await service.logs(
            id: id,
            options: ContainerLogOptions(tail: 2),
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        defer {
            handles.forEach { try? $0.close() }
        }
        let data = try #require(try handles[0].readToEnd())

        #expect(String(data: data, encoding: .utf8) == "newer\nactive\n")
    }

    @Test func boundedTailRebuildsLineAcrossRotatedFiles() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-bounded-log-tail-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let older = tempURL.appendingPathComponent("stdio.log.1")
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("one\npar".utf8).write(to: older)
        try Data("t\ntwo\n".utf8).write(to: active)

        let data = try ContainersService.tailLogData(from: [older, active], lineCount: 2)

        #expect(String(data: data, encoding: .utf8) == "part\ntwo\n")
    }

    @Test func defaultLogReplayKeepsActiveFileOnly() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-active-log-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("rotated\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-active-log-replay-test")
        let handles = try await service.logs(id: id, options: .default)
        defer {
            handles.forEach { try? $0.close() }
        }
        let data = try #require(try handles[0].readToEnd())

        #expect(String(data: data, encoding: .utf8) == "active\n")
    }

    @Test func followedLogFileReplaysInitialTailAndFollowsRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("one\ntwo\n".utf8).write(to: active)

        let stream = try ContainersService.followLogFile(
            for: active,
            options: ContainerLogOptions(tail: 1),
            pollInterval: .milliseconds(10)
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: Data("two\nthree\nfour\n".utf8))

        try append("three\n", to: active)
        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try Data("four\n".utf8).write(to: active)

        let output = try await outputTask

        #expect(String(data: output, encoding: .utf8) == "two\nthree\nfour\n")
    }

    @Test func followedLogFileTailZeroStartsEmptyBeforeFollowing() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-tail-zero-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("old\n".utf8).write(to: active)

        let stream = try ContainersService.followLogFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10)
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: Data("new\n".utf8))

        try append("new\n", to: active)
        let output = try await outputTask

        #expect(String(data: output, encoding: .utf8) == "new\n")
    }

    @Test func followedLogRecordFileReplaysInitialTailAndFollowsRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("one\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stderr, data: Data("two\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stdout, data: Data("three\n".utf8))
        let fourth = ContainerLogRecord(timestamp: date("2026-01-04T00:00:00Z"), stream: .stdout, data: Data("four\n".utf8))
        try logRecordData([first, second]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 1),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [second, third, fourth]
        async let outputTask = followedData(from: stream, until: recordDataMarker(fourth))

        try append([third], to: active)
        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try logRecordData([fourth]).write(to: active)

        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileTailZeroStartsEmptyBeforeFollowing() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-tail-zero-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        try logRecordData([old]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [new]
        async let outputTask = followedData(from: stream, until: recordDataMarker(new))

        try append([new], to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileTailZeroDropsOpenInitialRecord() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-tail-zero-open-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        let oldData = try logRecordData([old])
        try Data(oldData.dropLast(2)).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: recordDataMarker(new))

        var appended = Data(oldData.suffix(2))
        appended.append(try logRecordData([new]))
        try append(appended, to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == [new])
    }

    @Test func followedLogRecordFileCompletesPartialLineAcrossRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-partial-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let started = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("pa".utf8))
        let completed = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("rt\n".utf8))
        let expectedRecord = ContainerLogRecord(timestamp: started.timestamp, stream: .stdout, data: Data("part\n".utf8))
        try logRecordData([started]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: .default,
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [expectedRecord]
        async let outputTask = followedData(from: stream, until: recordDataMarker(expectedRecord))

        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try logRecordData([completed]).write(to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileFlushesPartialLineWhenContainerStops() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-stop-flush-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let partial = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stderr, data: Data("partial".utf8))
        try logRecordData([partial]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: .default,
            pollInterval: .milliseconds(10),
            isLive: { false }
        )
        defer {
            try? stream.close()
        }
        let expected = [partial]
        let output = try await followedData(from: stream, until: recordDataMarker(partial))

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileAppliesInitialSinceUntilAndTail() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-filter-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let first = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("second\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-04T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        try logRecordData([old, first, second, new]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(
                tail: 1,
                since: first.timestamp,
                until: second.timestamp
            ),
            pollInterval: .milliseconds(10),
            isLive: { false }
        )
        defer {
            try? stream.close()
        }
        let expected = [second]
        let output = try await followedData(from: stream, until: recordDataMarker(second))

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedRawLogsRejectTimeFilters() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-filter-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)

        let service = try service(appRoot: tempURL, logLabel: "container-follow-log-filter-test")

        await #expect(throws: (any Error).self) {
            _ = try await service.followLogs(
                id: id,
                options: ContainerLogOptions(since: date("2026-01-01T00:00:00Z"))
            )
        }
    }

    @Test func staticRecordReplayIncludesRotatedFilesInChronologicalOrder() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-record-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        let oldest = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("oldest\n".utf8))
        let newer = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("newer\n".utf8))
        let active = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("active\n".utf8))
        try logRecordData([active]).write(to: bundle.containerLogRecords)
        try logRecordData([newer]).write(to: rotatedLogURL(for: bundle.containerLogRecords, index: 1))
        try logRecordData([oldest]).write(to: rotatedLogURL(for: bundle.containerLogRecords, index: 2))

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-record-replay-test")
        let records = try await service.logRecords(
            id: id,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )

        #expect(records == [oldest, newer, active])
    }

    @Test func opensTimestampedLogRecordFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-record-file-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(path: containerRoot.appendingPathComponent(id))
        try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
        try bundle.set(configuration: testConfiguration(id: id))
        let records = [
            ContainerLogRecord(
                timestamp: date("2026-01-02T00:00:00Z"),
                stream: .stdout,
                data: Data("first\n".utf8)
            )
        ]
        let expectedData = try logRecordData(records)
        try expectedData.write(to: bundle.containerLogRecords)

        let service = try ContainersService(
            appRoot: tempURL,
            pluginLoader: try pluginLoader(appRoot: tempURL),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "container-log-record-file-test")
        )

        let file = try await service.logRecordFile(id: id)
        defer {
            try? file.close()
        }
        let data = file.readDataToEndOfFile()

        #expect(data == expectedData)
    }

    private func logRecordData(_ records: [ContainerLogRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private func logRecords(from data: Data) throws -> [ContainerLogRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: UInt8(ascii: "\n")).map { line in
            try decoder.decode(ContainerLogRecord.self, from: Data(line))
        }
    }

    private func recordDataMarker(_ record: ContainerLogRecord) -> Data {
        Data("\"data\":\"\(record.data.base64EncodedString())\"".utf8)
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-test-\(UUID().uuidString)")
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private func append(_ value: String, to url: URL) throws {
        try append(Data(value.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func append(_ records: [ContainerLogRecord], to url: URL) throws {
        try append(logRecordData(records), to: url)
    }

    private func followedData(
        from handle: FileHandle,
        until expected: Data,
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            FollowReadState(handle: handle, expected: expected, continuation: continuation)
                .start(timeout: timeout)
        }
    }

    private func createBundle(appRoot: URL, id: String) throws -> ContainerResource.Bundle {
        let containerRoot = appRoot.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(path: containerRoot.appendingPathComponent(id))
        try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
        try bundle.set(configuration: testConfiguration(id: id))
        return bundle
    }

    private func service(appRoot: URL, logLabel: String) throws -> ContainersService {
        try ContainersService(
            appRoot: appRoot,
            pluginLoader: try pluginLoader(appRoot: appRoot),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: logLabel)
        )
    }

    private func rotatedLogURL(for url: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(url.path).\(index)")
    }

    private func testConfiguration(id: String) -> ContainerConfiguration {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    private func pluginLoader(appRoot: URL) throws -> PluginLoader {
        let pluginRoot = appRoot.appendingPathComponent("plugins")
        let runtimeURL = pluginRoot.appendingPathComponent("container-runtime-linux")
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        return try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [pluginRoot],
            pluginFactories: [StaticRuntimePluginFactory()]
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}

private struct FollowReadTimeout: Error, CustomStringConvertible {
    var output: String

    var description: String {
        "timed out waiting for followed log output; observed: \(output)"
    }
}

private final class FollowReadState: @unchecked Sendable {
    private let handle: FileHandle
    private let expected: Data
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var output = Data()
    private var finished = false

    init(
        handle: FileHandle,
        expected: Data,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.handle = handle
        self.expected = expected
        self.continuation = continuation
    }

    func start(timeout: Duration) {
        handle.readabilityHandler = { [self] readableHandle in
            read(from: readableHandle)
        }
        Task { [self] in
            try? await Task.sleep(for: timeout)
            finish(.failure(timeoutError()))
        }
    }

    private func timeoutError() -> FollowReadTimeout {
        lock.lock()
        let data = output
        lock.unlock()
        return FollowReadTimeout(output: String(data: data, encoding: .utf8) ?? "<non-utf8>")
    }

    private func read(from handle: FileHandle) {
        let data = handle.availableData
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if data.isEmpty {
            let result = output
            lock.unlock()
            finish(.success(result))
            return
        }
        output.append(data)
        let matched = output.range(of: expected) != nil
        let result = output
        lock.unlock()
        if matched {
            finish(.success(result))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        handle.readabilityHandler = nil
        lock.unlock()

        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private struct StaticRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux" else {
            return nil
        }
        return Plugin(binaryURL: installURL.appending(path: "bin/container-runtime-linux"), config: runtimeConfig)
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }

    private var runtimeConfig: PluginConfig {
        let servicesConfig = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [PluginConfig.Service(type: .runtime, description: nil)],
            defaultArguments: []
        )
        return PluginConfig(abstract: "runtime", author: nil, servicesConfig: servicesConfig)
    }
}
