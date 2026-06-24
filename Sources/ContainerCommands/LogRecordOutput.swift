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

/// Writes structured log records as a byte-preserving log stream.
struct LogRecordOutput {
    /// Writes all requested records.
    static func write(
        records: [ContainerLogRecord],
        n: Int?,
        since: Date? = nil,
        until: Date? = nil,
        timestamps: Bool = true,
        output: FileHandle = .standardOutput
    ) throws {
        let data = renderedData(records: records, n: n, since: since, until: until, timestamps: timestamps)
        if !data.isEmpty {
            output.write(data)
        }
    }

    /// Writes existing records from a structured record file and optionally follows it.
    static func write(
        recordFile: FileHandle,
        n: Int?,
        follow: Bool,
        since: Date?,
        until: Date?,
        timestamps: Bool,
        output: FileHandle = .standardOutput
    ) async throws {
        let decoder = LogRecordJSONLDecoder()
        let renderer = LogRecordRenderer(since: since, until: until, timestamps: timestamps)
        let shouldFlushInitial = !follow || until.map { $0 <= Date() } == true
        let shouldFinish = try writeInitialRecordFile(
            recordFile,
            n: n,
            decoder: decoder,
            renderer: renderer,
            flushPending: shouldFlushInitial,
            output: output
        )

        if !follow || shouldFinish || shouldFlushInitial {
            return
        }

        try await followRecordFile(
            recordFile,
            decoder: decoder,
            renderer: renderer,
            until: until,
            output: output
        )
    }

    /// Renders records to bytes, applying `n` after runtime chunks become log lines.
    static func renderedData(
        records: [ContainerLogRecord],
        n: Int?,
        since: Date? = nil,
        until: Date? = nil,
        timestamps: Bool = true
    ) -> Data {
        let renderer = LogRecordRenderer(since: since, until: until, timestamps: timestamps)
        let result = renderer.append(records)
        var lines = result.lines + renderer.flush()
        if let n, n >= 0 {
            if n == 0 {
                return Data()
            }
            lines = Array(lines.suffix(n))
        }

        return renderedData(lines)
    }

    private static func writeInitialRecordFile(
        _ recordFile: FileHandle,
        n: Int?,
        decoder: LogRecordJSONLDecoder,
        renderer: LogRecordRenderer,
        flushPending: Bool,
        output: FileHandle
    ) throws -> Bool {
        guard n != 0 else {
            _ = try? recordFile.seekToEnd()
            return false
        }
        guard let size = try? recordFile.seekToEnd() else {
            return false
        }
        try recordFile.seek(toOffset: 0)
        guard size > 0 else {
            return false
        }
        guard size <= UInt64(Int.max) else {
            return false
        }

        var records = try decoder.append(recordFile.readData(ofLength: Int(size)))
        if flushPending {
            records.append(contentsOf: try decoder.flush())
        }
        let result = renderer.append(records)
        var lines = result.shouldFinish || flushPending ? result.lines + renderer.flush() : result.lines

        if let n, n >= 0 {
            lines = Array(lines.suffix(n))
        }
        output.write(renderedData(lines))
        return result.shouldFinish
    }

    private static func followRecordFile(
        _ recordFile: FileHandle,
        decoder: LogRecordJSONLDecoder,
        renderer: LogRecordRenderer,
        until: Date?,
        output: FileHandle
    ) async throws {
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let coordinator = LogRecordFollowCoordinator(
                recordFile: recordFile,
                decoder: decoder,
                renderer: renderer,
                continuation: continuation
            )
            let deadlineTask = until.map { deadline in
                Task {
                    if let nanoseconds = followDeadlineNanoseconds(until: deadline) {
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                    if !Task.isCancelled {
                        coordinator.finish(flushDecoder: false)
                    }
                }
            }
            continuation.onTermination = { _ in
                deadlineTask?.cancel()
                coordinator.cancel()
            }
            recordFile.readabilityHandler = { handle in
                coordinator.handleAvailableData(from: handle)
            }
        }
        defer {
            recordFile.readabilityHandler = nil
        }

        for try await data in stream {
            output.write(data)
        }
    }

