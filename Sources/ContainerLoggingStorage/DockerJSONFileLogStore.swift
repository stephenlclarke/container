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

import Compression
import ContainerResource
import Darwin
import Foundation

/// A single-representation canonical Docker json-file writer.
///
/// The supplied directory is a dedicated logging directory. It is created as
/// mode 0700 when absent and opened component-by-component with `O_NOFOLLOW`.
/// Active and rotated files are current-user-owned regular files with one link
/// and Docker's 0640 file mode. The private parent makes group readability
/// non-traversable while preserving the Docker file-mode contract.
package struct DockerJSONFileLogStoreHooks: Sendable {
    package let didEnumerateSnapshot: (@Sendable () -> Void)?
    package let writeWillAcquireCoordinatorLock: (@Sendable () -> Void)?
    package let writeEncodedRecord: (@Sendable (Data, Int32) throws -> Void)?
    package let compressionWillStart: (@Sendable () throws -> Void)?
    package let compressionWaitDidBegin: (@Sendable () -> Void)?
    package let readPinnedSnapshotWillBegin: (@Sendable () -> Void)?

    package init(
        didEnumerateSnapshot: (@Sendable () -> Void)? = nil,
        writeWillAcquireCoordinatorLock: (@Sendable () -> Void)? = nil,
        writeEncodedRecord: (@Sendable (Data, Int32) throws -> Void)? = nil,
        compressionWillStart: (@Sendable () throws -> Void)? = nil,
        compressionWaitDidBegin: (@Sendable () -> Void)? = nil,
        readPinnedSnapshotWillBegin: (@Sendable () -> Void)? = nil
    ) {
        self.didEnumerateSnapshot = didEnumerateSnapshot
        self.writeWillAcquireCoordinatorLock = writeWillAcquireCoordinatorLock
        self.writeEncodedRecord = writeEncodedRecord
        self.compressionWillStart = compressionWillStart
        self.compressionWaitDidBegin = compressionWaitDidBegin
        self.readPinnedSnapshotWillBegin = readPinnedSnapshotWillBegin
    }
}

package enum DockerJSONFileCompressionFailureStage: String, Equatable, Sendable {
    case preparation
    case publication
}

package struct DockerJSONFileCompressionFailure: Equatable, Sendable {
    package let stage: DockerJSONFileCompressionFailureStage
    package let error: DockerJSONFileLogError
}

package struct DockerJSONFileLogStoreSnapshot: Equatable, Sendable {
    package let closed: Bool
    package let writePoisoned: Bool
    package let compressionRunning: Bool
    package let successfulCompressionCount: UInt64
    package let compressionFailureCount: UInt64
    package let lastCompressionFailure: DockerJSONFileCompressionFailure?
}

/// A process-wide admission controller for bounded static json-file reads.
///
/// A read reserves three times its decoded-byte ceiling plus bounded fixed
/// overhead. This conservatively covers directory/pinned-file metadata, the
/// encoded snapshot, decoded bytes, and record/JSON copies that can coexist
/// transiently. The independent slot limit bounds inflate and JSON parsing
/// CPU. Admission is deliberately non-blocking so untrusted API requests cannot
/// accumulate a waiter/thread backlog.
package final class DockerJSONFileReadQuota: @unchecked Sendable {
    private static let reservationMultiplier = 3
    private static let fixedReservationBytes = 2 * 1024 * 1024

    package static let defaultMaximumConcurrentReads = 4
    package static let defaultMaximumReservedBytes =
        defaultMaximumConcurrentReads
        * (DockerJSONFileLogReadRequest.hardMaximumDecodedBytes * reservationMultiplier
            + fixedReservationBytes)
    package static let shared = DockerJSONFileReadQuota(
        validatedMaximumReservedBytes: defaultMaximumReservedBytes,
        validatedMaximumConcurrentReads: defaultMaximumConcurrentReads
    )

    private let lock = NSLock()
    private let maximumReservedBytes: Int
    private let maximumConcurrentReads: Int
    private var reservedBytes = 0
    private var activeReads = 0

    private init(
        validatedMaximumReservedBytes: Int,
        validatedMaximumConcurrentReads: Int
    ) {
        maximumReservedBytes = validatedMaximumReservedBytes
        maximumConcurrentReads = validatedMaximumConcurrentReads
    }

    package convenience init(
        maximumReservedBytes: Int,
        maximumConcurrentReads: Int
    ) throws {
        guard maximumReservedBytes > 0, maximumConcurrentReads > 0 else {
            throw DockerJSONFileLogError.invalidConfiguration
        }
        self.init(
            validatedMaximumReservedBytes: maximumReservedBytes,
            validatedMaximumConcurrentReads: maximumConcurrentReads
        )
    }

    package func acquire(maximumDecodedBytes: Int) throws -> DockerJSONFileReadQuotaLease {
        let (reservation, overflow) = maximumDecodedBytes.multipliedReportingOverflow(
            by: Self.reservationMultiplier
        )
        let (boundedReservation, additionOverflow) = reservation.addingReportingOverflow(
            Self.fixedReservationBytes
        )
        guard !overflow, !additionOverflow, boundedReservation > 0 else {
            throw DockerJSONFileLogError.readQuotaExceeded
        }
        return try lock.withLock {
            guard
                activeReads < maximumConcurrentReads,
                boundedReservation <= maximumReservedBytes - reservedBytes
            else {
                throw DockerJSONFileLogError.readQuotaExceeded
            }
            activeReads += 1
            reservedBytes += boundedReservation
            return DockerJSONFileReadQuotaLease(
                quota: self,
                reservedBytes: boundedReservation
            )
        }
    }

    fileprivate func release(reservation: Int) {
        lock.withLock {
            precondition(activeReads > 0)
            precondition(reservation > 0 && reservation <= reservedBytes)
            activeReads -= 1
            reservedBytes -= reservation
        }
    }
}

package final class DockerJSONFileReadQuotaLease: @unchecked Sendable {
    private let lock = NSLock()
    private var quota: DockerJSONFileReadQuota?
    private let reservedBytes: Int

    fileprivate init(quota: DockerJSONFileReadQuota, reservedBytes: Int) {
        self.quota = quota
        self.reservedBytes = reservedBytes
    }

    deinit {
        release()
    }

    package func release() {
        let quota = lock.withLock {
            defer { self.quota = nil }
            return self.quota
        }
        quota?.release(reservation: reservedBytes)
    }
}

private final class DockerJSONFileLogCoordinator: @unchecked Sendable {
    let writerLock = NSLock()
    let filesystemLock = NSLock()
    let hooks: DockerJSONFileLogStoreHooks
    var activePhysicalSize: UInt64
    var activeCompletedSize: UInt64
    var lastTimestamp: ContainerLogTimestamp?

    private let compressionCondition = NSCondition()
    private var compressionRunning = false
    private var successfulCompressionCount: UInt64 = 0
    private var compressionFailureCount: UInt64 = 0
    private var lastCompressionFailure: DockerJSONFileCompressionFailure?

    init(activeSize: UInt64, hooks: DockerJSONFileLogStoreHooks) {
        activePhysicalSize = activeSize
        activeCompletedSize = activeSize
        self.hooks = hooks
    }

    func beginCompression() {
        compressionCondition.withLock {
            precondition(!compressionRunning)
            compressionRunning = true
        }
    }

