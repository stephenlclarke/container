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
    /// Creates a stream handle that replays the requested raw log window and follows rotations.
    static func followLogFile(
        for url: URL,
        options: ContainerLogOptions,
        pollInterval: Duration = .milliseconds(250)
    ) throws -> FileHandle {
        try RotatingLogFollower(url: url, options: options, pollInterval: pollInterval).stream()
    }
}

/// Streams a local log file while detecting rename-based rotations.
private struct RotatingLogFollower: Sendable {
    private let url: URL
    private let options: ContainerLogOptions
    private let pollInterval: Duration

    init(url: URL, options: ContainerLogOptions, pollInterval: Duration) {
        self.url = url
        self.options = options
        self.pollInterval = pollInterval
    }

    func stream() throws -> FileHandle {
        let cursor = try RotatingLogCursor(url: url)
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let replayData = try cursor.initialReplayData(options: options)

        Task {
            defer {
                try? writer.close()
                try? cursor.close()
            }

            do {
                try write(replayData, to: writer)
                while !Task.isCancelled {
                    try write(cursor.readAvailableData(), to: writer)
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

/// Maintains a read offset for the active log and reopens it after rotation.
final class RotatingLogCursor: @unchecked Sendable {
    private let url: URL
    private let initialReplayURLs: [URL]
    private var handle: FileHandle
    private var identity: LogFileIdentity?
    private var offset: UInt64

    init(url: URL) throws {
        self.url = url
        self.initialReplayURLs = ContainersService.rotatedLogURLs(for: url)
        self.handle = try FileHandle(forReadingFrom: url)
        self.identity = LogFileIdentity(url: url)
        self.offset = try handle.seekToEnd()
    }

    func initialReplayData(options: ContainerLogOptions) throws -> Data {
        let data = try initialReplayData()
        return ContainersService.filteredLogData(data, options: options)
    }

    /// Returns the retained rotated logs plus the active prefix that existed before following began.
    func initialReplayData() throws -> Data {
        var data = try ContainersService.logData(from: initialReplayURLs)
        try handle.seek(toOffset: 0)
        data.append(try readPrefix(from: handle, byteCount: offset))
        try handle.seek(toOffset: offset)
        return data
    }

    func close() throws {
        try handle.close()
    }

    func readAvailableData() throws -> Data {
        var data = try readCurrentHandle()
        if try activeFileMovedOrTruncated() {
            // A writer can append to the old file after the first read but
            // before this rotation check. Drain it before closing the handle.
            data.append(try readCurrentHandle())
            try reopenActiveFile()
            data.append(try readCurrentHandle())
        }
        return data
    }

    private func readCurrentHandle() throws -> Data {
        try handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        return data
    }

    private func activeFileMovedOrTruncated() throws -> Bool {
        if let currentIdentity = LogFileIdentity(url: url), currentIdentity != identity {
            return true
        }
        guard let size = Self.fileSize(at: url) else {
            return false
        }
        return UInt64(size) < offset
    }

    private func reopenActiveFile() throws {
        try? handle.close()
        handle = try FileHandle(forReadingFrom: url)
        identity = LogFileIdentity(url: url)
        offset = 0
    }

    private func readPrefix(from handle: FileHandle, byteCount: UInt64) throws -> Data {
        var remaining = byteCount
        var data = Data()
        while remaining > 0 {
            let readSize = min(remaining, UInt64(Int.max))
            let chunk = handle.readData(ofLength: Int(readSize))
            guard !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        return data
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return value.uint64Value
    }
}

/// Stable-enough identity for detecting when the active log path points to a new file.
private struct LogFileIdentity: Equatable {
    private let value: String

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let device = attributes[.systemNumber],
            let inode = attributes[.systemFileNumber]
        else {
            return nil
        }
        self.value = "\(device):\(inode)"
    }
}