    private static func followDeadlineNanoseconds(until deadline: Date) -> UInt64? {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else {
            return nil
        }
        return UInt64(interval * 1_000_000_000)
    }

    fileprivate static func renderedData(_ lines: [TimestampedLogLine]) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var output = Data()
        for line in lines {
            if line.timestamps {
                output.append(Data("\(formatter.string(from: line.timestamp)) ".utf8))
            }
            output.append(line.data)
            if line.terminated {
                output.append(LogByte.lineFeed)
            }
        }
        return output
    }
}

/// A structured log line rebuilt from one or more runtime chunks.
private struct TimestampedLogLine {
    var timestamp: Date
    var data: Data
    var terminated: Bool
    var timestamps: Bool
}

/// Result from rendering structured records.
private struct LogRecordRenderResult {
    var lines: [TimestampedLogLine]
    var shouldFinish: Bool
}

/// Incrementally renders structured runtime records as log lines.
private final class LogRecordRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let since: Date?
    private let until: Date?
    private let timestamps: Bool
    private var accumulator = TimestampedLogLineAccumulator()

    init(since: Date?, until: Date?, timestamps: Bool) {
        self.since = since
        self.until = until
        self.timestamps = timestamps
    }

    /// Appends records and returns complete lines plus whether an `until` bound ended the stream.
    func append(_ records: [ContainerLogRecord]) -> LogRecordRenderResult {
        lock.lock()
        defer {
            lock.unlock()
        }

        var lines: [TimestampedLogLine] = []
        for record in records {
            let recordLines = accumulator.append(record.data, timestamp: record.timestamp, timestamps: timestamps)
            for line in recordLines {
                if let until, line.timestamp > until {
                    return LogRecordRenderResult(lines: lines, shouldFinish: true)
                }
                if let since, line.timestamp < since {
                    continue
                }
                lines.append(line)
            }
        }
        return LogRecordRenderResult(lines: lines, shouldFinish: false)
    }

    /// Returns the final unterminated structured line, if one exists.
    func flush() -> [TimestampedLogLine] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let line = accumulator.flush(timestamps: timestamps) else {
            return []
        }
        if let until, line.timestamp > until {
            return []
        }
        if let since, line.timestamp < since {
            return []
        }
        return [line]
    }
}

/// Rebuilds complete log lines while retaining the timestamp from the first chunk.
private struct TimestampedLogLineAccumulator {
    private var pending = Data()
    private var pendingTimestamp: Date?

    /// Appends one runtime chunk and returns complete timestamped lines.
    mutating func append(_ output: Data, timestamp: Date, timestamps: Bool) -> [TimestampedLogLine] {
        guard !output.isEmpty else {
            return []
        }

        var lines: [TimestampedLogLine] = []
        var index = output.startIndex
        while index < output.endIndex {
            let byte = output[index]
            if byte == LogByte.lineFeed {
                lines.append(completeLine(timestamp: timestamp, timestamps: timestamps))
                index = output.index(after: index)
            } else if byte == LogByte.carriageReturn {
                lines.append(completeLine(timestamp: timestamp, timestamps: timestamps))
                let next = output.index(after: index)
                if next < output.endIndex, output[next] == LogByte.lineFeed {
                    index = output.index(after: next)
                } else {
                    index = next
                }
            } else {
                if pendingTimestamp == nil {
                    pendingTimestamp = timestamp
                }
                pending.append(byte)
                index = output.index(after: index)
            }
        }
        return lines
    }

    /// Returns the final unterminated line, if one exists.
    mutating func flush(timestamps: Bool) -> TimestampedLogLine? {
        guard !pending.isEmpty, let pendingTimestamp else {
            return nil
        }
        let line = TimestampedLogLine(timestamp: pendingTimestamp, data: pending, terminated: false, timestamps: timestamps)
        pending.removeAll()
        self.pendingTimestamp = nil
        return line
    }

