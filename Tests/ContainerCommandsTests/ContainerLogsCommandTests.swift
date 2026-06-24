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
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerLogsCommandTests {
    @Test
    func tailDataPreservesBlankLinesAndTrailingNewline() {
        let input = Data("one\n\ntwo\n".utf8)

        let output = LogFileOutput.tailData(input, lineCount: 2)

        #expect(String(data: output, encoding: .utf8) == "\ntwo\n")
    }

    @Test
    func tailDataReturnsAllDataWhenLineCountExceedsInput() {
        let input = Data("one\n\ntwo\n".utf8)

        let output = LogFileOutput.tailData(input, lineCount: 5)

        #expect(output == input)
    }

    @Test
    func tailDataReturnsEmptyDataForZeroLines() {
        let input = Data("one\n\ntwo\n".utf8)

        let output = LogFileOutput.tailData(input, lineCount: 0)

        #expect(output.isEmpty)
    }

    @Test
    func tailDataPreservesBytesForNegativeLineCount() {
        let input = Data([0xff, 0xfe, 0x0a, 0x41])

        let output = LogFileOutput.tailData(input, lineCount: -1)

        #expect(output == input)
    }

    @Test
    func tailDataPreservesUnterminatedFinalLine() {
        let input = Data("one\ntwo".utf8)

        let output = LogFileOutput.tailData(input, lineCount: 1)

        #expect(String(data: output, encoding: .utf8) == "two")
    }

    @Test
    func logFileOutputWritesAllBytes() async throws {
        let input = Data([0xff, 0xfe, 0x0a, 0x41])
        let inputHandle = try fileHandle(containing: input)
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogFileOutput.write(
            fh: inputHandle,
            n: nil,
            follow: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(try Data(contentsOf: outputURL) == input)
    }

    @Test
    func logFileOutputWritesTailWithoutDroppingBlankLines() async throws {
        let inputHandle = try fileHandle(containing: Data("one\n\ntwo\n".utf8))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogFileOutput.write(
            fh: inputHandle,
            n: 2,
            follow: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "\ntwo\n")
    }

    @Test
    func logFileOutputNegativeTailWritesExistingBytesBeforeFollow() async throws {
        let input = Data([0xff, 0xfe, 0x0a, 0x41])
        let inputHandle = try fileHandle(containing: input)
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogFileOutput.write(
            fh: inputHandle,
            n: -1,
            follow: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(try Data(contentsOf: outputURL) == input)
    }

    @Test
    func logFileOutputWritesAlreadyFollowedStream() async throws {
        let pipe = Pipe()
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        async let writeTask: Void = LogFileOutput.writeStream(
            fh: pipe.fileHandleForReading,
            output: outputHandle
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("one\ntwo\n".utf8))
        try pipe.fileHandleForWriting.close()
        try await writeTask
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "one\ntwo\n")
    }

    @Test
    func parsesRFC3339Timestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(timestamp.date == date("2026-06-18T10:00:00Z"))
    }

    @Test
    func parsesFractionalRFC3339Timestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00.123Z"))

        #expect(timestamp.date == date("2026-06-18T10:00:00.123Z"))
    }

    @Test
    func parsesUnixTimestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "1781776800"))

        #expect(timestamp.date == Date(timeIntervalSince1970: 1_781_776_800))
    }

    @Test
    func parsesFractionalUnixTimestamp() throws {
        let timestamp = try #require(ContainerLogTimestamp(argument: "1781776800.25"))

        #expect(timestamp.date == Date(timeIntervalSince1970: 1_781_776_800.25))
    }

    @Test
    func parsesRelativeDurationTimestamp() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)

        let timestamp = try #require(ContainerLogTimestampParser.parse("1m30s", relativeTo: reference))

        #expect(timestamp == reference.addingTimeInterval(-90))
    }

    @Test
    func rejectsInvalidTimestamp() {
        #expect(ContainerLogTimestamp(argument: "not-a-date") == nil)
        #expect(ContainerLogTimestamp(argument: "-1781776800") == nil)
        #expect(ContainerLogTimestamp(argument: ".25") == nil)
        #expect(ContainerLogTimestamp(argument: "1781776800.") == nil)
        #expect(ContainerLogTimestamp(argument: "1781776800.1234567890") == nil)
    }

    @Test
    func logOptionsUseAPITailWhenNotFollowing() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))
        let until = try #require(ContainerLogTimestamp(argument: "2026-06-18T11:00:00Z"))

        let options = Application.ContainerLogs.retrievalOptions(
            numLines: 25,
            follow: false,
            since: since,
            until: until
        )

        #expect(options.tail == 25)
        #expect(options.since == since.date)
        #expect(options.until == until.date)
        #expect(Application.ContainerLogs.replayOptions(follow: false).includeRotated)
    }

    @Test
    func logOptionsLeaveTailForLocalFollowHandling() {
        let options = Application.ContainerLogs.retrievalOptions(
            numLines: 25,
            follow: true,
            since: nil,
            until: nil
        )

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(!Application.ContainerLogs.replayOptions(follow: true).includeRotated)
    }

    @Test
    func staticReplayOptionsIncludeRotatedLogs() {
        let options = Application.ContainerLogs.staticReplayOptions()

        #expect(options.includeRotated)
    }

    @Test
    func validateAcceptsFollowWithSince() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        try Application.ContainerLogs.validateLogOptions(
            boot: false,
            follow: true,
            since: since,
            until: nil,
            timestamps: false
        )
    }

    @Test
    func validateAcceptsFollowWithUntil() throws {
        let until = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        try Application.ContainerLogs.validateLogOptions(
            boot: false,
            follow: true,
            since: nil,
            until: until,
            timestamps: false
        )
    }

    @Test
    func validateRejectsBootWithTimestamps() {
        #expect(throws: Error.self) {
            try Application.ContainerLogs.validateLogOptions(
                boot: true,
                follow: false,
                since: nil,
                until: nil,
                timestamps: true
            )
        }
    }

    @Test
    func validateAcceptsFollowWithTimestamps() throws {
        try Application.ContainerLogs.validateLogOptions(
            boot: false,
            follow: true,
            since: nil,
            until: nil,
            timestamps: true
        )
    }

    @Test
    func validateRejectsBootWithFollowedTimeFilters() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(throws: Error.self) {
            try Application.ContainerLogs.validateLogOptions(
                boot: true,
                follow: true,
                since: since,
                until: nil,
                timestamps: false
            )
        }
    }

    @Test
    func validateAcceptsFollowWithTailOnly() throws {
        try Application.ContainerLogs.validateLogOptions(
            boot: false,
            follow: true,
            since: nil,
            until: nil,
            timestamps: false
        )
    }

    @Test
    func logsUsesStructuredRecordsForTimeFiltersAndTimestamps() throws {
        let since = try #require(ContainerLogTimestamp(argument: "2026-06-18T10:00:00Z"))
        let until = try #require(ContainerLogTimestamp(argument: "2026-06-18T11:00:00Z"))

        #expect(!Application.ContainerLogs.usesStructuredRecords(follow: false, since: nil, until: nil, timestamps: false))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: false, since: since, until: nil, timestamps: false))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: false, since: nil, until: until, timestamps: false))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: false, since: nil, until: nil, timestamps: true))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: true, since: since, until: nil, timestamps: false))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: true, since: nil, until: until, timestamps: false))
        #expect(Application.ContainerLogs.usesStructuredRecords(follow: true, since: nil, until: nil, timestamps: true))
    }

    @Test
    func timestampedLogOutputRendersSplitRecordsAndBlankLines() throws {
        let first = date("2026-06-18T10:00:00Z")
        let second = date("2026-06-18T10:00:01Z")
        let output = LogRecordOutput.renderedData(
            records: [
                ContainerLogRecord(timestamp: first, stream: .stdout, data: Data("one\npa".utf8)),
                ContainerLogRecord(timestamp: second, stream: .stderr, data: Data("rt\n\n".utf8)),
            ],
            n: nil
        )

        let expected =
            [
                "2026-06-18T10:00:00.000Z one",
                "2026-06-18T10:00:00.000Z part",
                "2026-06-18T10:00:01.000Z" + " ",
            ].joined(separator: "\n") + "\n"
        #expect(String(data: output, encoding: .utf8) == expected)
    }

    @Test
    func timestampedLogOutputAppliesTailAfterLineSplitting() throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let output = LogRecordOutput.renderedData(
            records: [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\ntwo\nthree\n".utf8))
            ],
            n: 2
        )

        #expect(
            String(data: output, encoding: .utf8) == """
                2026-06-18T10:00:00.000Z two
                2026-06-18T10:00:00.000Z three

                """)
    }

    @Test
    func timestampedLogOutputFiltersSplitLinesByLogicalLineTimestamp() throws {
        let before = date("2026-06-18T10:00:00Z")
        let since = date("2026-06-18T10:00:01Z")
        let until = date("2026-06-18T10:00:02Z")
        let after = date("2026-06-18T10:00:03Z")
        let output = LogRecordOutput.renderedData(
            records: [
                ContainerLogRecord(timestamp: before, stream: .stdout, data: Data("old".utf8)),
                ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("-line\ninside".utf8)),
                ContainerLogRecord(timestamp: until, stream: .stdout, data: Data("-line\nclosing".utf8)),
                ContainerLogRecord(timestamp: after, stream: .stdout, data: Data("-line\n".utf8)),
            ],
            n: nil,
            since: since,
            until: until,
            timestamps: false
        )

        #expect(String(data: output, encoding: .utf8) == "inside-line\nclosing-line\n")
    }

    @Test
    func timestampedLogOutputPreservesNonUTF8Bytes() throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let output = LogRecordOutput.renderedData(
            records: [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data([0xff, 0xfe, 0x0a]))
            ],
            n: nil
        )

        var expected = Data("2026-06-18T10:00:00.000Z ".utf8)
        expected.append(contentsOf: [0xff, 0xfe, 0x0a])
        #expect(output == expected)
    }

    @Test
    func logRecordOutputFollowsTimestampedRecordFile() async throws {
        let first = date("2026-06-18T10:00:00Z")
        let second = date("2026-06-18T10:00:01Z")
        let pipe = Pipe()
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        async let followTask: Void = LogRecordOutput.write(
            recordFile: pipe.fileHandleForReading,
            n: 0,
            follow: true,
            since: nil,
            until: nil,
            timestamps: true,
            output: outputHandle
        )
        try await Task.sleep(for: .milliseconds(50))
        pipe.fileHandleForWriting.write(
            try logRecordData([
                ContainerLogRecord(timestamp: first, stream: .stdout, data: Data("one\npa".utf8)),
                ContainerLogRecord(timestamp: second, stream: .stderr, data: Data("rt\n".utf8)),
            ]))
        try pipe.fileHandleForWriting.close()
        try await followTask
        try outputHandle.close()

        let expected = """
            2026-06-18T10:00:00.000Z one
            2026-06-18T10:00:00.000Z part

            """
        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == expected)
    }

    @Test
    func logRecordOutputFiltersFollowedRecordFile() async throws {
        let base = date("2100-01-01T00:00:00Z")
        let since = date("2100-01-01T00:00:01Z")
        let until = date("2100-01-01T00:00:02Z")
        let pipe = Pipe()
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        async let followTask: Void = LogRecordOutput.write(
            recordFile: pipe.fileHandleForReading,
            n: 0,
            follow: true,
            since: since,
            until: until,
            timestamps: false,
            output: outputHandle
        )
        try await Task.sleep(for: .milliseconds(50))
        pipe.fileHandleForWriting.write(
            try logRecordData([
                ContainerLogRecord(timestamp: base, stream: .stdout, data: Data("old\n".utf8)),
                ContainerLogRecord(timestamp: since, stream: .stdout, data: Data("inside\n".utf8)),
                ContainerLogRecord(timestamp: until.addingTimeInterval(1), stream: .stdout, data: Data("new\n".utf8)),
            ]))
        try pipe.fileHandleForWriting.close()
        try await followTask
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "inside\n")
    }

    @Test
    func logRecordOutputReplaysExistingRecordFileBeforeFollowing() async throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let recordFile = try fileHandle(
            containing: try logRecordData([
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\ntwo\nthree\n".utf8))
            ]))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: 2,
            follow: false,
            since: nil,
            until: nil,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "two\nthree\n")
    }

    @Test
    func logRecordOutputFollowNegativeTailReplaysExistingRecordFile() async throws {
        let until = Date().addingTimeInterval(-1)
        let recordFile = try fileHandle(
            containing: try logRecordData([
                ContainerLogRecord(timestamp: until.addingTimeInterval(-2), stream: .stdout, data: Data("one\ntwo\n".utf8))
            ]))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: -1,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "one\ntwo\n")
    }

    @Test
    func logRecordOutputReplaysUnterminatedRecordFileWhenNotFollowing() async throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let recordFile = try fileHandle(
            containing: try logRecordData([
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\ntwo".utf8))
            ]))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "one\ntwo")
    }

    @Test
    func logRecordOutputReplaysRecordFileWithoutTrailingJSONNewline() async throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let recordFile = try fileHandle(
            containing: try logRecordData(
                [ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one".utf8))],
                terminatingNewline: false
            ))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: nil,
            follow: false,
            since: nil,
            until: nil,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "one")
    }

    @Test
    func logRecordOutputAppliesTailAfterFlushingUnterminatedRecordFile() async throws {
        let timestamp = date("2026-06-18T10:00:00Z")
        let recordFile = try fileHandle(
            containing: try logRecordData([
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("one\ntwo".utf8))
            ]))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: 1,
            follow: false,
            since: nil,
            until: nil,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "two")
    }

    @Test
    func logRecordOutputFlushesInitialRecordFileWhenFollowUntilAlreadyElapsed() async throws {
        let until = Date().addingTimeInterval(-1)
        let recordFile = try fileHandle(
            containing: try logRecordData([
                ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot".utf8))
            ]))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "snapshot")
    }

    @Test
    func logRecordOutputFlushesUnterminatedJSONRecordWhenFollowUntilAlreadyElapsed() async throws {
        let until = Date().addingTimeInterval(-1)
        let recordFile = try fileHandle(
            containing: try logRecordData(
                [ContainerLogRecord(timestamp: until.addingTimeInterval(-1), stream: .stdout, data: Data("snapshot".utf8))],
                terminatingNewline: false
            ))
        let outputURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)

        try await LogRecordOutput.write(
            recordFile: recordFile,
            n: nil,
            follow: true,
            since: nil,
            until: until,
            timestamps: false,
            output: outputHandle
        )
        try outputHandle.close()

        #expect(String(data: try Data(contentsOf: outputURL), encoding: .utf8) == "snapshot")
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = temporaryFileURL()
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("container-logs-command-\(UUID().uuidString)")
    }

    private func logRecordData(_ records: [ContainerLogRecord], terminatingNewline: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for (index, record) in records.enumerated() {
            data.append(try encoder.encode(record))
            if terminatingNewline || index < records.count - 1 {
                data.append(UInt8(ascii: "\n"))
            }
        }
        return data
    }

}