    func waitForCompression() {
        compressionCondition.lock()
        while compressionRunning {
            hooks.compressionWaitDidBegin?()
            compressionCondition.wait()
        }
        compressionCondition.unlock()
    }

    func finishCompression(failure: DockerJSONFileCompressionFailure?) {
        compressionCondition.withLock {
            if let failure {
                if compressionFailureCount < .max {
                    compressionFailureCount += 1
                }
                lastCompressionFailure = failure
            } else {
                if successfulCompressionCount < .max {
                    successfulCompressionCount += 1
                }
            }
            compressionRunning = false
            compressionCondition.broadcast()
        }
    }

    func compressionSnapshot() -> (
        running: Bool,
        successCount: UInt64,
        failureCount: UInt64,
        lastFailure: DockerJSONFileCompressionFailure?
    ) {
        compressionCondition.withLock {
            (
                compressionRunning,
                successfulCompressionCount,
                compressionFailureCount,
                lastCompressionFailure
            )
        }
    }
}

package final class DockerJSONFileLogStore: @unchecked Sendable {
    package let logURL: URL

    private let directory: DockerJSONFileSecureDirectory
    private let activeFileName: String
    private let configuration: DockerJSONFileLogConfiguration
    private let coordinator: DockerJSONFileLogCoordinator
    private let compressionQueue = DispatchQueue(label: "com.apple.container.logging.json-file-compression")
    private var descriptor: Int32
    private var closed = false
    private var writePoisoned = false

    package convenience init(
        directoryURL: URL,
        activeFileName: String,
        configuration: DockerJSONFileLogConfiguration
    ) throws {
        try self.init(
            directoryURL: directoryURL,
            activeFileName: activeFileName,
            configuration: configuration,
            hooks: DockerJSONFileLogStoreHooks()
        )
    }

    package init(
        directoryURL: URL,
        activeFileName: String,
        configuration: DockerJSONFileLogConfiguration,
        hooks: DockerJSONFileLogStoreHooks
    ) throws {
        try DockerJSONFileSecureDirectory.validateActiveFileName(activeFileName)
        let directory = try DockerJSONFileSecureDirectory(url: directoryURL, createIfAbsent: true)
        try directory.removeStaleCompressionFiles(activeFileName: activeFileName)
        let opened = try directory.openWritableFile(named: activeFileName)
        self.directory = directory
        self.activeFileName = activeFileName
        self.configuration = configuration
        descriptor = opened.descriptor
        coordinator = DockerJSONFileLogCoordinator(activeSize: opened.size, hooks: hooks)
        logURL = directoryURL.appendingPathComponent(activeFileName, isDirectory: false)
    }

    package convenience init(directoryURL: URL, activeFileName: String) throws {
        try self.init(
            directoryURL: directoryURL,
            activeFileName: activeFileName,
            configuration: try DockerJSONFileLogConfiguration()
        )
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    package func write(_ record: ContainerLogRecordV2) throws {
        let encoded = try DockerJSONFileLogCodec.encode(record)
        coordinator.hooks.writeWillAcquireCoordinatorLock?()
        try coordinator.writerLock.withLock {
            guard !closed else {
                throw DockerJSONFileLogError.closed
            }
            guard !writePoisoned else {
                throw DockerJSONFileLogError.writePoisoned
            }
            if let maximumFileSize = configuration.maximumFileSize,
                coordinator.activePhysicalSize >= maximumFileSize
            {
                try rotate()
            }
            let completedBoundary = coordinator.activeCompletedSize
            let (newSize, overflow) = coordinator.activePhysicalSize.addingReportingOverflow(
                UInt64(encoded.count)
            )
            guard !overflow else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            do {
                if let writeEncodedRecord = coordinator.hooks.writeEncodedRecord {
                    try writeEncodedRecord(encoded, descriptor)
                } else {
                    try DockerJSONFileSystem.writeAll(encoded, to: descriptor)
                }
            } catch {
                rollbackFailedWrite(to: completedBoundary)
                throw error
            }
            coordinator.activePhysicalSize = newSize
            coordinator.activeCompletedSize = newSize
            coordinator.lastTimestamp = record.observation.wallClock
        }
    }

    package func close() throws {
        try coordinator.writerLock.withLock {
            guard !closed else {
                return
            }
            closed = true
            let closingDescriptor = descriptor
            descriptor = -1
            let closeError: DockerJSONFileLogError?
            if closingDescriptor < 0 || Darwin.close(closingDescriptor) == 0 {
                closeError = nil
            } else {
                closeError = .io(.close, errno)
            }
            coordinator.waitForCompression()
            if let closeError {
                throw closeError
            }
        }
    }

    package func makeReader() throws -> DockerJSONFileLogReader {
        try DockerJSONFileLogReader(
            directoryURL: directory.url,
            activeFileName: activeFileName,
            maximumFileCount: configuration.maximumFileCount,
            directory: directory,
            coordinator: coordinator
        )
    }

    package var snapshot: DockerJSONFileLogStoreSnapshot {
        coordinator.writerLock.withLock {
            let compression = coordinator.compressionSnapshot()
            return DockerJSONFileLogStoreSnapshot(
                closed: closed,
                writePoisoned: writePoisoned,
                compressionRunning: compression.running,
                successfulCompressionCount: compression.successCount,
                compressionFailureCount: compression.failureCount,
                lastCompressionFailure: compression.lastFailure
            )
        }
    }

    private func rotate() throws {
        coordinator.waitForCompression()
        let oldDescriptor = descriptor
        descriptor = -1
        guard Darwin.close(oldDescriptor) == 0 else {
            let savedErrno = errno
            try coordinator.filesystemLock.withLock {
                try reopenAfterRotationFailure()
            }
            throw DockerJSONFileLogError.io(.close, savedErrno)
        }

        do {
            try coordinator.filesystemLock.withLock {
                try directory.removeRotationsOutsideRetention(
                    activeFileName: activeFileName,
                    maximumFileCount: configuration.maximumFileCount
                )
                if configuration.maximumFileCount == 1 {
                    try directory.removeFileIfPresent(named: activeFileName)
                } else {
                    try rotateRetainedFiles()
                    try directory.renameFile(
                        from: activeFileName,
                        to: rotationName(index: 1, compressed: false)
                    )
                }
                let opened = try directory.openWritableFile(named: activeFileName)
                descriptor = opened.descriptor
                coordinator.activePhysicalSize = opened.size
                coordinator.activeCompletedSize = opened.size
            }
            if configuration.compress, configuration.maximumFileCount > 1 {
                scheduleCompression(
                    named: rotationName(index: 1, compressed: false),
                    lastTimestamp: coordinator.lastTimestamp
                )
            }
        } catch {
            try? coordinator.filesystemLock.withLock {
                try reopenAfterRotationFailure()
            }
            throw error
        }
    }

    private func rotateRetainedFiles() throws {
        let retained = try directory.rotationFiles(
            activeFileName: activeFileName,
            maximumFileCount: configuration.maximumFileCount
        )
        for file in retained.sorted(by: { $0.index > $1.index }) {
            let alternate = rotationName(index: file.index, compressed: !file.compressed)
            try directory.removeFileIfPresent(named: alternate)
            if file.index >= configuration.maximumFileCount - 1 {
                try directory.removeFileIfPresent(named: file.name)
                continue
            }
            let destination = rotationName(index: file.index + 1, compressed: file.compressed)
            try directory.removeFileIfPresent(named: destination)
            try directory.removeFileIfPresent(
                named: rotationName(index: file.index + 1, compressed: !file.compressed)
            )
            try directory.renameFile(from: file.name, to: destination)
        }
    }

    private func scheduleCompression(
        named sourceName: String,
        lastTimestamp: ContainerLogTimestamp?
    ) {
        coordinator.beginCompression()
        compressionQueue.async { [self] in
            var failure: DockerJSONFileCompressionFailure?
            defer { coordinator.finishCompression(failure: failure) }

            let temporaryName: String
            do {
                try coordinator.hooks.compressionWillStart?()
                temporaryName = try prepareCompression(
                    named: sourceName,
                    lastTimestamp: lastTimestamp
                )
            } catch {
                failure = Self.compressionFailure(stage: .preparation, error: error)
                return
            }
            var published = false
            defer {
                if !published {
                    try? coordinator.filesystemLock.withLock {
                        try directory.removeFileIfPresent(named: temporaryName)
                    }
                }
            }
            do {
                try coordinator.filesystemLock.withLock {
                    let compressedName = "\(sourceName).gz"
                    try directory.renameFile(from: temporaryName, to: compressedName)
                    published = true
                    try directory.removeFileIfPresent(named: sourceName)
                }
            } catch {
                failure = Self.compressionFailure(stage: .publication, error: error)
                return
            }
        }
    }

    private func prepareCompression(
        named sourceName: String,
        lastTimestamp: ContainerLogTimestamp?
    ) throws -> String {
        let compressedName = "\(sourceName).gz"
        let temporaryName = "\(compressedName).tmp.\(UUID().uuidString)"
        let source = try directory.openReadableFile(named: sourceName)
        var destination = try directory.createExclusiveWritableFile(named: temporaryName)
        var prepared = false
        defer {
            Darwin.close(source)
            if destination >= 0 {
                Darwin.close(destination)
            }
            if !prepared {
                try? coordinator.filesystemLock.withLock {
                    try directory.removeFileIfPresent(named: temporaryName)
                }
            }
        }

        try DockerGzip.compress(
            source: source,
            destination: destination,
            lastTimestamp: lastTimestamp
        )
        guard Darwin.fsync(destination) == 0 else {
            throw DockerJSONFileLogError.io(.sync, errno)
        }
        guard Darwin.close(destination) == 0 else {
            throw DockerJSONFileLogError.io(.close, errno)
        }
        destination = -1
        prepared = true
        return temporaryName
    }

    private static func compressionFailure(
        stage: DockerJSONFileCompressionFailureStage,
        error: Error
    ) -> DockerJSONFileCompressionFailure {
        DockerJSONFileCompressionFailure(
            stage: stage,
            error: error as? DockerJSONFileLogError ?? .compressionFailed
        )
    }

    private func reopenAfterRotationFailure() throws {
        guard descriptor < 0 else {
            return
        }
        let opened = try directory.openWritableFile(named: activeFileName)
        descriptor = opened.descriptor
        coordinator.activePhysicalSize = opened.size
        coordinator.activeCompletedSize = opened.size
    }

    private func rollbackFailedWrite(to completedBoundary: UInt64) {
        guard
            descriptor >= 0,
            completedBoundary <= UInt64(off_t.max),
            Darwin.ftruncate(descriptor, off_t(completedBoundary)) == 0,
            Darwin.fsync(descriptor) == 0
        else {
            writePoisoned = true
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            return
        }
        coordinator.activePhysicalSize = completedBoundary
        coordinator.activeCompletedSize = completedBoundary
    }

    private func rotationName(index: Int, compressed: Bool) -> String {
        "\(activeFileName).\(index)\(compressed ? ".gz" : "")"
    }
}

/// A bounded static reader for a native Docker json-file store.
///
/// A malformed complete NDJSON record stops only that file, matching Moby's
/// decoder behavior; reading then continues with a newer rotation. A truncated
/// final record is ignored and reported. Compressed corruption is an explicit
/// read failure because Engine 29.2.1's exact external error path for that case
/// is not yet frozen by the black-box oracle.
package final class DockerJSONFileLogReader: @unchecked Sendable {
    private let directory: DockerJSONFileSecureDirectory
    private let activeFileName: String
    private let maximumFileCount: Int
    private let coordinator: DockerJSONFileLogCoordinator?
    private let readQuota: DockerJSONFileReadQuota
    private let lock = NSLock()

    package init(
        directoryURL: URL,
        activeFileName: String,
        maximumFileCount: Int,
        readQuota: DockerJSONFileReadQuota = .shared
    ) throws {
        try DockerJSONFileSecureDirectory.validateActiveFileName(activeFileName)
        guard maximumFileCount >= 1 else {
            throw DockerJSONFileLogError.invalidConfiguration
        }
        directory = try DockerJSONFileSecureDirectory(url: directoryURL, createIfAbsent: false)
        self.activeFileName = activeFileName
        self.maximumFileCount = maximumFileCount
        self.readQuota = readQuota
        coordinator = nil
    }

    fileprivate init(
        directoryURL: URL,
        activeFileName: String,
        maximumFileCount: Int,
        directory: DockerJSONFileSecureDirectory,
        coordinator: DockerJSONFileLogCoordinator,
        readQuota: DockerJSONFileReadQuota = .shared
    ) throws {
        try DockerJSONFileSecureDirectory.validateActiveFileName(activeFileName)
        guard maximumFileCount >= 1, directory.url == directoryURL else {
            throw DockerJSONFileLogError.invalidConfiguration
        }
        self.directory = directory
        self.activeFileName = activeFileName
        self.maximumFileCount = maximumFileCount
        self.coordinator = coordinator
        self.readQuota = readQuota
    }

    package func read(_ request: DockerJSONFileLogReadRequest) throws -> DockerJSONFileLogReadResult {
        try lock.withLock {
            if request.tail == 0 || (!request.stdout && !request.stderr) {
                return DockerJSONFileLogReadResult(records: [], issues: [])
            }
            let quotaLease = try readQuota.acquire(
                maximumDecodedBytes: request.maximumDecodedBytes
            )

            return try withExtendedLifetime(quotaLease) {
                var remainingBytes = request.maximumDecodedBytes
                let pinned = try pinnedFiles()
                coordinator?.hooks.readPinnedSnapshotWillBegin?()
                let files = try selectedFiles(
                    pinned,
                    request: request,
                    remainingBytes: &remainingBytes
                )
                var issues: [DockerJSONFileLogReadIssue] = []
                var storageSequence: UInt64 = 0
                var allRecords: [DockerJSONFileLogReadRecord] = []
                var tailBuffer = DockerJSONFileTailBuffer<DockerJSONFileLogReadRecord>(capacity: request.tail)

                for (file, data) in files {
                    var recordStart = data.startIndex
                    while let lineFeed = data[recordStart...].firstIndex(of: UInt8(ascii: "\n")) {
                        let encodedLine = Data(data[recordStart..<lineFeed])
                        let offset = UInt64(data.distance(from: data.startIndex, to: recordStart))
                        do {
                            let (nextSequence, overflow) = storageSequence.addingReportingOverflow(1)
                            guard !overflow else {
                                throw DockerJSONFileLogError.storageLimitExceeded
                            }
                            storageSequence = nextSequence
                            let record = try DockerJSONFileLogCodec.decode(
                                encodedLine,
                                storageSequence: storageSequence
                            )
                            if request.tail == nil {
                                guard allRecords.count < request.maximumRecords else {
                                    throw DockerJSONFileLogError.storageLimitExceeded
                                }
                                allRecords.append(record)
                            } else {
                                tailBuffer.append(record)
                            }
                        } catch DockerJSONFileLogError.malformedRecord,
                            DockerJSONFileLogError.malformedTimestamp
                        {
                            issues.append(.malformedRecord(fileIndex: file.index, byteOffset: offset))
                            recordStart = data.endIndex
                            break
                        }
                        recordStart = data.index(after: lineFeed)
                    }
                    if recordStart < data.endIndex {
                        issues.append(.truncatedFinalRecord(fileIndex: file.index))
                    }
                }

                let selected = request.tail == nil ? allRecords : tailBuffer.elements
                return DockerJSONFileLogReadResult(
                    records: applyFilters(selected, request: request),
                    issues: issues
                )
            }
        }
    }

    private func pinnedFiles() throws -> [DockerJSONFilePinnedFile] {
        if let coordinator {
            return try coordinator.writerLock.withLock {
                try coordinator.filesystemLock.withLock {
                    try directory.pinnedFiles(
                        activeFileName: activeFileName,
                        maximumFileCount: maximumFileCount,
                        activeCompletedSize: coordinator.activeCompletedSize,
                        didEnumerate: coordinator.hooks.didEnumerateSnapshot
                    )
                }
            }
        }
        return try directory.pinnedFiles(
            activeFileName: activeFileName,
            maximumFileCount: maximumFileCount,
            activeCompletedSize: nil,
            didEnumerate: nil
        )
    }

    private func selectedFiles(
        _ files: [DockerJSONFilePinnedFile],
        request: DockerJSONFileLogReadRequest,
        remainingBytes: inout Int
    ) throws -> [(DockerJSONFilePinnedFile, Data)] {
        guard var needed = request.tail else {
            return try files.map { file in
                (
                    file,
                    try read(
                        file,
                        since: request.since,
                        remainingBytes: &remainingBytes
                    )
                )
            }
        }

        var newestFirst: [(DockerJSONFilePinnedFile, Data)] = []
        for file in files.reversed() where needed > 0 {
            let data: Data
            if file.compressed {
                data = Self.tailSuffix(
                    try read(
                        file,
                        since: request.since,
                        remainingBytes: &remainingBytes
                    ),
                    lineCount: needed
                )
            } else {
                let suffix = try DockerJSONFileSystem.readTail(
                    from: file.descriptor,
                    fileSize: file.byteCount,
                    lineCount: needed,
                    maximumBytes: remainingBytes
                )
                remainingBytes -= suffix.bytesRead
                data = suffix.data
            }
            newestFirst.append((file, data))
            let completeLines = data.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "\n") {
                    count += 1
                }
            }
            if completeLines >= needed {
                needed = 0
            } else {
                needed -= completeLines
            }
        }
        return Array(newestFirst.reversed())
    }

    private func read(
        _ file: DockerJSONFilePinnedFile,
        since: ContainerLogTimestamp?,
        remainingBytes: inout Int
    ) throws -> Data {
        if file.compressed {
            if let since,
                let lastTimestamp = try DockerGzip.lastTimestamp(
                    source: file.descriptor,
                    byteCount: file.byteCount
                ),
                lastTimestamp < since
            {
                return Data()
            }
            let compressed = try DockerJSONFileSystem.readAll(
                from: file.descriptor,
                byteCount: file.byteCount,
                maximumBytes: remainingBytes
            )
            let decoded = try DockerGzip.decompress(
                compressed,
                maximumDecodedBytes: remainingBytes
            )
            remainingBytes -= decoded.count
            return decoded
        }
        let data = try DockerJSONFileSystem.readAll(
            from: file.descriptor,
            byteCount: file.byteCount,
            maximumBytes: remainingBytes
        )
        remainingBytes -= data.count
        return data
    }

    fileprivate static func tailSuffix(_ data: Data, lineCount: Int) -> Data {
        guard lineCount > 0 else {
            return Data()
        }
        var observedLineFeeds = 0
        var cursor = data.endIndex
        while cursor > data.startIndex {
            cursor = data.index(before: cursor)
            if data[cursor] == UInt8(ascii: "\n") {
                observedLineFeeds += 1
                if observedLineFeeds > lineCount {
                    return Data(data[data.index(after: cursor)...])
                }
            }
        }
        return data
    }

    private func applyFilters(
        _ records: [DockerJSONFileLogReadRecord],
        request: DockerJSONFileLogReadRequest
    ) -> [DockerJSONFileLogReadRecord] {
        var since = request.since
        var filtered: [DockerJSONFileLogReadRecord] = []
        filtered.reserveCapacity(records.count)
        for record in records {
            if let lowerBound = since {
                if record.timestamp < lowerBound {
                    continue
                }
                // Moby disables the since check after the first match because
                // timestamps from concurrent streams need not be monotonic.
                since = nil
            }
            if let until = request.until, record.timestamp > until {
                break
            }
            switch record.stream {
            case .stdout where request.stdout:
                filtered.append(record)
            case .stderr where request.stderr:
                filtered.append(record)
            default:
                continue
            }
        }
        return filtered
    }

}

