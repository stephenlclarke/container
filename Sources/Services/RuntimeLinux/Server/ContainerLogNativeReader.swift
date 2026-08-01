//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
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

package enum ContainerLogNativeReaderFactoryError: Error, Equatable, Sendable {
    case incompleteConfiguration
    case providerReaderRequired(String)
    case invalidTimestamp
    case invalidLegacyConfiguration
    case malformedLegacyRecord
    case legacyStorageLimitExceeded
    case unsafeLegacyStorage
    case legacyIO(Int32)
}

/// Routes one historical-read request to the immutable configured source.
///
/// Stopped-container follow is deliberately suppressed, matching Docker's
/// temporary stopped-reader behavior. Active follow must use the retained
/// generation-fenced live reader rather than reopening a static file snapshot.
package enum ContainerLogNativeReaderFactory {
    package static func makeReader(
        bundle: ContainerResource.Bundle,
        configuration: ContainerConfiguration,
        request: ContainerLogReadRequest,
        source: LoggingReaderSourceV1
    ) throws -> any ContainerLogReader {
        if configuration.logging.isLegacy {
            guard configuration.logging.storage == .local else {
                throw ContainerLogReaderError.configuredDriverDoesNotSupportReading
            }
            try requireStaticRead(source: source, request: request)
            return try bufferedLegacyReader(
                bundle: bundle,
                logging: configuration.logging,
                request: request
            )
        }

        guard let resolved = configuration.logging.resolved else {
            throw ContainerLogNativeReaderFactoryError.incompleteConfiguration
        }
        switch resolved.readPolicy.source {
        case .unavailable:
            throw ContainerLogReaderError.configuredDriverDoesNotSupportReading

        case .legacyLocalV1:
            try requireStaticRead(source: source, request: request)
            return try bufferedLegacyReader(
                bundle: bundle,
                logging: configuration.logging,
                request: request
            )

        case .dualCache:
            try requireStaticRead(source: source, request: request)
            guard let cache = resolved.readPolicy.cache else {
                throw ContainerLogNativeReaderFactoryError.incompleteConfiguration
            }
            _ = try NativeLocalLogConfiguration(
                maximumFileSize: cache.maxSizeInBytes,
                maximumFileCount: cache.maxFileCount,
                compress: cache.compress
            )
            let reader = try NativeLocalLogReader(
                directoryURL: bundle.containerNativeLogCacheDirectory,
                activeFileName: ContainerResource.Bundle.nativeLogCacheName,
                maximumFileCount: cache.maxFileCount
            )
            return try bufferedLocalReader(reader, request: request)

        case .direct:
            switch resolved.driver {
            case "json-file":
                try requireStaticRead(source: source, request: request)
                guard
                    case .jsonFile(let storeConfiguration, _, _) = try ContainerLogRuntimePlan(
                        configuration: configuration
                    )
                else {
                    throw ContainerLogNativeReaderFactoryError.incompleteConfiguration
                }
                let reader = try DockerJSONFileLogReader(
                    directoryURL: bundle.containerJSONFileLogDirectory,
                    activeFileName: ContainerResource.Bundle.jsonFileLogName,
                    maximumFileCount: storeConfiguration.maximumFileCount
                )
                return try bufferedJSONFileReader(reader, request: request)

            case "local":
                try requireStaticRead(source: source, request: request)
                guard
                    case .local(let storeConfiguration, _, _) = try ContainerLogRuntimePlan(
                        configuration: configuration
                    )
                else {
                    throw ContainerLogNativeReaderFactoryError.incompleteConfiguration
                }
                let reader = try NativeLocalLogReader(
                    directoryURL: bundle.containerNativeLocalLogDirectory,
                    activeFileName: ContainerResource.Bundle.nativeLocalLogName,
                    maximumFileCount: storeConfiguration.maximumFileCount
                )
                return try bufferedLocalReader(reader, request: request)

            default:
                throw ContainerLogNativeReaderFactoryError.providerReaderRequired(
                    resolved.driver
                )
            }
        }
    }

    private static func requireStaticRead(
        source: LoggingReaderSourceV1,
        request: ContainerLogReadRequest
    ) throws {
        if case .activeWriter = source, request.follow {
            throw ContainerLogReaderError.activeReaderRequired
        }
    }

    private static func bufferedJSONFileReader(
        _ reader: DockerJSONFileLogReader,
        request: ContainerLogReadRequest
    ) throws -> ContainerLogBufferedReader {
        let result = try reader.read(
            DockerJSONFileLogReadRequest(
                stdout: request.stdout,
                stderr: request.stderr,
                tail: request.tail,
                since: try request.since.map(nativeReaderTimestamp),
                until: try request.until.map(nativeReaderTimestamp)
            )
        )
        let records = try result.records.map { record in
            try ContainerLogReadRecordV1(
                stream: record.stream,
                timestamp: record.timestamp,
                data: record.log,
                attributes: record.attributes,
                sequence: record.storageSequence
            )
        }
        return ContainerLogBufferedReader(records: records)
    }

    private static func bufferedLocalReader(
        _ reader: NativeLocalLogReader,
        request: ContainerLogReadRequest
    ) throws -> ContainerLogBufferedReader {
        let result = try reader.read(
            NativeLocalLogReadRequest(
                stdout: request.stdout,
                stderr: request.stderr,
                tail: request.tail,
                since: try request.since.map(nativeReaderTimestamp),
                until: try request.until.map(nativeReaderTimestamp)
            )
        )
        let records = try result.records.map { record in
            var presentation = record.payload
            if record.partial == nil || record.partial?.last == true {
                presentation.append(UInt8(ascii: "\n"))
            }
            return try ContainerLogReadRecordV1(
                stream: record.stream,
                timestamp: record.observation.wallClock,
                data: presentation,
                attributes: record.attributes,
                sequence: record.sequence,
                processGeneration: record.processGeneration
            )
        }
        return ContainerLogBufferedReader(records: records)
    }

    private static func bufferedLegacyReader(
        bundle: ContainerResource.Bundle,
        logging: ContainerLogConfiguration,
        request: ContainerLogReadRequest
    ) throws -> ContainerLogBufferedReader {
        let reader = try ContainerLegacyLogReader(
            directoryURL: bundle.path,
            activeFileName: bundle.containerLogRecords.lastPathComponent,
            maximumFileCount: logging.maxFileCount ?? 1
        )
        return ContainerLogBufferedReader(records: try reader.read(request))
    }
}