    private mutating func completeLine(timestamp: Date, timestamps: Bool) -> TimestampedLogLine {
        let line = TimestampedLogLine(
            timestamp: pendingTimestamp ?? timestamp,
            data: pending,
            terminated: true,
            timestamps: timestamps
        )
        pending.removeAll()
        pendingTimestamp = nil
        return line
    }
}

/// Coordinates structured log file readability callbacks and deadline completion.
private final class LogRecordFollowCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let recordFile: FileHandle
    private let decoder: LogRecordJSONLDecoder
    private let renderer: LogRecordRenderer
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var finished = false

    init(
        recordFile: FileHandle,
        decoder: LogRecordJSONLDecoder,
        renderer: LogRecordRenderer,
        continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.recordFile = recordFile
        self.decoder = decoder
        self.renderer = renderer
        self.continuation = continuation
    }

    /// Consumes data made available by the followed structured log record file.
    func handleAvailableData(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            do {
                _ = try handle.seekToEnd()
            } catch {
                finish(flushDecoder: true)
            }
            return
        }

        event(for: data).emit(to: continuation)
    }

    /// Finishes the stream, optionally decoding a final unterminated JSONL record.
    func finish(flushDecoder: Bool) {
        finishEvent(flushDecoder: flushDecoder).emit(to: continuation)
    }

    /// Cancels follow callbacks without finishing the already terminated stream.
    func cancel() {
        lock.lock()
        defer {
            lock.unlock()
        }
        finished = true
        recordFile.readabilityHandler = nil
    }

    private func event(for data: Data) -> LogRecordFollowEvent {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !finished else {
            return .none
        }

        do {
            let records = try decoder.append(data)
            let result = renderer.append(records)
            if result.shouldFinish {
                finished = true
                recordFile.readabilityHandler = nil
                return .finish(LogRecordOutput.renderedData(result.lines + renderer.flush()))
            }
            return .yield(LogRecordOutput.renderedData(result.lines))
        } catch {
            finished = true
            recordFile.readabilityHandler = nil
            return .fail(error)
        }
    }

    private func finishEvent(flushDecoder: Bool) -> LogRecordFollowEvent {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !finished else {
            return .none
        }

        do {
            let records = flushDecoder ? try decoder.flush() : []
            let result = renderer.append(records)
            finished = true
            recordFile.readabilityHandler = nil
            return .finish(LogRecordOutput.renderedData(result.lines + renderer.flush()))
        } catch {
            finished = true
            recordFile.readabilityHandler = nil
            return .fail(error)
        }
    }
}

/// Event emitted by the structured log follow coordinator.
private enum LogRecordFollowEvent {
    case yield(Data)
    case finish(Data)
    case fail(any Error)
    case none

    func emit(to continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        switch self {
        case .yield(let data):
            if !data.isEmpty {
                continuation.yield(data)
            }
        case .finish(let data):
            if !data.isEmpty {
                continuation.yield(data)
            }
            continuation.finish()
        case .fail(let error):
            continuation.finish(throwing: error)
        case .none:
            break
        }
    }
}

/// Incrementally decodes newline-delimited structured log records.
private final class LogRecordJSONLDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder: JSONDecoder
    private var buffer = Data()

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Appends a JSONL byte chunk and returns every complete record.
    func append(_ data: Data) throws -> [ContainerLogRecord] {
        lock.lock()
        defer {
            lock.unlock()
        }

        buffer.append(data)
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

    /// Decodes the final unterminated JSONL record, if one exists.
    func flush() throws -> [ContainerLogRecord] {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !buffer.isEmpty else {
            return []
        }
        let data = buffer
        buffer.removeAll()
        return [try decoder.decode(ContainerLogRecord.self, from: data)]
    }
}

private enum LogByte {
    static let carriageReturn = UInt8(ascii: "\r")
    static let lineFeed = UInt8(ascii: "\n")
}