private struct DockerJSONFileTailBuffer<Element> {
    private let capacity: Int?
    private var storage: [Element?]
    private var nextIndex = 0
    private var count = 0

    init(capacity: Int?) {
        self.capacity = capacity
        storage = capacity.map { Array(repeating: nil, count: $0) } ?? []
    }

    mutating func append(_ element: Element) {
        guard let capacity, capacity > 0 else {
            return
        }
        storage[nextIndex] = element
        nextIndex = (nextIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    var elements: [Element] {
        guard let capacity, capacity > 0, count > 0 else {
            return []
        }
        let start = count == capacity ? nextIndex : 0
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }
}

private struct DockerJSONFileStoredFile: Equatable {
    let name: String
    let index: Int
    let compressed: Bool
}

private final class DockerJSONFilePinnedFile: @unchecked Sendable {
    let storedFile: DockerJSONFileStoredFile
    let descriptor: Int32
    let byteCount: UInt64

    var index: Int { storedFile.index }
    var compressed: Bool { storedFile.compressed }

    init(storedFile: DockerJSONFileStoredFile, descriptor: Int32, byteCount: UInt64) {
        self.storedFile = storedFile
        self.descriptor = descriptor
        self.byteCount = byteCount
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private final class DockerJSONFileSecureDirectory: @unchecked Sendable {
    static let maximumDirectoryEntries = 4_096
    static let fileMode = mode_t(0o640)
    static let directoryMode = mode_t(0o700)

    let url: URL
    private let descriptor: Int32

    init(url: URL, createIfAbsent: Bool) throws {
        descriptor = try Self.openDirectory(url, createIfAbsent: createIfAbsent)
        self.url = url
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func validateActiveFileName(_ name: String) throws {
        guard
            !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.utf8.contains(0),
            name.utf8.count <= 180
        else {
            throw DockerJSONFileLogError.invalidActiveFileName
        }
    }

    func openWritableFile(named name: String) throws -> (descriptor: Int32, size: UInt64) {
        let opened = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                Self.fileMode
            )
        }
        guard opened >= 0 else {
            throw DockerJSONFileLogError.io(.open, errno)
        }
        do {
            let metadata = try validateRegularFile(opened)
            guard Darwin.fchmod(opened, Self.fileMode) == 0 else {
                throw DockerJSONFileLogError.io(.metadata, errno)
            }
            guard metadata.st_size >= 0 else {
                throw DockerJSONFileLogError.unsafeStorage
            }
            let recoveredSize = try DockerJSONFileSystem.recoverCompleteRecordPrefix(
                descriptor: opened,
                fileSize: UInt64(metadata.st_size)
            )
            return (opened, recoveredSize)
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func createExclusiveWritableFile(named name: String) throws -> Int32 {
        let opened = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                Self.fileMode
            )
        }
        guard opened >= 0 else {
            throw DockerJSONFileLogError.io(.open, errno)
        }
        do {
            _ = try validateRegularFile(opened)
            guard Darwin.fchmod(opened, Self.fileMode) == 0 else {
                throw DockerJSONFileLogError.io(.metadata, errno)
            }
            return opened
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func openReadableFile(named name: String) throws -> Int32 {
        let opened = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            throw DockerJSONFileLogError.io(.open, errno)
        }
        do {
            _ = try validateRegularFile(opened)
            return opened
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func fileSize(_ fileDescriptor: Int32) throws -> UInt64 {
        let metadata = try validateRegularFile(fileDescriptor)
        guard metadata.st_size >= 0 else {
            throw DockerJSONFileLogError.unsafeStorage
        }
        return UInt64(metadata.st_size)
    }

    func fileExists(named name: String) throws -> Bool {
        switch try metadata(named: name) {
        case .none:
            return false
        case .some(let metadata):
            try validateRegularMetadata(metadata)
            return true
        }
    }

    func removeFileIfPresent(named name: String) throws {
        guard let metadata = try metadata(named: name) else {
            return
        }
        try validateRegularMetadata(metadata)
        let result = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
        guard result == 0 else {
            throw DockerJSONFileLogError.io(.remove, errno)
        }
    }

    func renameFile(from source: String, to destination: String) throws {
        guard let sourceMetadata = try metadata(named: source) else {
            throw DockerJSONFileLogError.io(.rename, ENOENT)
        }
        try validateRegularMetadata(sourceMetadata)
        if let destinationMetadata = try metadata(named: destination) {
            try validateRegularMetadata(destinationMetadata)
        }
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameat(descriptor, sourcePointer, descriptor, destinationPointer)
            }
        }
        guard result == 0 else {
            throw DockerJSONFileLogError.io(.rename, errno)
        }
    }

    func rotationFiles(
        activeFileName: String,
        maximumFileCount: Int
    ) throws -> [DockerJSONFileStoredFile] {
        let names = try entryNames()
        var byIndex: [Int: DockerJSONFileStoredFile] = [:]
        for name in names {
            guard let parsed = Self.parseRotationName(name, activeFileName: activeFileName) else {
                continue
            }
            guard parsed.index < maximumFileCount else {
                continue
            }
            let candidate = DockerJSONFileStoredFile(
                name: name,
                index: parsed.index,
                compressed: parsed.compressed
            )
            if let existing = byIndex[parsed.index] {
                // Moby readers prefer the uncompressed file while gzip
                // publication is in flight.
                if existing.compressed && !candidate.compressed {
                    byIndex[parsed.index] = candidate
                }
            } else {
                byIndex[parsed.index] = candidate
            }
        }
        return Array(byIndex.values)
    }

    func pinnedFiles(
        activeFileName: String,
        maximumFileCount: Int,
        activeCompletedSize: UInt64?,
        didEnumerate: (@Sendable () -> Void)?
    ) throws -> [DockerJSONFilePinnedFile] {
        var files = try rotationFiles(
            activeFileName: activeFileName,
            maximumFileCount: maximumFileCount
        )
        files.sort { $0.index > $1.index }
        if try fileExists(named: activeFileName) {
            files.append(
                DockerJSONFileStoredFile(name: activeFileName, index: 0, compressed: false)
            )
        }
        didEnumerate?()

        var pinned: [DockerJSONFilePinnedFile] = []
        pinned.reserveCapacity(files.count)
        do {
            for file in files {
                let fileDescriptor = try openReadableFile(named: file.name)
                do {
                    let observedSize = try fileSize(fileDescriptor)
                    let byteCount: UInt64
                    if file.index == 0, let activeCompletedSize {
                        guard observedSize >= activeCompletedSize else {
                            throw DockerJSONFileLogError.unsafeStorage
                        }
                        byteCount = activeCompletedSize
                    } else {
                        byteCount = observedSize
                    }
                    pinned.append(
                        DockerJSONFilePinnedFile(
                            storedFile: file,
                            descriptor: fileDescriptor,
                            byteCount: byteCount
                        )
                    )
                } catch {
                    Darwin.close(fileDescriptor)
                    throw error
                }
            }
            return pinned
        } catch {
            pinned.removeAll()
            throw error
        }
    }

    func removeStaleCompressionFiles(activeFileName: String) throws {
        let prefix = "\(activeFileName).1.gz.tmp."
        for name in try entryNames() where name.hasPrefix(prefix) {
            let identifier = String(name.dropFirst(prefix.count))
            guard UUID(uuidString: identifier) != nil else {
                continue
            }
            try removeFileIfPresent(named: name)
        }
    }

    func removeRotationsOutsideRetention(
        activeFileName: String,
        maximumFileCount: Int
    ) throws {
        for name in try entryNames() {
            guard
                let parsed = Self.parseRotationName(
                    name,
                    activeFileName: activeFileName
                ),
                parsed.index >= maximumFileCount
            else {
                continue
            }
            try removeFileIfPresent(named: name)
        }
    }

    private func entryNames() throws -> [String] {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else {
            throw DockerJSONFileLogError.io(.enumerate, errno)
        }
        guard let directory = fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            throw DockerJSONFileLogError.io(.enumerate, savedErrno)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw DockerJSONFileLogError.io(.enumerate, errno)
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            guard names.count < Self.maximumDirectoryEntries else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            names.append(name)
        }
        return names
    }

    private func metadata(named name: String) throws -> stat? {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            return metadata
        }
        if errno == ENOENT {
            return nil
        }
        throw DockerJSONFileLogError.io(.metadata, errno)
    }

    private func validateRegularFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw DockerJSONFileLogError.io(.metadata, errno)
        }
        try validateRegularMetadata(metadata)
        return metadata
    }

