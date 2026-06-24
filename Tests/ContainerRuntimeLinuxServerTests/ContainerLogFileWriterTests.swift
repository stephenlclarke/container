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

@testable import ContainerRuntimeLinuxServer

struct ContainerLogFileWriterTests {
    @Test
    func writesRawBytesAndTimestampedRecords() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )

        try writer.writer(for: .stdout).write(Data("out\n".utf8))
        try writer.writer(for: .stderr).write(Data("err\n".utf8))
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == Data("out\nerr\n".utf8))

        let records = try records(from: files.recordURL)
        #expect(
            records == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("out\n".utf8)),
                ContainerLogRecord(timestamp: timestamp, stream: .stderr, data: Data("err\n".utf8)),
            ])
    }

    @Test
    func buffersRecordsUntilLineBoundary() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )
        let stdout = writer.writer(for: .stdout)

        try stdout.write(Data("out".utf8))

        #expect(try Data(contentsOf: files.rawURL).isEmpty)
        #expect(try Data(contentsOf: files.recordURL).isEmpty)

        try stdout.write(Data("\n".utf8))
        try stdout.close()
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == Data("out\n".utf8))
        #expect(
            try records(from: files.recordURL) == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("out\n".utf8))
            ])
    }

    @Test
    func flushesUnterminatedRecordWhenStreamCloses() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )
        let stdout = writer.writer(for: .stdout)

        try stdout.write(Data("partial".utf8))

        #expect(try Data(contentsOf: files.rawURL).isEmpty)
        #expect(try Data(contentsOf: files.recordURL).isEmpty)

        try stdout.close()
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == Data("partial".utf8))
        #expect(
            try records(from: files.recordURL) == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("partial".utf8))
            ])
    }

    @Test
    func chunksLongUnterminatedRecordAtDockerBufferBoundary() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )
        let stdout = writer.writer(for: .stdout)
        let chunkSize = 16 * 1024
        let bytes = Data(repeating: UInt8(ascii: "a"), count: chunkSize + 3)

        try stdout.write(bytes)
        try stdout.close()
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == bytes)
        #expect(
            try records(from: files.recordURL) == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data(bytes.prefix(chunkSize))),
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data(bytes.suffix(3))),
            ])
    }

    @Test
    func preservesNonUTF8BytesInRawOutputAndRecords() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41])
        let stdout = writer.writer(for: .stdout)

        try stdout.write(bytes)
        try stdout.close()
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == bytes)

        let records = try records(from: files.recordURL)
        #expect(
            records == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data([0xff, 0xfe, 0x0a])),
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data([0x41])),
            ])
    }

    @Test
    func preservesFractionalTimestampsInRecords() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let timestamp = try #require(date("2026-06-18T10:00:00.123Z"))
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle,
            dateProvider: { timestamp }
        )

        try writer.writer(for: .stdout).write(Data("out\n".utf8))
        try files.close()

        #expect(
            try records(from: files.recordURL) == [
                ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("out\n".utf8))
            ])
    }

    @Test
    func closingOneStreamWriterKeepsOtherStreamOpen() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle
        )
        let stdout = writer.writer(for: .stdout)
        let stderr = writer.writer(for: .stderr)

        try stdout.write(Data("out\n".utf8))
        try stdout.close()
        try stdout.write(Data("ignored\n".utf8))
        try stderr.write(Data("err\n".utf8))
        try stderr.close()
        try stderr.write(Data("ignored".utf8))

        #expect(try Data(contentsOf: files.rawURL) == Data("out\nerr\n".utf8))
        #expect(try records(from: files.recordURL).map(\.data) == [Data("out\n".utf8), Data("err\n".utf8)])
    }

    @Test
    func closingStreamWriterMoreThanOnceIsSafe() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let writer = ContainerLogFileWriter(
            rawLog: files.rawHandle,
            recordLog: files.recordHandle
        )
        let stdout = writer.writer(for: .stdout)

        try stdout.close()
        try stdout.close()
        try stdout.write(Data("ignored".utf8))

        #expect(try Data(contentsOf: files.rawURL).isEmpty)
        #expect(try Data(contentsOf: files.recordURL).isEmpty)
    }

    @Test
    func rotatesRawBytesAndTimestampedRecords() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        try files.close()
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        let writer = try ContainerLogFileWriter(
            rawLogURL: files.rawURL,
            recordLogURL: files.recordURL,
            maxSizeInBytes: 1,
            maxFileCount: 3,
            dateProvider: { timestamp }
        )

        try writer.writer(for: .stdout).write(Data("one\n".utf8))
        try writer.writer(for: .stdout).write(Data("two\n".utf8))
        try writer.writer(for: .stderr).write(Data("three\n".utf8))
        try writer.writer(for: .stdout).write(Data("four\n".utf8))
        try writer.writer(for: .stdout).close()

        #expect(try Data(contentsOf: files.rawURL) == Data("four\n".utf8))
        #expect(try Data(contentsOf: rotatedURL(files.rawURL, 1)) == Data("three\n".utf8))
        #expect(try Data(contentsOf: rotatedURL(files.rawURL, 2)) == Data("two\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: rotatedURL(files.rawURL, 3).path))

        #expect(try records(from: files.recordURL).map(\.data) == [Data("four\n".utf8)])
        #expect(try records(from: rotatedURL(files.recordURL, 1)).map(\.data) == [Data("three\n".utf8)])
        #expect(try records(from: rotatedURL(files.recordURL, 2)).map(\.data) == [Data("two\n".utf8)])
        #expect(!FileManager.default.fileExists(atPath: rotatedURL(files.recordURL, 3).path))
    }

    @Test
    func rotationCanRetainOnlyActiveLogFiles() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        try files.close()
        let writer = try ContainerLogFileWriter(
            rawLogURL: files.rawURL,
            recordLogURL: files.recordURL,
            maxSizeInBytes: 1,
            maxFileCount: 1
        )

        try writer.writer(for: .stdout).write(Data("one\n".utf8))
        try writer.writer(for: .stdout).write(Data("two\n".utf8))
        try writer.writer(for: .stdout).close()

        #expect(try Data(contentsOf: files.rawURL) == Data("two\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: rotatedURL(files.rawURL, 1).path))
        #expect(try records(from: files.recordURL).map(\.data) == [Data("two\n".utf8)])
        #expect(!FileManager.default.fileExists(atPath: rotatedURL(files.recordURL, 1).path))
    }

    @Test
    func rotationAccountsForExistingActiveLogSizes() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        try files.close()
        let timestamp = try #require(date("2026-06-18T10:00:00Z"))
        try Data("old\n".utf8).write(to: files.rawURL)
        try recordData(
            ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("old\n".utf8))
        ).write(to: files.recordURL)
        let writer = try ContainerLogFileWriter(
            rawLogURL: files.rawURL,
            recordLogURL: files.recordURL,
            maxSizeInBytes: 5,
            maxFileCount: 2,
            dateProvider: { timestamp }
        )

        try writer.writer(for: .stdout).write(Data("new\n".utf8))
        try writer.writer(for: .stdout).close()

        #expect(try Data(contentsOf: files.rawURL) == Data("new\n".utf8))
        #expect(try Data(contentsOf: rotatedURL(files.rawURL, 1)) == Data("old\n".utf8))
        #expect(try records(from: files.recordURL).map(\.data) == [Data("new\n".utf8)])
        #expect(try records(from: rotatedURL(files.recordURL, 1)).map(\.data) == [Data("old\n".utf8)])
    }

    @Test
    func runtimeOmitsLogWriterWhenLogStorageIsNone() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let bundle = ContainerResource.Bundle(path: files.directory)

        let writer = try RuntimeService.containerLogWriter(
            bundle: bundle,
            logging: ContainerLogConfiguration(storage: .none)
        )

        #expect(writer == nil)
    }

    @Test
    func runtimeLogWriterAppliesLocalRotationPolicy() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        try files.close()
        let bundle = ContainerResource.Bundle(path: files.directory)
        let writer = try #require(
            try RuntimeService.containerLogWriter(
                bundle: bundle,
                logging: ContainerLogConfiguration(maxSizeInBytes: 1, maxFileCount: 2)
            ))

        try writer.writer(for: .stdout).write(Data("one\n".utf8))
        try writer.writer(for: .stdout).write(Data("two\n".utf8))
        try writer.writer(for: .stdout).write(Data("three\n".utf8))
        try writer.writer(for: .stdout).close()

        #expect(try Data(contentsOf: files.rawURL) == Data("three\n".utf8))
        #expect(try Data(contentsOf: rotatedURL(files.rawURL, 1)) == Data("two\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: rotatedURL(files.rawURL, 2).path))
    }

    @Test
    func runtimeOutputWriterReturnsNilWithoutStdioOrLogCapture() {
        let writer = RuntimeService.outputWriter(stdio: nil, logWriter: nil)

        #expect(writer == nil)
    }

    @Test
    func runtimeOutputWriterPreservesAttachedStdioWhenLogCaptureIsDisabled() throws {
        let files = try temporaryLogFiles()
        defer { files.remove() }
        let writer = try #require(RuntimeService.outputWriter(stdio: files.rawHandle, logWriter: nil))

        try writer.write(Data("attached\n".utf8))
        try files.close()

        #expect(try Data(contentsOf: files.rawURL) == Data("attached\n".utf8))
        #expect(try Data(contentsOf: files.recordURL).isEmpty)
    }

    private func records(from url: URL) throws -> [ContainerLogRecord] {
        let data = try Data(contentsOf: url)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines.map { line in
            try decoder.decode(ContainerLogRecord.self, from: Data(line.utf8))
        }
    }

    private func recordData(_ record: ContainerLogRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0a)
        return data
    }

    private func temporaryLogFiles() throws -> TemporaryLogFiles {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-file-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("stdio.log")
        let recordURL = directory.appendingPathComponent("stdio.jsonl")
        _ = FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: recordURL.path, contents: nil)
        return TemporaryLogFiles(
            directory: directory,
            rawURL: rawURL,
            recordURL: recordURL,
            rawHandle: try FileHandle(forWritingTo: rawURL),
            recordHandle: try FileHandle(forWritingTo: recordURL)
        )
    }

    private func date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func rotatedURL(_ url: URL, _ index: Int) -> URL {
        ContainerLogFileWriter.rotatedLogURL(for: url, index: index)
    }
}

private struct TemporaryLogFiles {
    let directory: URL
    let rawURL: URL
    let recordURL: URL
    let rawHandle: FileHandle
    let recordHandle: FileHandle

    func close() throws {
        try rawHandle.close()
        try recordHandle.close()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
