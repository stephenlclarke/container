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

extension ContainersService {
    /// Creates a stream handle that replays structured records and follows rotations.
    static func followLogRecordFile(
        for url: URL,
        options: ContainerLogOptions,
        pollInterval: Duration = .milliseconds(250),
        isLive: @escaping @Sendable () async -> Bool
    ) throws -> FileHandle {
        try RotatingLogRecordFollower(
            url: url,
            options: options,
            pollInterval: pollInterval,
            isLive: isLive
        ).stream()
    }
}

/// Streams a structured record file while detecting rename-based rotations.
private struct RotatingLogRecordFollower: Sendable {
    private let url: URL
    private let options: ContainerLogOptions
    private let pollInterval: Duration
    private let isLive: @Sendable () async -> Bool

    init(
        url: URL,
        options: ContainerLogOptions,
        pollInterval: Duration,
        isLive: @escaping @Sendable () async -> Bool
    ) {
        self.url = url
        self.options = options
        self.pollInterval = pollInterval
        self.isLive = isLive
    }

    func stream() throws -> FileHandle {
        let cursor = try RotatingLogCursor(url: url)
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let initialData = try cursor.initialReplayData()
        let options = self.options
        let pollInterval = self.pollInterval
        let isLive = self.isLive

        Task {
            var processor = LogRecordFollowProcessor(options: options)
            defer {
                try? writer.close()
                try? cursor.close()
            }

            do {
                try write(processor.initialData(from: initialData), to: writer)
                guard !processor.isFinished else {
                    return
                }
                if await !isLive() {
                    try write(try processor.finishData(flushDecoder: true), to: writer)
                    return
                }

                while !Task.isCancelled {
                    if processor.deadlineElapsed {
                        try write(try processor.finishData(flushDecoder: false), to: writer)
                        return
                    }
                    try write(try processor.followData(from: cursor.readAvailableData()), to: writer)
                    guard !processor.isFinished else {
                        return
                    }
                    if await !isLive() {
                        try write(try processor.finishData(flushDecoder: true), to: writer)
                        return
                    }
                    try await Task.sleep(for: pollInterval)
                }
            } catch {
                try? writer.close()
            }
        }

        return pipe.fileHandleForReading
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        guard !data.isEmpty else {
            return
        }
        try handle.write(contentsOf: data)
    }
}

/// Applies line-based record follow filters while preserving partial lines.
private struct LogRecordFollowProcessor {
    private let options: ContainerLogOptions
    private let encoder = JSONEncoder()
    private var decoder = LogRecordStreamDecoder()
    private var accumulator = StructuredLogLineAccumulator()
    private var finished = false

    init(options: ContainerLogOptions) {
        self.options = options
    }

    var isFinished: Bool {
        finished
    }

    var deadlineElapsed: Bool {
        options.until.map { $0 <= Date() } == true
    }

    mutating func initialData(from data: Data) throws -> Data {
        guard options.tail != 0 else {
            decoder.reset(droppingCurrentLine: data.last != LogByte.lineFeed && !data.isEmpty)
            accumulator.reset()
            finished = deadlineElapsed
            return Data()
        }

        let records = try decoder.append(data)
        let flushPending = deadlineElapsed
        var lines = try filteredLines(from: records, flushPending: flushPending)
        if let tail = options.tail, tail > 0 {
            lines = Array(lines.suffix(tail))
        }
        if flushPending {
            finished = true
        }
        return try encoded(lines)
    }

    mutating func followData(from data: Data) throws -> Data {
        let records = try decoder.append(data)
        return try encoded(filteredLines(from: records, flushPending: false))
    }

    mutating func finishData(flushDecoder: Bool) throws -> Data {
        guard !finished else {
            return Data()
        }

        let records = flushDecoder ? try decoder.flush() : []
        let lines = try filteredLines(from: records, flushPending: true)
        finished = true
        return try encoded(lines)
    }

    private mutating func filteredLines(
        from records: [ContainerLogRecord],
        flushPending: Bool
    ) throws -> [StructuredLogLine] {
        var lines: [StructuredLogLine] = []
        for record in records {
            for line in accumulator.append(record) {
                if let until = options.until, line.timestamp > until {
                    finished = true
                    return lines
                }
                if let since = options.since, line.timestamp < since {
                    continue
                }
                lines.append(line)
            }
        }

        guard flushPending, let line = accumulator.flush() else {
            return lines
        }
        if let until = options.until, line.timestamp > until {
            return lines
        }
        if let since = options.since, line.timestamp < since {
            return lines
        }
        lines.append(line)
        return lines
    }