    private func validateRegularMetadata(_ metadata: stat) throws {
        let permissions = metadata.st_mode & mode_t(0o777)
        guard
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            metadata.st_uid == getuid(),
            metadata.st_nlink == 1,
            permissions & mode_t(0o027) == 0
        else {
            throw DockerJSONFileLogError.unsafeStorage
        }
    }

    private static func openDirectory(_ url: URL, createIfAbsent: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DockerJSONFileLogError.unsafeStorage
        }
        let canonicalPath = DarwinSystemDirectoryAlias.canonicalPath(for: url.path)
        let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({
                $0 != "." && $0 != ".." && !$0.utf8.contains(0) && $0.utf8.count <= 255
            })
        else {
            throw DockerJSONFileLogError.unsafeStorage
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            throw DockerJSONFileLogError.io(.open, errno)
        }
        do {
            for (index, component) in components.enumerated() {
                let isLast = index == components.count - 1
                var next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                if next < 0, errno == ENOENT, isLast, createIfAbsent {
                    let created = component.withCString {
                        Darwin.mkdirat(current, $0, Self.directoryMode)
                    }
                    guard created == 0 || errno == EEXIST else {
                        throw DockerJSONFileLogError.io(.createDirectory, errno)
                    }
                    next = component.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                }
                guard next >= 0 else {
                    throw DockerJSONFileLogError.io(.open, errno)
                }
                Darwin.close(current)
                current = next
            }

            var metadata = stat()
            guard Darwin.fstat(current, &metadata) == 0 else {
                throw DockerJSONFileLogError.io(.metadata, errno)
            }
            guard
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                metadata.st_uid == getuid(),
                metadata.st_mode & mode_t(0o777) == Self.directoryMode
            else {
                throw DockerJSONFileLogError.unsafeStorage
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func parseRotationName(
        _ name: String,
        activeFileName: String
    ) -> (index: Int, compressed: Bool)? {
        let prefix = "\(activeFileName)."
        guard name.hasPrefix(prefix) else {
            return nil
        }
        var suffix = String(name.dropFirst(prefix.count))
        let compressed = suffix.hasSuffix(".gz")
        if compressed {
            suffix.removeLast(3)
        }
        guard
            !suffix.isEmpty,
            suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
            let index = Int(suffix),
            index >= 1
        else {
            return nil
        }
        return (index, compressed)
    }
}

private enum DockerJSONFileSystem {
    private static let readChunkSize = 64 * 1024

    static func recoverCompleteRecordPrefix(descriptor: Int32, fileSize: UInt64) throws -> UInt64 {
        guard fileSize <= UInt64(off_t.max) else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        var cursor = off_t(fileSize)
        while cursor > 0 {
            let requested = min(readChunkSize, Int(min(cursor, off_t(Int.max))))
            let offset = cursor - off_t(requested)
            let chunk = try readExactly(from: descriptor, count: requested, offset: offset)
            if let lineFeed = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                let recoveredSize = offset + off_t(chunk.distance(from: chunk.startIndex, to: lineFeed)) + 1
                return try truncateIfNeeded(
                    descriptor: descriptor,
                    currentSize: off_t(fileSize),
                    recoveredSize: recoveredSize
                )
            }
            cursor = offset
        }
        return try truncateIfNeeded(
            descriptor: descriptor,
            currentSize: off_t(fileSize),
            recoveredSize: 0
        )
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw DockerJSONFileLogError.io(.write, errno)
                }
                written += result
            }
        }
    }

    static func readAll(from descriptor: Int32, byteCount: UInt64, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        guard byteCount <= UInt64(maximumBytes), byteCount <= UInt64(Int.max) else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        return try readExactly(from: descriptor, count: Int(byteCount), offset: 0)
    }

    static func readPrefix(from descriptor: Int32, byteCount: Int) throws -> Data {
        guard byteCount > 0 else {
            throw DockerJSONFileLogError.compressionFailed
        }
        return try readExactly(from: descriptor, count: byteCount, offset: 0)
    }

    static func readTail(
        from descriptor: Int32,
        fileSize: UInt64,
        lineCount: Int,
        maximumBytes: Int
    ) throws -> (data: Data, bytesRead: Int) {
        guard lineCount > 0, maximumBytes > 0 else {
            return (Data(), 0)
        }
        guard fileSize <= UInt64(off_t.max) else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }

        var cursor = off_t(fileSize)
        var observedLineFeeds = 0
        var bytesRead = 0
        var reverseChunks: [Data] = []
        while cursor > 0, observedLineFeeds <= lineCount {
            let remainingBudget = maximumBytes - bytesRead
            guard remainingBudget > 0 else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            let requested = min(
                readChunkSize,
                remainingBudget,
                Int(min(cursor, off_t(Int.max)))
            )
            let offset = cursor - off_t(requested)
            let chunk = try readExactly(
                from: descriptor,
                count: requested,
                offset: offset
            )
            reverseChunks.append(chunk)
            bytesRead += chunk.count
            observedLineFeeds += chunk.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "\n") {
                    count += 1
                }
            }
            cursor = offset
        }
        guard cursor == 0 || observedLineFeeds > lineCount else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }

        var suffix = Data()
        suffix.reserveCapacity(bytesRead)
        for chunk in reverseChunks.reversed() {
            suffix.append(chunk)
        }
        return (DockerJSONFileLogReader.tailSuffix(suffix, lineCount: lineCount), bytesRead)
    }

    private static func readExactly(
        from descriptor: Int32,
        count: Int,
        offset: off_t
    ) throws -> Data {
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { buffer in
            while total < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: total),
                    buffer.count - total,
                    offset + off_t(total)
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    if result < 0 {
                        throw DockerJSONFileLogError.io(.read, errno)
                    }
                    throw DockerJSONFileLogError.unsafeStorage
                }
                total += result
            }
        }
        return data
    }

    private static func truncateIfNeeded(
        descriptor: Int32,
        currentSize: off_t,
        recoveredSize: off_t
    ) throws -> UInt64 {
        guard recoveredSize >= 0, recoveredSize <= currentSize else {
            throw DockerJSONFileLogError.unsafeStorage
        }
        guard recoveredSize != currentSize else {
            return UInt64(recoveredSize)
        }
        guard Darwin.ftruncate(descriptor, recoveredSize) == 0 else {
            throw DockerJSONFileLogError.io(.truncate, errno)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DockerJSONFileLogError.io(.sync, errno)
        }
        return UInt64(recoveredSize)
    }
}