package final class ContainerLogBufferedReader: ContainerLogReader, @unchecked Sendable {
    private let lock = NSLock()
    private let nextCallAdmitted: (@Sendable () async -> Void)?
    private var records: [ContainerLogReadRecordV1]
    private var index = 0
    private var terminalEmitted = false
    private var nextInFlight = false
    private var cancelled = false

    package init(
        records: [ContainerLogReadRecordV1],
        nextCallAdmitted: (@Sendable () async -> Void)? = nil
    ) {
        self.records = records
        self.nextCallAdmitted = nextCallAdmitted
    }

    package func next() async throws -> ContainerLogReaderEventV1 {
        try beginNext()
        defer { finishNext() }

        return try await withTaskCancellationHandler {
            do {
                if let nextCallAdmitted {
                    await nextCallAdmitted()
                }
                try Task.checkCancellation()
                return try lock.withLock {
                    guard !cancelled else {
                        throw ContainerLogReaderError.cancelled
                    }
                    guard !terminalEmitted else {
                        throw ContainerLogReaderError.alreadyEnded
                    }
                    if index < records.count {
                        let record = records[index]
                        index += 1
                        if index >= 1_024, index * 2 >= records.count {
                            records.removeFirst(index)
                            index = 0
                        }
                        return .record(record)
                    }
                    records.removeAll(keepingCapacity: false)
                    index = 0
                    terminalEmitted = true
                    return .endOfStream
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            self.cancelImmediately()
        }
    }

    package func cancel() async {
        cancelImmediately()
    }

    private func beginNext() throws {
        try lock.withLock {
            guard !cancelled else {
                throw ContainerLogReaderError.alreadyEnded
            }
            guard !nextInFlight else {
                throw ContainerLogReaderError.concurrentReadNotSupported
            }
            nextInFlight = true
        }
    }

    private func finishNext() {
        lock.withLock {
            precondition(nextInFlight)
            nextInFlight = false
        }
    }

    private func cancelImmediately() {
        lock.withLock {
            cancelled = true
            records.removeAll(keepingCapacity: false)
            index = 0
        }
    }
}

private final class ContainerLegacyLogReader: @unchecked Sendable {
    private static let maximumDecodedBytes = 128 * 1024 * 1024
    private static let maximumRecords = ContainerLogReadRequest.maximumTail
    private static let maximumFiles = 1_000

    private let directory: ContainerLegacyLogSecureDirectory
    private let activeFileName: String
    private let maximumFileCount: Int

    init(
        directoryURL: URL,
        activeFileName: String,
        maximumFileCount: Int
    ) throws {
        guard
            !activeFileName.isEmpty,
            activeFileName != ".",
            activeFileName != "..",
            !activeFileName.contains("/"),
            !activeFileName.utf8.contains(0),
            (1...Self.maximumFiles).contains(maximumFileCount)
        else {
            throw ContainerLogNativeReaderFactoryError.invalidLegacyConfiguration
        }
        directory = try ContainerLegacyLogSecureDirectory(url: directoryURL)
        self.activeFileName = activeFileName
        self.maximumFileCount = maximumFileCount
    }

    func read(_ request: ContainerLogReadRequest) throws -> [ContainerLogReadRecordV1] {
        if request.tail == 0 || (!request.stdout && !request.stderr) {
            return []
        }

        let decoder = JSONDecoder()
        var remainingBytes = Self.maximumDecodedBytes
        var sequence: UInt64 = 0
        var decodedRecordCount = 0
        var records: [ContainerLogReadRecordV1] = []
        records.reserveCapacity(min(request.tail ?? 256, Self.maximumRecords))

        for fileName in orderedFileNames() {
            guard
                let data = try directory.readFileIfPresent(
                    named: fileName,
                    maximumBytes: remainingBytes
                )
            else {
                continue
            }
            remainingBytes -= data.count
            var recordStart = data.startIndex
            while let lineFeed = data[recordStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let encoded = Data(data[recordStart..<lineFeed])
                if !encoded.isEmpty {
                    guard decodedRecordCount < Self.maximumRecords else {
                        throw ContainerLogNativeReaderFactoryError.legacyStorageLimitExceeded
                    }
                    decodedRecordCount += 1
                    let decoded: ContainerLogRecord
                    do {
                        decoded = try decoder.decode(ContainerLogRecord.self, from: encoded)
                    } catch {
                        throw ContainerLogNativeReaderFactoryError.malformedLegacyRecord
                    }
                    let (nextSequence, overflow) = sequence.addingReportingOverflow(1)
                    guard !overflow else {
                        throw ContainerLogNativeReaderFactoryError.legacyStorageLimitExceeded
                    }
                    sequence = nextSequence
                    if includes(decoded, request: request) {
                        records.append(
                            try ContainerLogReadRecordV1(
                                stream: decoded.stream == .stdout ? .stdout : .stderr,
                                timestamp: try nativeReaderTimestamp(decoded.timestamp),
                                data: decoded.data,
                                sequence: sequence
                            )
                        )
                    }
                }
                recordStart = data.index(after: lineFeed)
            }
            // A final unterminated sidecar value may be a torn append. It is
            // never decoded or exposed.
        }

        if let tail = request.tail, records.count > tail {
            records.removeFirst(records.count - tail)
        }
        return records
    }

    private func orderedFileNames() -> [String] {
        var names: [String] = []
        if maximumFileCount > 1 {
            names.reserveCapacity(maximumFileCount)
            for index in stride(from: maximumFileCount - 1, through: 1, by: -1) {
                names.append("\(activeFileName).\(index)")
            }
        }
        names.append(activeFileName)
        return names
    }

    private func includes(
        _ record: ContainerLogRecord,
        request: ContainerLogReadRequest
    ) -> Bool {
        if record.stream == .stdout, !request.stdout {
            return false
        }
        if record.stream == .stderr, !request.stderr {
            return false
        }
        if let since = request.since, record.timestamp < since {
            return false
        }
        if let until = request.until, record.timestamp > until {
            return false
        }
        return true
    }
}

private func nativeReaderTimestamp(_ date: Date) throws -> ContainerLogTimestamp {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite else {
        throw ContainerLogNativeReaderFactoryError.invalidTimestamp
    }
    let wholeSeconds = interval.rounded(.down)
    guard var seconds = Int64(exactly: wholeSeconds) else {
        throw ContainerLogNativeReaderFactoryError.invalidTimestamp
    }
    let fractional = interval - wholeSeconds
    guard fractional >= 0, fractional < 1 else {
        throw ContainerLogNativeReaderFactoryError.invalidTimestamp
    }
    var nanoseconds = UInt32((fractional * 1_000_000_000).rounded())
    if nanoseconds == 1_000_000_000 {
        let (incremented, overflow) = seconds.addingReportingOverflow(1)
        guard !overflow else {
            throw ContainerLogNativeReaderFactoryError.invalidTimestamp
        }
        seconds = incremented
        nanoseconds = 0
    }
    return try ContainerLogTimestamp(
        secondsSinceUnixEpoch: seconds,
        nanoseconds: nanoseconds
    )
}

private final class ContainerLegacyLogSecureDirectory: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = try Self.openDirectory(url)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func readFileIfPresent(named name: String, maximumBytes: Int) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw ContainerLogNativeReaderFactoryError.legacyStorageLimitExceeded
        }
        let opened = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if opened < 0, errno == ENOENT {
            return nil
        }
        guard opened >= 0 else {
            throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
        }
        defer { Darwin.close(opened) }

        var metadata = stat()
        guard Darwin.fstat(opened, &metadata) == 0 else {
            throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
        }
        try Self.validateRegularFile(metadata)
        guard
            metadata.st_size >= 0,
            metadata.st_size <= off_t(maximumBytes)
        else {
            throw ContainerLogNativeReaderFactoryError.legacyStorageLimitExceeded
        }

        let byteCount = Int(metadata.st_size)
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < byteCount {
                let result = Darwin.pread(
                    opened,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    if result < 0 {
                        throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
                    }
                    throw ContainerLogNativeReaderFactoryError.unsafeLegacyStorage
                }
                offset += result
            }
        }
        return data
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw ContainerLogNativeReaderFactoryError.unsafeLegacyStorage
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({
                $0 != "." && $0 != ".." && !$0.utf8.contains(0) && $0.utf8.count <= 255
            })
        else {
            throw ContainerLogNativeReaderFactoryError.unsafeLegacyStorage
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
        }
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
                }
                Darwin.close(current)
                current = next
            }

            var metadata = stat()
            guard Darwin.fstat(current, &metadata) == 0 else {
                throw ContainerLogNativeReaderFactoryError.legacyIO(errno)
            }
            let permissions = metadata.st_mode & mode_t(0o777)
            guard
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                metadata.st_uid == getuid(),
                permissions & mode_t(0o022) == 0
            else {
                throw ContainerLogNativeReaderFactoryError.unsafeLegacyStorage
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func validateRegularFile(_ metadata: stat) throws {
        let permissions = metadata.st_mode & mode_t(0o777)
        guard
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_uid == getuid(),
            metadata.st_nlink == 1,
            permissions & mode_t(0o022) == 0
        else {
            throw ContainerLogNativeReaderFactoryError.unsafeLegacyStorage
        }
    }
}
