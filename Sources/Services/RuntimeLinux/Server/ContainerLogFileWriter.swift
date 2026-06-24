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
import Foundation

/// Writes raw container logs and timestamped sidecar records.
final class ContainerLogFileWriter: @unchecked Sendable {
    private var rawLog: FileHandle
    private var recordLog: FileHandle
    private let rawLogURL: URL?
    private let recordLogURL: URL?
    private let maxSizeInBytes: UInt64?
    private let maxFileCount: Int
    private let dateProvider: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var rawLogSize: UInt64
    private var recordLogSize: UInt64
    private var openStreamWriterCount = 0
    private var closed = false

    init(
        rawLog: FileHandle,
        recordLog: FileHandle,
        rawLogURL: URL? = nil,
        recordLogURL: URL? = nil,
        maxSizeInBytes: UInt64? = nil,
        maxFileCount: Int? = nil,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rawLog = rawLog
        self.recordLog = recordLog
        self.rawLogURL = rawLogURL
        self.recordLogURL = recordLogURL
        self.maxSizeInBytes = maxSizeInBytes
        self.maxFileCount = max(maxFileCount ?? 1, 1)
        self.dateProvider = dateProvider
        self.rawLogSize = 0
        self.recordLogSize = 0

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    convenience init(
        rawLogURL: URL,
        recordLogURL: URL,
        maxSizeInBytes: UInt64? = nil,
        maxFileCount: Int? = nil,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let rawLog = try Self.openLogFile(rawLogURL)
        let recordLog = try Self.openLogFile(recordLogURL)
        self.init(
            rawLog: rawLog.handle,
            recordLog: recordLog.handle,
            rawLogURL: rawLogURL,
            recordLogURL: recordLogURL,
            maxSizeInBytes: maxSizeInBytes,
            maxFileCount: maxFileCount,
            dateProvider: dateProvider
        )
        self.rawLogSize = rawLog.size
        self.recordLogSize = recordLog.size
    }

    /// Returns a writer for a single container output stream.
    func writer(for stream: ContainerLogRecord.Stream) -> ContainerLogStreamWriter {
        registerStreamWriter()
        return ContainerLogStreamWriter(log: self, stream: stream)
    }

    fileprivate func write(_ data: Data, stream: ContainerLogRecord.Stream) throws {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !closed else {
            return
        }

        let record = ContainerLogRecord(
            timestamp: dateProvider(),
            stream: stream,
            data: data
        )
        var encoded = try encoder.encode(record)
        encoded.append(LogByte.lineFeed)

        try rotateIfNeeded(rawBytes: UInt64(data.count), recordBytes: UInt64(encoded.count))
        try rawLog.write(contentsOf: data)
        try recordLog.write(contentsOf: encoded)
        rawLogSize += UInt64(data.count)
        recordLogSize += UInt64(encoded.count)
    }

    fileprivate func close() throws {
        var closeError: (any Error)?

        lock.lock()
        if !closed {
            closed = true
            do {
                try rawLog.close()
            } catch {
                closeError = error
            }
            do {
                try recordLog.close()
            } catch {
                closeError = closeError ?? error
            }
        }
        lock.unlock()

        if let closeError {
            throw closeError
        }
    }

    fileprivate func closeStreamWriter() throws {
        var shouldClose = false

        lock.lock()
        if openStreamWriterCount > 0 {
            openStreamWriterCount -= 1
            shouldClose = openStreamWriterCount == 0
        } else {
            shouldClose = !closed
        }
        lock.unlock()

        if shouldClose {
            try close()
        }
    }

    private func registerStreamWriter() {
        lock.lock()
        if !closed {
            openStreamWriterCount += 1
        }
        lock.unlock()
    }

    private func rotateIfNeeded(rawBytes: UInt64, recordBytes: UInt64) throws {
        guard let maxSizeInBytes,
            maxSizeInBytes > 0,
            let rawLogURL,
            let recordLogURL
        else {
            return
        }

        let rawWouldExceed = rawLogSize > 0 && rawLogSize + rawBytes > maxSizeInBytes
        let recordWouldExceed = recordLogSize > 0 && recordLogSize + recordBytes > maxSizeInBytes
        guard rawWouldExceed || recordWouldExceed else {
            return
        }

        try rawLog.close()
        try recordLog.close()
        try Self.rotateLogFile(rawLogURL, maxFileCount: maxFileCount)
        try Self.rotateLogFile(recordLogURL, maxFileCount: maxFileCount)

        let rawLog = try Self.openLogFile(rawLogURL)
        let recordLog = try Self.openLogFile(recordLogURL)
        self.rawLog = rawLog.handle
        self.recordLog = recordLog.handle
        self.rawLogSize = rawLog.size
        self.recordLogSize = recordLog.size
    }

    private static func openLogFile(_ url: URL) throws -> (handle: FileHandle, size: UInt64) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        return (handle, size)
    }