private enum DockerGzip {
    private static let fixedHeaderSize = 10
    private static let flagExtra: UInt8 = 0x04
    private static let zeroGoTime = "0001-01-01T00:00:00Z"
    private static let chunkSize = 64 * 1024

    static func compress(
        source: Int32,
        destination: Int32,
        lastTimestamp: ContainerLogTimestamp?
    ) throws {
        try DockerJSONFileSystem.writeAll(
            try mobyHeader(lastTimestamp: lastTimestamp),
            to: destination
        )

        let dummySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer {
            dummySource.deallocate()
            dummyDestination.deallocate()
        }
        var stream = compression_stream(
            dst_ptr: dummyDestination,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySource),
            src_size: 0,
            state: nil
        )
        guard
            compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR
        else {
            throw DockerJSONFileLogError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var crc = UInt32.max
        var inputSize: UInt32 = 0
        var input = [UInt8](repeating: 0, count: chunkSize)
        var output = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let count = try input.withUnsafeMutableBytes { buffer -> Int in
                while true {
                    let result = Darwin.read(source, buffer.baseAddress, buffer.count)
                    if result < 0, errno == EINTR {
                        continue
                    }
                    guard result >= 0 else {
                        throw DockerJSONFileLogError.io(.read, errno)
                    }
                    return result
                }
            }
            guard count > 0 else {
                break
            }
            crc = CRC32.update(crc, bytes: input[0..<count])
            inputSize &+= UInt32(truncatingIfNeeded: count)
            try process(
                &stream,
                input: input[0..<count],
                output: &output,
                flags: 0,
                destination: destination
            )
        }