    private func encoded(_ lines: [StructuredLogLine]) throws -> Data {
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line.record))
            data.append(LogByte.lineFeed)
        }
        return data
    }
}

/// Incrementally decodes newline-delimited structured log records.
private struct LogRecordStreamDecoder {
    private let decoder: JSONDecoder
    private var buffer = Data()
    private var droppingCurrentLine = false

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    mutating func append(_ data: Data) throws -> [ContainerLogRecord] {
        buffer.append(data)
        if droppingCurrentLine {
            guard let newline = buffer.firstIndex(of: LogByte.lineFeed) else {
                buffer.removeAll()
                return []
            }
            buffer.removeSubrange(...newline)
            droppingCurrentLine = false
        }

        var records: [ContainerLogRecord] = []
        var recordStart = buffer.startIndex
        while let newline = buffer[recordStart...].firstIndex(of: LogByte.lineFeed) {
            let line = buffer[recordStart..<newline]
            recordStart = buffer.index(after: newline)
            guard !line.isEmpty else {
                continue
            }
            records.append(try decoder.decode(ContainerLogRecord.self, from: Data(line)))
        }
        if recordStart > buffer.startIndex {
            buffer.removeSubrange(..<recordStart)
        }
        return records
    }

    mutating func flush() throws -> [ContainerLogRecord] {
        guard !buffer.isEmpty else {
            return []
        }
        let data = buffer
        buffer.removeAll()
        return [try decoder.decode(ContainerLogRecord.self, from: data)]
    }

    mutating func reset(droppingCurrentLine: Bool = false) {
        buffer.removeAll()
        self.droppingCurrentLine = droppingCurrentLine
    }
}

/// One logical log line reconstructed from structured runtime chunks.
private struct StructuredLogLine {
    var timestamp: Date
    var stream: ContainerLogRecord.Stream
    var data: Data
    var terminated: Bool

    var record: ContainerLogRecord {
        var recordData = data
        if terminated {
            recordData.append(LogByte.lineFeed)
        }
        return ContainerLogRecord(timestamp: timestamp, stream: stream, data: recordData)
    }
}

/// Rebuilds logical lines while carrying partial-line state across rotations.
private struct StructuredLogLineAccumulator {
    private var pending = Data()
    private var pendingTimestamp: Date?
    private var pendingStream: ContainerLogRecord.Stream?

    mutating func append(_ record: ContainerLogRecord) -> [StructuredLogLine] {
        guard !record.data.isEmpty else {
            return []
        }

        var lines: [StructuredLogLine] = []
        var index = record.data.startIndex
        while index < record.data.endIndex {
            let byte = record.data[index]
            if byte == LogByte.lineFeed {
                lines.append(completeLine(record: record, terminated: true))
                index = record.data.index(after: index)
            } else if byte == LogByte.carriageReturn {
                lines.append(completeLine(record: record, terminated: true))
                let next = record.data.index(after: index)
                if next < record.data.endIndex, record.data[next] == LogByte.lineFeed {
                    index = record.data.index(after: next)
                } else {
                    index = next
                }
            } else {
                if pendingTimestamp == nil {
                    pendingTimestamp = record.timestamp
                    pendingStream = record.stream
                }
                pending.append(byte)
                index = record.data.index(after: index)
            }
        }
        return lines
    }

    mutating func flush() -> StructuredLogLine? {
        guard !pending.isEmpty,
            let timestamp = pendingTimestamp,
            let stream = pendingStream
        else {
            return nil
        }
        let line = StructuredLogLine(timestamp: timestamp, stream: stream, data: pending, terminated: false)
        reset()
        return line
    }

    mutating func reset() {
        pending.removeAll()
        pendingTimestamp = nil
        pendingStream = nil
    }

    private mutating func completeLine(record: ContainerLogRecord, terminated: Bool) -> StructuredLogLine {
        let line = StructuredLogLine(
            timestamp: pendingTimestamp ?? record.timestamp,
            stream: pendingStream ?? record.stream,
            data: pending,
            terminated: terminated
        )
        reset()
        return line
    }
}

private enum LogByte {
    static let carriageReturn = UInt8(ascii: "\r")
    static let lineFeed = UInt8(ascii: "\n")
}