    private static func rotateLogFile(_ url: URL, maxFileCount: Int) throws {
        let fileManager = FileManager.default
        if maxFileCount <= 1 {
            try? fileManager.removeItem(at: url)
            fileManager.createFile(atPath: url.path, contents: nil)
            return
        }

        let rotatedCount = maxFileCount - 1
        try? fileManager.removeItem(at: rotatedLogURL(for: url, index: rotatedCount))
        if rotatedCount > 1 {
            for index in stride(from: rotatedCount - 1, through: 1, by: -1) {
                let source = rotatedLogURL(for: url, index: index)
                let destination = rotatedLogURL(for: url, index: index + 1)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: rotatedLogURL(for: url, index: 1))
        }
        fileManager.createFile(atPath: url.path, contents: nil)
    }

    static func rotatedLogURL(for url: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(url.path).\(index)")
    }
}

/// Adapts a stream-specific log file writer to the containerization writer API.
final class ContainerLogStreamWriter: Writer, @unchecked Sendable {
    private static let maxBufferedRecordBytes = 16 * 1024

    private let log: ContainerLogFileWriter
    private let stream: ContainerLogRecord.Stream
    private let lock = NSLock()
    private var pending = Data()
    private var closed = false

    init(log: ContainerLogFileWriter, stream: ContainerLogRecord.Stream) {
        self.log = log
        self.stream = stream
    }

    func close() throws {
        let finalRecord: Data?
        var closeError: (any Error)?

        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        if pending.isEmpty {
            finalRecord = nil
        } else {
            finalRecord = pending
            pending.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        if let finalRecord {
            do {
                try log.write(finalRecord, stream: stream)
            } catch {
                closeError = error
            }
        }
        do {
            try log.closeStreamWriter()
        } catch {
            closeError = closeError ?? error
        }
        if let closeError {
            throw closeError
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }

        pending.append(data)
        let records = drainCompleteRecords()
        do {
            for record in records {
                try log.write(record, stream: stream)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func drainCompleteRecords() -> [Data] {
        var records: [Data] = []
        var recordStart = pending.startIndex

        while recordStart < pending.endIndex {
            let maxRecordEnd =
                pending.index(
                    recordStart,
                    offsetBy: Self.maxBufferedRecordBytes,
                    limitedBy: pending.endIndex
                ) ?? pending.endIndex

            if let lineFeedIndex = pending[recordStart..<maxRecordEnd].firstIndex(of: LogByte.lineFeed) {
                let recordEnd = pending.index(after: lineFeedIndex)
                records.append(Data(pending[recordStart..<recordEnd]))
                recordStart = recordEnd
                continue
            }

            guard pending.distance(from: recordStart, to: pending.endIndex) >= Self.maxBufferedRecordBytes else {
                break
            }
            records.append(Data(pending[recordStart..<maxRecordEnd]))
            recordStart = maxRecordEnd
        }

        if recordStart > pending.startIndex {
            pending.removeSubrange(..<recordStart)
        }

        return records
    }
}

private enum LogByte {
    static let lineFeed = UInt8(ascii: "\n")
}