        try finalize(&stream, output: &output, destination: destination)
        var trailer = Data()
        appendLittleEndian(~crc, to: &trailer)
        appendLittleEndian(inputSize, to: &trailer)
        try DockerJSONFileSystem.writeAll(trailer, to: destination)
    }

    /// Reads only Moby's bounded FEXTRA header metadata. Invalid JSON or time
    /// metadata is ignored just as `json.Unmarshal` is ignored by Moby's
    /// compressed-file opener; an invalid gzip header remains a hard failure.
    static func lastTimestamp(
        source: Int32,
        byteCount: UInt64
    ) throws -> ContainerLogTimestamp? {
        guard byteCount >= UInt64(fixedHeaderSize + 8) else {
            throw DockerJSONFileLogError.compressionFailed
        }
        let fixed = try DockerJSONFileSystem.readPrefix(
            from: source,
            byteCount: fixedHeaderSize
        )
        guard
            fixed[0] == 0x1f,
            fixed[1] == 0x8b,
            fixed[2] == 0x08,
            fixed[3] & 0xe0 == 0
        else {
            throw DockerJSONFileLogError.compressionFailed
        }
        guard fixed[3] & flagExtra != 0 else {
            return nil
        }
        // Store-owned Moby files set only FEXTRA. If optional name, comment,
        // or header-CRC fields are present, defer all validation to the full
        // inflater instead of trusting metadata from a partially parsed
        // header to skip the file.
        guard fixed[3] == flagExtra else {
            return nil
        }

        let withLength = try DockerJSONFileSystem.readPrefix(
            from: source,
            byteCount: fixedHeaderSize + 2
        )
        let extraLength = Int(withLength[10]) | (Int(withLength[11]) << 8)
        let completeHeaderCount = fixedHeaderSize + 2 + extraLength
        guard UInt64(completeHeaderCount) <= byteCount - 8 else {
            throw DockerJSONFileLogError.compressionFailed
        }
        let completeHeader = try DockerJSONFileSystem.readPrefix(
            from: source,
            byteCount: completeHeaderCount
        )
        let extra = Data(completeHeader[(fixedHeaderSize + 2)..<completeHeaderCount])
        guard
            let object = try? JSONSerialization.jsonObject(with: extra),
            let dictionary = object as? [String: Any],
            let timestampText = dictionary["lastTime"] as? String,
            timestampText != zeroGoTime,
            let timestamp = try? DockerRFC3339Nano.parse(timestampText)
        else {
            return nil
        }
        return timestamp
    }

    static func decompress(_ data: Data, maximumDecodedBytes: Int) throws -> Data {
        guard maximumDecodedBytes > 0 else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        let deflateRange = try deflatePayloadRange(data)
        let expectedSize = Int(readLittleEndianUInt32(data, at: data.count - 4))
        guard expectedSize <= maximumDecodedBytes else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        var output = Data(count: max(expectedSize, 1))
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                guard
                    let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let source = inputBuffer.bindMemory(to: UInt8.self).baseAddress
                else {
                    return 0
                }
                return compression_decode_buffer(
                    destination,
                    outputBuffer.count,
                    source.advanced(by: deflateRange.lowerBound),
                    deflateRange.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedSize else {
            throw DockerJSONFileLogError.compressionFailed
        }
        output.removeSubrange(expectedSize...)
        let expectedCRC = readLittleEndianUInt32(data, at: data.count - 8)
        guard CRC32.checksum(output) == expectedCRC else {
            throw DockerJSONFileLogError.compressionFailed
        }
        return output
    }

    private static func process(
        _ stream: inout compression_stream,
        input: ArraySlice<UInt8>,
        output: inout [UInt8],
        flags: Int32,
        destination: Int32
    ) throws {
        try input.withUnsafeBytes { inputBuffer in
            guard let source = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw DockerJSONFileLogError.compressionFailed
            }
            stream.src_ptr = source
            stream.src_size = inputBuffer.count
            repeat {
                let status = try output.withUnsafeMutableBytes { outputBuffer -> compression_status in
                    guard let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        throw DockerJSONFileLogError.compressionFailed
                    }
                    stream.dst_ptr = destination
                    stream.dst_size = outputBuffer.count
                    return compression_stream_process(&stream, flags)
                }
                guard status != COMPRESSION_STATUS_ERROR, status != COMPRESSION_STATUS_END else {
                    throw DockerJSONFileLogError.compressionFailed
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    try DockerJSONFileSystem.writeAll(Data(output[0..<produced]), to: destination)
                }
            } while stream.src_size > 0
        }
    }

    private static func finalize(
        _ stream: inout compression_stream,
        output: inout [UInt8],
        destination: Int32
    ) throws {
        let dummyInput = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummyInput.deallocate() }
        stream.src_ptr = UnsafePointer(dummyInput)
        stream.src_size = 0
        while true {
            let status = try output.withUnsafeMutableBytes { outputBuffer -> compression_status in
                guard let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw DockerJSONFileLogError.compressionFailed
                }
                stream.dst_ptr = destination
                stream.dst_size = outputBuffer.count
                return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            }
            guard status != COMPRESSION_STATUS_ERROR else {
                throw DockerJSONFileLogError.compressionFailed
            }
            let produced = output.count - stream.dst_size
            if produced > 0 {
                try DockerJSONFileSystem.writeAll(Data(output[0..<produced]), to: destination)
            }
            if status == COMPRESSION_STATUS_END {
                return
            }
        }
    }

    private static func deflatePayloadRange(_ data: Data) throws -> Range<Int> {
        guard
            data.count >= fixedHeaderSize + 8,
            data[0] == 0x1f,
            data[1] == 0x8b,
            data[2] == 0x08
        else {
            throw DockerJSONFileLogError.compressionFailed
        }
        let flags = data[3]
        guard flags & 0xe0 == 0 else {
            throw DockerJSONFileLogError.compressionFailed
        }
        var cursor = 10
        let trailerStart = data.count - 8
        if flags & 0x04 != 0 {
            guard cursor + 2 <= trailerStart else {
                throw DockerJSONFileLogError.compressionFailed
            }
            let extraLength = Int(data[cursor]) | (Int(data[cursor + 1]) << 8)
            cursor += 2
            guard cursor + extraLength <= trailerStart else {
                throw DockerJSONFileLogError.compressionFailed
            }
            cursor += extraLength
        }
        if flags & 0x08 != 0 {
            cursor = try skipZeroTerminatedField(data, from: cursor, before: trailerStart)
        }
        if flags & 0x10 != 0 {
            cursor = try skipZeroTerminatedField(data, from: cursor, before: trailerStart)
        }
        if flags & 0x02 != 0 {
            guard cursor + 2 <= trailerStart else {
                throw DockerJSONFileLogError.compressionFailed
            }
            cursor += 2
        }
        guard cursor <= trailerStart else {
            throw DockerJSONFileLogError.compressionFailed
        }
        return cursor..<trailerStart
    }

    private static func mobyHeader(
        lastTimestamp: ContainerLogTimestamp?
    ) throws -> Data {
        // Docker Engine 29.2.1 (Moby docker-v29.2.1) assigns the raw JSON below
        // directly to gzip.Header.Extra. Go therefore emits FEXTRA + XLEN + the
        // JSON bytes, with no registered gzip subfield wrapper.
        let formattedTimestamp: String
        if let lastTimestamp {
            formattedTimestamp = try DockerRFC3339Nano.format(lastTimestamp)
        } else {
            formattedTimestamp = zeroGoTime
        }
        let extra = Data(#"{"lastTime":"\#(formattedTimestamp)"}"#.utf8)
        guard extra.count <= Int(UInt16.max) else {
            throw DockerJSONFileLogError.compressionFailed
        }

        var header = Data([0x1f, 0x8b, 0x08, flagExtra, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        header.append(UInt8(truncatingIfNeeded: extra.count))
        header.append(UInt8(truncatingIfNeeded: extra.count >> 8))
        header.append(extra)
        return header
    }

    private static func skipZeroTerminatedField(
        _ data: Data,
        from start: Int,
        before end: Int
    ) throws -> Int {
        guard start < end, let terminator = data[start..<end].firstIndex(of: 0) else {
            throw DockerJSONFileLogError.compressionFailed
        }
        return data.index(after: terminator)
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~update(UInt32.max, bytes: data)
    }

    static func update<Bytes: Sequence>(_ crc: UInt32, bytes: Bytes) -> UInt32
    where Bytes.Element == UInt8 {
        var result = crc
        for byte in bytes {
            result = table[Int((result ^ UInt32(byte)) & 0xff)] ^ (result >> 8)
        }
        return result
    }
}

package struct DockerJSONFileHandoffSegmentInspection: Equatable, Sendable {
    package let recordCount: UInt64
    package let firstTimestamp: ContainerLogTimestamp?
    package let lastTimestamp: ContainerLogTimestamp?
}

/// Exact, bounded validation for an immutable Docker json-file segment.
/// Imported bytes are parsed without opening a writer, so migration never
/// normalizes a record or creates a synthetic logging action.
package enum DockerJSONFileHandoffSegmentValidator {
    package static let maximumDecodedSegmentBytes = 128 * 1024 * 1024

    package static func inspect(
        _ bytes: Data,
        compressed: Bool
    ) throws -> DockerJSONFileHandoffSegmentInspection {
        guard bytes.count <= maximumDecodedSegmentBytes else {
            throw DockerJSONFileLogError.storageLimitExceeded
        }
        let decoded: Data
        if compressed {
            decoded = try DockerGzip.decompress(
                bytes,
                maximumDecodedBytes: maximumDecodedSegmentBytes
            )
        } else {
            decoded = bytes
        }

        var recordStart = decoded.startIndex
        var recordCount: UInt64 = 0
        var firstTimestamp: ContainerLogTimestamp?
        var lastTimestamp: ContainerLogTimestamp?
        while let lineFeed = decoded[recordStart...].firstIndex(
            of: UInt8(ascii: "\n")
        ) {
            let (nextCount, overflow) = recordCount.addingReportingOverflow(1)
            guard !overflow else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            let record = try DockerJSONFileLogCodec.decode(
                Data(decoded[recordStart..<lineFeed]),
                storageSequence: nextCount
            )
            recordCount = nextCount
            firstTimestamp = firstTimestamp ?? record.timestamp
            lastTimestamp = record.timestamp
            recordStart = decoded.index(after: lineFeed)
        }
        guard recordStart == decoded.endIndex else {
            throw DockerJSONFileLogError.malformedRecord
        }
        return DockerJSONFileHandoffSegmentInspection(
            recordCount: recordCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp
        )
    }
}
/// Read-only export of every retained Docker json-file physical segment.
///
/// Directory enumeration pins each exact inode before any bytes are read. The
/// source must already be quiesced; this path deliberately does not construct
/// a writer or run storage recovery that could mutate migration evidence.
package enum DockerJSONFileHandoffSegmentExporter {
    package static func snapshotFiles(
        directoryURL: URL,
        activeFileName: String,
        destinationDirectoryURL: URL
    ) throws -> [ContainerLogHandoffSegmentFileSnapshot] {
        try DockerJSONFileSecureDirectory.validateActiveFileName(activeFileName)
        let directory = try DockerJSONFileSecureDirectory(
            url: directoryURL,
            createIfAbsent: false
        )
        let files = try directory.pinnedFiles(
            activeFileName: activeFileName,
            maximumFileCount:
                DockerJSONFileSecureDirectory.maximumDirectoryEntries + 1,
            activeCompletedSize: nil,
            didEnumerate: nil
        )
        return try files.map { file in
            guard
                file.index >= 0,
                file.byteCount
                    <= UInt64(
                        DockerJSONFileHandoffSegmentValidator
                            .maximumDecodedSegmentBytes
                    )
            else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            let snapshot = try ContainerLogHandoffSegmentFileCopier.copy(
                descriptor: file.descriptor,
                byteLength: file.byteCount,
                rotationIndex: UInt64(file.index),
                compressed: file.compressed,
                maximumInternalSequence: 0,
                destinationDirectoryURL: destinationDirectoryURL
            )
            let bytes = try Data(
                contentsOf: snapshot.fileURL,
                options: .mappedIfSafe
            )
            _ = try DockerJSONFileHandoffSegmentValidator.inspect(
                bytes,
                compressed: file.compressed
            )
            return snapshot
        }
    }

    package static func snapshot(
        directoryURL: URL,
        activeFileName: String
    ) throws -> [ContainerLogHandoffSegmentSnapshot] {
        try DockerJSONFileSecureDirectory.validateActiveFileName(activeFileName)
        let directory = try DockerJSONFileSecureDirectory(
            url: directoryURL,
            createIfAbsent: false
        )
        let files = try directory.pinnedFiles(
            activeFileName: activeFileName,
            maximumFileCount:
                DockerJSONFileSecureDirectory.maximumDirectoryEntries + 1,
            activeCompletedSize: nil,
            didEnumerate: nil
        )
        return try files.map { file in
            guard
                file.index >= 0,
                file.byteCount
                    <= UInt64(
                        DockerJSONFileHandoffSegmentValidator
                            .maximumDecodedSegmentBytes
                    ),
                file.byteCount <= UInt64(Int.max)
            else {
                throw DockerJSONFileLogError.storageLimitExceeded
            }
            let bytes = try DockerJSONFileSystem.readAll(
                from: file.descriptor,
                byteCount: file.byteCount,
                maximumBytes: Int(file.byteCount)
            )
            _ = try DockerJSONFileHandoffSegmentValidator.inspect(
                bytes,
                compressed: file.compressed
            )
            var metadata = stat()
            guard Darwin.fstat(file.descriptor, &metadata) == 0 else {
                throw DockerJSONFileLogError.io(.metadata, errno)
            }
            return ContainerLogHandoffSegmentSnapshot(
                rotationIndex: UInt64(file.index),
                compressed: file.compressed,
                sourceDeviceID: UInt64(metadata.st_dev),
                sourceInode: UInt64(metadata.st_ino),
                bytes: bytes
            )
        }
    }
}
