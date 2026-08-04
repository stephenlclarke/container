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

/// Durable rotation checkpoints exposed to deterministic storage tests.
package enum NativeLocalLogRotationCheckpoint: Sendable {
    case replacementSynchronized
    case activeExchanged
    case rotationsStaged
    case rotationsPublished
}

package struct NativeLocalLogStoreHooks: Sendable {
    package let didEnumerateSnapshot: (@Sendable () -> Void)?
    package let pinnedSnapshotWillRead: (@Sendable () -> Void)?
    package let writeWillAcquireCoordinatorLock: (@Sendable () -> Void)?
    package let writeEncodedFrame: (@Sendable (Data, Int32) throws -> Void)?
    package let rollbackFailedWrite: (@Sendable (Int32, UInt64) -> Bool)?
    package let compressionWillStart: (@Sendable () throws -> Void)?
    package let compressionWaitDidBegin: (@Sendable () -> Void)?
    package let rotationCheckpoint: (@Sendable (NativeLocalLogRotationCheckpoint) throws -> Void)?

    package init(
        didEnumerateSnapshot: (@Sendable () -> Void)? = nil,
        pinnedSnapshotWillRead: (@Sendable () -> Void)? = nil,
        writeWillAcquireCoordinatorLock: (@Sendable () -> Void)? = nil,
        writeEncodedFrame: (@Sendable (Data, Int32) throws -> Void)? = nil,
        rollbackFailedWrite: (@Sendable (Int32, UInt64) -> Bool)? = nil,
        compressionWillStart: (@Sendable () throws -> Void)? = nil,
        compressionWaitDidBegin: (@Sendable () -> Void)? = nil,
        rotationCheckpoint: (@Sendable (NativeLocalLogRotationCheckpoint) throws -> Void)? = nil
    ) {
        self.didEnumerateSnapshot = didEnumerateSnapshot
        self.pinnedSnapshotWillRead = pinnedSnapshotWillRead
        self.writeWillAcquireCoordinatorLock = writeWillAcquireCoordinatorLock
        self.writeEncodedFrame = writeEncodedFrame
        self.rollbackFailedWrite = rollbackFailedWrite
        self.compressionWillStart = compressionWillStart
        self.compressionWaitDidBegin = compressionWaitDidBegin
        self.rotationCheckpoint = rotationCheckpoint
    }
}

package enum NativeLocalLogCompressionFailureStage: String, Equatable, Sendable {
    case preparation
    case publication
}

package struct NativeLocalLogCompressionFailure: Equatable, Sendable {
    package let stage: NativeLocalLogCompressionFailureStage
    package let error: NativeLocalLogError
}

package struct NativeLocalLogStoreSnapshot: Equatable, Sendable {
    package let closed: Bool
    package let writePoisoned: Bool
    package let compressionRunning: Bool
    package let successfulCompressionCount: UInt64
    package let compressionFailureCount: UInt64
    package let lastCompressionFailure: NativeLocalLogCompressionFailure?
}

private final class NativeLocalLogCoordinator: @unchecked Sendable {
    let writerLock = NSLock()
    let filesystemLock = NSLock()
    let hooks: NativeLocalLogStoreHooks
    var activePhysicalSize: UInt64
    var activeCompletedSize: UInt64

    private let compressionCondition = NSCondition()
    private var compressionRunning = false
    private var successfulCompressionCount: UInt64 = 0
    private var compressionFailureCount: UInt64 = 0
    private var lastCompressionFailure: NativeLocalLogCompressionFailure?

    init(activeSize: UInt64, hooks: NativeLocalLogStoreHooks) {
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

    func finishCompression(failure: NativeLocalLogCompressionFailure?) {
        compressionCondition.withLock {
            if let failure {
                if compressionFailureCount < .max {
                    compressionFailureCount += 1
                }
                lastCompressionFailure = failure
            } else if successfulCompressionCount < .max {
                successfulCompressionCount += 1
            }
            compressionRunning = false
            compressionCondition.broadcast()
        }
    }

    func compressionSnapshot() -> (
        running: Bool,
        successCount: UInt64,
        failureCount: UInt64,
        lastFailure: NativeLocalLogCompressionFailure?
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

/// Private compact store for the native `local` logging driver.
///
/// Writes, rotation, and live-reader snapshots share one coordinator. A reader
/// pins every selected inode and its completed byte boundary while holding the
/// writer and filesystem locks, so later renames and appends cannot change the
/// snapshot. Failed appends are truncated back to the last completed frame or
/// permanently fence the writer when that rollback cannot be made durable.
package final class NativeLocalLogStore: @unchecked Sendable {
    package let storageURL: URL

    private let directory: NativeLocalSecureDirectory
    private let activeFileName: String
    private let configuration: NativeLocalLogConfiguration
    private let coordinator: NativeLocalLogCoordinator
    private let compressionQueue = DispatchQueue(label: "com.apple.container.logging.local-compression")
    private var descriptor: Int32
    private var closed = false
    private var writePoisoned = false

    package convenience init(
        directoryURL: URL,
        activeFileName: String,
        configuration: NativeLocalLogConfiguration
    ) throws {
        try self.init(
            directoryURL: directoryURL,
            activeFileName: activeFileName,
            configuration: configuration,
            hooks: NativeLocalLogStoreHooks()
        )
    }

    package init(
        directoryURL: URL,
        activeFileName: String,
        configuration: NativeLocalLogConfiguration,
        hooks: NativeLocalLogStoreHooks
    ) throws {
        try NativeLocalSecureDirectory.validateActiveFileName(activeFileName)
        let directory = try NativeLocalSecureDirectory(url: directoryURL, createIfAbsent: true)
        try directory.reconcileInterruptedRotation(
            activeFileName: activeFileName,
            maximumFileCount: configuration.maximumFileCount
        )
        try directory.reconcileCompressionArtifacts(activeFileName: activeFileName)
        try directory.removeStaleRotations(
            activeFileName: activeFileName,
            maximumFileCount: configuration.maximumFileCount
        )
        let opened = try Self.openPreparedActiveFile(
            directory: directory,
            activeFileName: activeFileName
        )

        self.directory = directory
        self.activeFileName = activeFileName
        self.configuration = configuration
        descriptor = opened.descriptor
        coordinator = NativeLocalLogCoordinator(activeSize: opened.size, hooks: hooks)
        storageURL = directoryURL.appendingPathComponent(activeFileName, isDirectory: false)

        if configuration.compress, configuration.maximumFileCount > 1,
            try directory.fileExists(named: rotationName(index: 1, compressed: false))
        {
            scheduleCompression(named: rotationName(index: 1, compressed: false))
        }
    }

    package convenience init(directoryURL: URL, activeFileName: String) throws {
        try self.init(
            directoryURL: directoryURL,
            activeFileName: activeFileName,
            configuration: try NativeLocalLogConfiguration()
        )
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    package func write(_ record: ContainerLogRecordV2) throws {
        let encoded = try NativeLocalLogCodec.encode(record)
        coordinator.hooks.writeWillAcquireCoordinatorLock?()
        try coordinator.writerLock.withLock {
            guard !closed else {
                throw NativeLocalLogError.closed
            }
            guard !writePoisoned else {
                throw NativeLocalLogError.writePoisoned
            }
            if coordinator.activePhysicalSize > UInt64(NativeLocalLogCodec.fileHeaderSize),
                coordinator.activePhysicalSize >= configuration.maximumFileSize
            {
                try rotate()
            }

            let completedBoundary = coordinator.activeCompletedSize
            let (nextSize, overflow) = coordinator.activePhysicalSize.addingReportingOverflow(
                UInt64(encoded.count)
            )
            guard !overflow else {
                throw NativeLocalLogError.storageLimitExceeded
            }
            do {
                if let writeEncodedFrame = coordinator.hooks.writeEncodedFrame {
                    try writeEncodedFrame(encoded, descriptor)
                } else {
                    try NativeLocalFileSystem.writeAll(encoded, to: descriptor)
                }
            } catch {
                rollbackFailedWrite(to: completedBoundary)
                throw error
            }
            coordinator.activePhysicalSize = nextSize
            coordinator.activeCompletedSize = nextSize
        }
    }

    package func synchronize() throws {
        try coordinator.writerLock.withLock {
            guard !closed else {
                throw NativeLocalLogError.closed
            }
            guard !writePoisoned else {
                throw NativeLocalLogError.writePoisoned
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw NativeLocalLogError.io(.sync, errno)
            }
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
            let closeError: NativeLocalLogError?
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

    package func makeReader() throws -> NativeLocalLogReader {
        try NativeLocalLogReader(
            directoryURL: directory.url,
            activeFileName: activeFileName,
            maximumFileCount: configuration.maximumFileCount,
            directory: directory,
            coordinator: coordinator
        )
    }

    package var snapshot: NativeLocalLogStoreSnapshot {
        coordinator.writerLock.withLock {
            let compression = coordinator.compressionSnapshot()
            return NativeLocalLogStoreSnapshot(
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
        let transaction = NativeLocalRotationTransaction(
            activeFileName: activeFileName,
            identifier: UUID().uuidString
        )
        var replacementDescriptor = Int32(-1)
        var exchanged = false
        var oldDescriptor = descriptor

        do {
            try coordinator.filesystemLock.withLock {
                replacementDescriptor = try directory.createExclusiveReadWriteFile(
                    named: transaction.replacementName
                )
                try NativeLocalFileSystem.writeAll(
                    NativeLocalLogCodec.fileHeader,
                    to: replacementDescriptor
                )
                guard Darwin.fsync(replacementDescriptor) == 0 else {
                    throw NativeLocalLogError.io(.sync, errno)
                }
                try directory.createRotationMarker(named: transaction.markerName(for: .prepared))
                try directory.synchronize()
                try coordinator.hooks.rotationCheckpoint?(.replacementSynchronized)

                try directory.exchangeFiles(
                    transaction.replacementName,
                    activeFileName
                )
                exchanged = true
                descriptor = replacementDescriptor
                replacementDescriptor = -1
                coordinator.activePhysicalSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
                coordinator.activeCompletedSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
                try directory.renameFile(
                    from: transaction.markerName(for: .prepared),
                    to: transaction.markerName(for: .swapped)
                )
                try directory.synchronize()
                let closeResult = Darwin.close(oldDescriptor)
                oldDescriptor = -1
                if closeResult != 0 {
                    throw NativeLocalLogError.io(.close, errno)
                }
                try coordinator.hooks.rotationCheckpoint?(.activeExchanged)

                try directory.stageRotations(for: transaction)
                try directory.renameFile(
                    from: transaction.markerName(for: .swapped),
                    to: transaction.markerName(for: .publishing)
                )
                try directory.synchronize()
                try coordinator.hooks.rotationCheckpoint?(.rotationsStaged)

                try directory.publishStagedRotations(
                    for: transaction,
                    maximumFileCount: configuration.maximumFileCount
                )
                try directory.synchronize()
                try coordinator.hooks.rotationCheckpoint?(.rotationsPublished)
                try directory.removeFileIfPresent(
                    named: transaction.markerName(for: .publishing)
                )
                try directory.synchronize()
            }
        } catch {
            if replacementDescriptor >= 0 {
                Darwin.close(replacementDescriptor)
            }
            if oldDescriptor >= 0, exchanged {
                Darwin.close(oldDescriptor)
            }
            do {
                try coordinator.filesystemLock.withLock {
                    if exchanged {
                        try directory.reconcileInterruptedRotation(
                            activeFileName: activeFileName,
                            maximumFileCount: configuration.maximumFileCount
                        )
                    } else {
                        try directory.removeRotationTransaction(transaction)
                    }
                }
            } catch {
                poisonWriter()
            }
            throw error
        }

        if configuration.compress, configuration.maximumFileCount > 1 {
            scheduleCompression(named: rotationName(index: 1, compressed: false))
        }
    }

    private func scheduleCompression(named sourceName: String) {
        coordinator.beginCompression()
        compressionQueue.async { [self] in
            var failure: NativeLocalLogCompressionFailure?
            defer { coordinator.finishCompression(failure: failure) }

            let compressedName = "\(sourceName).gz"
            let temporaryName = "\(compressedName).tmp.\(UUID().uuidString)"
            var source = Int32(-1)
            var destination = Int32(-1)
            var published = false
            var failureStage = NativeLocalLogCompressionFailureStage.preparation
            defer {
                if source >= 0 {
                    Darwin.close(source)
                }
                if destination >= 0 {
                    Darwin.close(destination)
                }
                if !published {
                    try? coordinator.filesystemLock.withLock {
                        try directory.removeFileIfPresent(named: temporaryName)
                        try directory.synchronize()
                    }
                }
            }

            do {
                try coordinator.hooks.compressionWillStart?()
                try coordinator.filesystemLock.withLock {
                    guard try directory.fileExists(named: sourceName) else {
                        return
                    }
                    source = try directory.openReadableFile(named: sourceName)
                    destination = try directory.createExclusiveWritableFile(named: temporaryName)
                }
                guard source >= 0, destination >= 0 else {
                    return
                }
                try NativeLocalGzip.compress(source: source, destination: destination)
                guard Darwin.fsync(destination) == 0 else {
                    throw NativeLocalLogError.io(.sync, errno)
                }
                guard Darwin.close(destination) == 0 else {
                    throw NativeLocalLogError.io(.close, errno)
                }
                destination = -1

                failureStage = .publication
                try coordinator.filesystemLock.withLock {
                    try directory.removeFileIfPresent(named: compressedName)
                    try directory.renameFile(from: temporaryName, to: compressedName)
                    try directory.synchronize()
                    try directory.removeFileIfPresent(named: sourceName)
                    try directory.synchronize()
                    published = true
                }
            } catch {
                failure = NativeLocalLogCompressionFailure(
                    stage: failureStage,
                    error: error as? NativeLocalLogError ?? .compressionFailed
                )
                return
            }
        }
    }

    private func rollbackFailedWrite(to completedBoundary: UInt64) {
        let rolledBack: Bool
        if let rollbackFailedWrite = coordinator.hooks.rollbackFailedWrite {
            rolledBack = rollbackFailedWrite(descriptor, completedBoundary)
        } else {
            rolledBack = NativeLocalFileSystem.rollback(
                descriptor,
                to: completedBoundary
            )
        }
        guard rolledBack else {
            poisonWriter()
            return
        }
        coordinator.activePhysicalSize = completedBoundary
        coordinator.activeCompletedSize = completedBoundary
    }

    private func poisonWriter() {
        writePoisoned = true
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func rotationName(index: Int, compressed: Bool) -> String {
        "\(activeFileName).\(index)\(compressed ? ".gz" : "")"
    }

    private static func openPreparedActiveFile(
        directory: NativeLocalSecureDirectory,
        activeFileName: String
    ) throws -> (descriptor: Int32, size: UInt64) {
        let opened = try directory.openWritableFile(named: activeFileName)
        do {
            let size = try prepareActiveFile(
                descriptor: opened.descriptor,
                observedSize: opened.size
            )
            return (opened.descriptor, size)
        } catch {
            Darwin.close(opened.descriptor)
            throw error
        }
    }

    private static func prepareActiveFile(descriptor: Int32, observedSize: UInt64) throws -> UInt64 {
        let headerSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
        if observedSize < headerSize {
            let partial = try NativeLocalFileSystem.readExactly(
                from: descriptor,
                count: Int(observedSize),
                offset: 0
            )
            guard partial == Data(NativeLocalLogCodec.fileHeader.prefix(Int(observedSize))) else {
                throw NativeLocalLogError.malformedHeader
            }
            try NativeLocalFileSystem.truncate(descriptor, to: 0)
            do {
                try NativeLocalFileSystem.writeAll(NativeLocalLogCodec.fileHeader, to: descriptor)
                guard Darwin.fsync(descriptor) == 0 else {
                    throw NativeLocalLogError.io(.sync, errno)
                }
            } catch {
                _ = NativeLocalFileSystem.rollback(descriptor, to: 0)
                throw error
            }
            return headerSize
        }

        let header = try NativeLocalFileSystem.readExactly(
            from: descriptor,
            count: NativeLocalLogCodec.fileHeaderSize,
            offset: 0
        )
        try NativeLocalLogCodec.validateFileHeader(header)

        var offset = headerSize
        while offset < observedSize {
            let available = observedSize - offset
            if available < UInt64(NativeLocalLogCodec.framePrefixSize) {
                let suffix = try NativeLocalFileSystem.readExactly(
                    from: descriptor,
                    count: Int(available),
                    offset: offset
                )
                guard NativeLocalLogCodec.isTruncatedFramePrefix(suffix) else {
                    throw NativeLocalLogError.malformedFrame
                }
                try NativeLocalFileSystem.truncate(descriptor, to: offset)
                return offset
            }

            let prefix = try NativeLocalFileSystem.readExactly(
                from: descriptor,
                count: NativeLocalLogCodec.framePrefixSize,
                offset: offset
            )
            let bodyLength: Int
            let frameLength: Int
            do {
                bodyLength = try NativeLocalLogCodec.bodyLength(fromFramePrefix: prefix)
                frameLength = try NativeLocalLogCodec.frameLength(bodyLength: bodyLength)
            } catch {
                throw NativeLocalLogError.malformedFrame
            }
            guard UInt64(frameLength) <= available else {
                guard
                    try !NativeLocalFileSystem.hasValidFrame(
                        descriptor: descriptor,
                        after: offset,
                        fileSize: observedSize
                    )
                else {
                    throw NativeLocalLogError.malformedFrame
                }
                try NativeLocalFileSystem.truncate(descriptor, to: offset)
                return offset
            }
            let frame = try NativeLocalFileSystem.readExactly(
                from: descriptor,
                count: frameLength,
                offset: offset
            )
            _ = try NativeLocalLogCodec.decode(frame)
            offset += UInt64(frameLength)
        }
        return offset
    }
}

/// Bounded reader for the native `local` store.
///
/// Store-owned readers take an atomic inode snapshot. Standalone readers are
/// intended for stopped containers and pin the same information without a
/// coordinator. Negative tail values mean full replay, matching Docker's API.
package final class NativeLocalLogReader: @unchecked Sendable {
    private let directory: NativeLocalSecureDirectory
    private let activeFileName: String
    private let maximumFileCount: Int
    private let coordinator: NativeLocalLogCoordinator?
    private let lock = NSLock()

    package init(
        directoryURL: URL,
        activeFileName: String,
        maximumFileCount: Int
    ) throws {
        try NativeLocalSecureDirectory.validateActiveFileName(activeFileName)
        guard maximumFileCount > 0 else {
            throw NativeLocalLogError.invalidConfiguration
        }
        directory = try NativeLocalSecureDirectory(url: directoryURL, createIfAbsent: false)
        self.activeFileName = activeFileName
        self.maximumFileCount = maximumFileCount
        coordinator = nil
    }

    fileprivate init(
        directoryURL: URL,
        activeFileName: String,
        maximumFileCount: Int,
        directory: NativeLocalSecureDirectory,
        coordinator: NativeLocalLogCoordinator
    ) throws {
        try NativeLocalSecureDirectory.validateActiveFileName(activeFileName)
        guard maximumFileCount > 0, directory.url == directoryURL else {
            throw NativeLocalLogError.invalidConfiguration
        }
        self.directory = directory
        self.activeFileName = activeFileName
        self.maximumFileCount = maximumFileCount
        self.coordinator = coordinator
    }

    package func read(_ request: NativeLocalLogReadRequest) throws -> NativeLocalLogReadResult {
        try lock.withLock {
            if request.effectiveTail == 0 || (!request.stdout && !request.stderr) {
                return NativeLocalLogReadResult(records: [], issues: [])
            }

            var budget = NativeLocalReadBudget(request: request)
            let files = try pinnedFiles()
            coordinator?.hooks.pinnedSnapshotWillRead?()
            let decoded: NativeLocalLogReadResult
            if let tail = request.effectiveTail {
                decoded = try readTail(
                    files: files,
                    count: tail,
                    budget: &budget
                )
            } else {
                decoded = try readAll(
                    files: files,
                    budget: &budget,
                    maximumRecords: request.maximumRecords
                )
            }
            return NativeLocalLogReadResult(
                records: applyFilters(decoded.records, request: request),
                issues: decoded.issues
            )
        }
    }

    package func forEach(
        _ request: NativeLocalLogReadRequest,
        _ body: (ContainerLogRecordV2) throws -> Void
    ) throws -> [NativeLocalLogReadIssue] {
        let result = try read(request)
        for record in result.records {
            try body(record)
        }
        return result.issues
    }

    private func pinnedFiles() throws -> [NativeLocalPinnedFile] {
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

    private func readAll(
        files: [NativeLocalPinnedFile],
        budget: inout NativeLocalReadBudget,
        maximumRecords: Int
    ) throws -> NativeLocalLogReadResult {
        var records: [ContainerLogRecordV2] = []
        var issues: [NativeLocalLogReadIssue] = []
        for file in files {
            let data: Data
            do {
                data = try readFile(file, budget: &budget)
            } catch NativeLocalLogError.compressionFailed {
                issues.append(.corruptCompressedFile(fileIndex: file.index))
                continue
            }
            let decoded = try decodeForward(
                data,
                fileIndex: file.index,
                maximumRecords: maximumRecords - records.count
            )
            records.append(contentsOf: decoded.records)
            issues.append(contentsOf: decoded.issues)
        }
        return NativeLocalLogReadResult(records: records, issues: issues)
    }

    private func readTail(
        files: [NativeLocalPinnedFile],
        count: Int,
        budget: inout NativeLocalReadBudget
    ) throws -> NativeLocalLogReadResult {
        var newestFirst: [ContainerLogRecordV2] = []
        var issues: [NativeLocalLogReadIssue] = []
        newestFirst.reserveCapacity(count)

        for file in files.reversed() where newestFirst.count < count {
            let needed = count - newestFirst.count
            let decoded: NativeLocalLogReadResult
            if file.compressed {
                do {
                    decoded = decodeBackward(
                        try readFile(file, budget: &budget),
                        fileIndex: file.index,
                        maximumRecords: needed
                    )
                } catch NativeLocalLogError.compressionFailed {
                    issues.append(.corruptCompressedFile(fileIndex: file.index))
                    continue
                }
            } else {
                decoded = try decodeBackward(
                    descriptor: file.descriptor,
                    byteCount: file.byteCount,
                    fileIndex: file.index,
                    maximumRecords: needed,
                    budget: &budget
                )
            }
            newestFirst.append(contentsOf: decoded.records)
            issues.append(contentsOf: decoded.issues)
        }
        return NativeLocalLogReadResult(
            records: Array(newestFirst.prefix(count).reversed()),
            issues: issues
        )
    }

    private func readFile(
        _ file: NativeLocalPinnedFile,
        budget: inout NativeLocalReadBudget
    ) throws -> Data {
        guard file.byteCount <= UInt64(Int.max) else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        let count = Int(file.byteCount)
        if file.compressed {
            try budget.consumeStored(count)
            let stored = try NativeLocalFileSystem.readExactly(
                from: file.descriptor,
                count: count,
                offset: 0
            )
            let decoded = try NativeLocalGzip.decompress(
                stored,
                maximumDecodedBytes: budget.remainingDecoded
            )
            try budget.consumeDecoded(decoded.count)
            return decoded
        }
        try budget.consumeUncompressed(count)
        return try NativeLocalFileSystem.readExactly(
            from: file.descriptor,
            count: count,
            offset: 0
        )
    }

    private func decodeForward(
        _ data: Data,
        fileIndex: Int,
        maximumRecords: Int
    ) throws -> NativeLocalLogReadResult {
        guard data.count >= NativeLocalLogCodec.fileHeaderSize else {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.truncatedFinalFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }
        do {
            try NativeLocalLogCodec.validateFileHeader(
                Data(data.prefix(NativeLocalLogCodec.fileHeaderSize))
            )
        } catch {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.corruptFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }

        var records: [ContainerLogRecordV2] = []
        var issues: [NativeLocalLogReadIssue] = []
        var offset = NativeLocalLogCodec.fileHeaderSize
        while offset < data.count {
            guard data.count - offset >= NativeLocalLogCodec.framePrefixSize else {
                let remainder = Data(data[offset...])
                issues.append(
                    NativeLocalLogCodec.isTruncatedFramePrefix(remainder)
                        ? .truncatedFinalFrame(fileIndex: fileIndex, byteOffset: UInt64(offset))
                        : .corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset))
                )
                break
            }

            let frameLength: Int
            do {
                let prefix = Data(data[offset..<(offset + NativeLocalLogCodec.framePrefixSize)])
                let bodyLength = try NativeLocalLogCodec.bodyLength(fromFramePrefix: prefix)
                frameLength = try NativeLocalLogCodec.frameLength(bodyLength: bodyLength)
            } catch {
                if let next = nextValidFrameStart(in: data, after: offset) {
                    issues.append(.corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                    offset = next
                    continue
                }
                issues.append(.corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                break
            }

            guard frameLength <= data.count - offset else {
                if let next = nextValidFrameStart(in: data, after: offset) {
                    issues.append(.corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                    offset = next
                    continue
                }
                issues.append(.truncatedFinalFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                break
            }
            let frame = Data(data[offset..<(offset + frameLength)])
            do {
                guard records.count < maximumRecords else {
                    throw NativeLocalLogError.storageLimitExceeded
                }
                records.append(try NativeLocalLogCodec.decode(frame))
                offset += frameLength
            } catch NativeLocalLogError.storageLimitExceeded {
                throw NativeLocalLogError.storageLimitExceeded
            } catch {
                if let next = nextValidFrameStart(in: data, after: offset) {
                    issues.append(.corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                    offset = next
                    continue
                }
                issues.append(.corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(offset)))
                break
            }
        }
        return NativeLocalLogReadResult(records: records, issues: issues)
    }

    private func nextValidFrameStart(in data: Data, after offset: Int) -> Int? {
        let lastStart = data.count - NativeLocalLogCodec.framePrefixSize
        guard offset < lastStart else {
            return nil
        }
        for candidate in (offset + 1)...lastStart
        where NativeLocalLogCodec.hasFrameMagic(data, at: candidate) {
            let prefix = Data(data[candidate..<(candidate + NativeLocalLogCodec.framePrefixSize)])
            guard
                let bodyLength = try? NativeLocalLogCodec.bodyLength(fromFramePrefix: prefix),
                let frameLength = try? NativeLocalLogCodec.frameLength(bodyLength: bodyLength),
                frameLength <= data.count - candidate,
                (try? NativeLocalLogCodec.decode(
                    Data(data[candidate..<(candidate + frameLength)])
                )) != nil
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func decodeBackward(
        _ data: Data,
        fileIndex: Int,
        maximumRecords: Int
    ) -> NativeLocalLogReadResult {
        guard data.count >= NativeLocalLogCodec.fileHeaderSize else {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.truncatedFinalFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }
        do {
            try NativeLocalLogCodec.validateFileHeader(
                Data(data.prefix(NativeLocalLogCodec.fileHeaderSize))
            )
        } catch {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.corruptFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }

        var records: [ContainerLogRecordV2] = []
        var issues: [NativeLocalLogReadIssue] = []
        var cursor = data.count
        var pendingFrame =
            cursor > NativeLocalLogCodec.fileHeaderSize
            ? decodeFrameEnding(at: cursor, in: data)
            : nil
        if cursor > NativeLocalLogCodec.fileHeaderSize, pendingFrame == nil {
            let recovered = lastValidFrameEnd(in: data)
            let boundary = recovered ?? NativeLocalLogCodec.fileHeaderSize
            let trailing = Data(data[boundary...])
            issues.append(
                NativeLocalLogCodec.isTruncatedFramePrefix(trailing)
                    ? .truncatedFinalFrame(fileIndex: fileIndex, byteOffset: UInt64(boundary))
                    : .corruptFrame(fileIndex: fileIndex, byteOffset: UInt64(boundary))
            )
            cursor = boundary
            pendingFrame = nil
        }

        while cursor > NativeLocalLogCodec.fileHeaderSize, records.count < maximumRecords {
            guard let decoded = pendingFrame ?? decodeFrameEnding(at: cursor, in: data) else {
                issues.append(
                    .corruptFrame(
                        fileIndex: fileIndex,
                        byteOffset: UInt64(max(cursor - NativeLocalLogCodec.frameFooterSize, 0))
                    )
                )
                break
            }
            pendingFrame = nil
            records.append(decoded.record)
            cursor = decoded.start
        }
        return NativeLocalLogReadResult(records: records, issues: issues)
    }

    private func decodeFrameEnding(
        at end: Int,
        in data: Data
    ) -> (start: Int, record: ContainerLogRecordV2)? {
        let headerSize = NativeLocalLogCodec.fileHeaderSize
        guard end - headerSize >= NativeLocalLogCodec.frameFooterSize else {
            return nil
        }
        let footer = Data(data[(end - NativeLocalLogCodec.frameFooterSize)..<end])
        guard
            let bodyLength = try? NativeLocalLogCodec.bodyLength(fromFrameFooter: footer),
            let frameLength = try? NativeLocalLogCodec.frameLength(bodyLength: bodyLength),
            frameLength <= end - headerSize
        else {
            return nil
        }
        let start = end - frameLength
        guard let record = try? NativeLocalLogCodec.decode(Data(data[start..<end])) else {
            return nil
        }
        return (start, record)
    }

    private func lastValidFrameEnd(in data: Data) -> Int? {
        let minimumEnd = NativeLocalLogCodec.fileHeaderSize + NativeLocalLogCodec.frameFooterSize
        guard data.count >= minimumEnd else {
            return nil
        }
        for end in stride(from: data.count - 1, through: minimumEnd, by: -1) {
            if decodeFrameEnding(at: end, in: data) != nil {
                return end
            }
        }
        return nil
    }

    private func decodeBackward(
        descriptor: Int32,
        byteCount: UInt64,
        fileIndex: Int,
        maximumRecords: Int,
        budget: inout NativeLocalReadBudget
    ) throws -> NativeLocalLogReadResult {
        let headerSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
        guard byteCount >= headerSize else {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.truncatedFinalFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }
        try budget.consumeUncompressed(NativeLocalLogCodec.fileHeaderSize)
        let header = try NativeLocalFileSystem.readExactly(
            from: descriptor,
            count: NativeLocalLogCodec.fileHeaderSize,
            offset: 0
        )
        do {
            try NativeLocalLogCodec.validateFileHeader(header)
        } catch {
            return NativeLocalLogReadResult(
                records: [],
                issues: [.corruptFrame(fileIndex: fileIndex, byteOffset: 0)]
            )
        }

        var records: [ContainerLogRecordV2] = []
        var issues: [NativeLocalLogReadIssue] = []
        var cursor = byteCount
        var pendingFrame =
            cursor > headerSize
            ? try readFrameEnding(
                at: cursor,
                descriptor: descriptor,
                budget: &budget
            ) : nil
        if cursor > headerSize, pendingFrame == nil {
            let recovered = try lastValidFrameEnd(
                descriptor: descriptor,
                byteCount: byteCount,
                budget: &budget
            )
            let boundary = recovered ?? headerSize
            let trailingByteCount = byteCount - boundary
            guard trailingByteCount <= UInt64(Int.max) else {
                throw NativeLocalLogError.storageLimitExceeded
            }
            let trailingCount = Int(trailingByteCount)
            try budget.consumeUncompressed(trailingCount)
            let trailing = try NativeLocalFileSystem.readExactly(
                from: descriptor,
                count: trailingCount,
                offset: boundary
            )
            issues.append(
                NativeLocalLogCodec.isTruncatedFramePrefix(trailing)
                    ? .truncatedFinalFrame(fileIndex: fileIndex, byteOffset: boundary)
                    : .corruptFrame(fileIndex: fileIndex, byteOffset: boundary)
            )
            cursor = boundary
            pendingFrame = nil
        }

        while cursor > headerSize, records.count < maximumRecords {
            guard
                let decoded = try pendingFrame
                    ?? readFrameEnding(
                        at: cursor,
                        descriptor: descriptor,
                        budget: &budget
                    )
            else {
                issues.append(
                    .corruptFrame(
                        fileIndex: fileIndex,
                        byteOffset: cursor - UInt64(NativeLocalLogCodec.frameFooterSize)
                    )
                )
                break
            }
            pendingFrame = nil
            records.append(decoded.record)
            cursor = decoded.start
        }
        return NativeLocalLogReadResult(records: records, issues: issues)
    }

    private func readFrameEnding(
        at end: UInt64,
        descriptor: Int32,
        budget: inout NativeLocalReadBudget
    ) throws -> (start: UInt64, record: ContainerLogRecordV2)? {
        let headerSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
        guard end - min(end, headerSize) >= UInt64(NativeLocalLogCodec.frameFooterSize) else {
            return nil
        }
        try budget.consumeUncompressed(NativeLocalLogCodec.frameFooterSize)
        let footer = try NativeLocalFileSystem.readExactly(
            from: descriptor,
            count: NativeLocalLogCodec.frameFooterSize,
            offset: end - UInt64(NativeLocalLogCodec.frameFooterSize)
        )
        guard
            let bodyLength = try? NativeLocalLogCodec.bodyLength(fromFrameFooter: footer),
            let frameLength = try? NativeLocalLogCodec.frameLength(bodyLength: bodyLength),
            UInt64(frameLength) <= end - headerSize
        else {
            return nil
        }
        let start = end - UInt64(frameLength)
        try budget.consumeUncompressed(frameLength - NativeLocalLogCodec.frameFooterSize)
        let frame = try NativeLocalFileSystem.readExactly(
            from: descriptor,
            count: frameLength,
            offset: start
        )
        guard let record = try? NativeLocalLogCodec.decode(frame) else {
            return nil
        }
        return (start, record)
    }

    private func lastValidFrameEnd(
        descriptor: Int32,
        byteCount: UInt64,
        budget: inout NativeLocalReadBudget
    ) throws -> UInt64? {
        let headerSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
        let scanLength = min(
            byteCount - headerSize,
            UInt64(NativeLocalLogCodec.maximumEncodedFrameBytes + NativeLocalLogCodec.frameFooterSize)
        )
        guard scanLength > 0 else {
            return nil
        }
        guard scanLength <= UInt64(Int.max) else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        let scanStart = byteCount - scanLength
        try budget.consumeUncompressed(Int(scanLength))
        let suffix = try NativeLocalFileSystem.readExactly(
            from: descriptor,
            count: Int(scanLength),
            offset: scanStart
        )
        let minimumRelativeEnd = NativeLocalLogCodec.frameFooterSize
        guard suffix.count >= minimumRelativeEnd else {
            return nil
        }
        for relativeEnd in stride(
            from: suffix.count - 1,
            through: minimumRelativeEnd,
            by: -1
        ) {
            let absoluteEnd = scanStart + UInt64(relativeEnd)
            let footer = Data(
                suffix[(relativeEnd - NativeLocalLogCodec.frameFooterSize)..<relativeEnd]
            )
            guard
                let bodyLength = try? NativeLocalLogCodec.bodyLength(fromFrameFooter: footer),
                let frameLength = try? NativeLocalLogCodec.frameLength(bodyLength: bodyLength),
                UInt64(frameLength) <= absoluteEnd - min(absoluteEnd, headerSize)
            else {
                continue
            }
            let start = absoluteEnd - UInt64(frameLength)
            try budget.consumeUncompressed(frameLength)
            let frame = try NativeLocalFileSystem.readExactly(
                from: descriptor,
                count: frameLength,
                offset: start
            )
            if (try? NativeLocalLogCodec.decode(frame)) != nil {
                return absoluteEnd
            }
        }
        return nil
    }

    private func applyFilters(
        _ records: [ContainerLogRecordV2],
        request: NativeLocalLogReadRequest
    ) -> [ContainerLogRecordV2] {
        var since = request.since
        var filtered: [ContainerLogRecordV2] = []
        filtered.reserveCapacity(records.count)
        for record in records {
            if let lowerBound = since {
                if record.observation.wallClock < lowerBound {
                    continue
                }
                // Moby disables the lower-bound check after its first match
                // because timestamps from concurrent streams may regress.
                since = nil
            }
            if let until = request.until, record.observation.wallClock > until {
                break
            }
            switch record.stream {
            case .stdout where !request.stdout:
                continue
            case .stderr where !request.stderr:
                continue
            default:
                break
            }
            filtered.append(record)
        }
        return filtered
    }
}

private struct NativeLocalReadBudget {
    private(set) var remainingDecoded: Int
    private(set) var remainingStored: Int
    private(set) var remainingAggregate: Int

    init(request: NativeLocalLogReadRequest) {
        remainingDecoded = request.maximumDecodedBytes
        remainingStored = request.maximumStoredBytes
        remainingAggregate = request.maximumDecodedBytes + request.maximumStoredBytes
    }

    mutating func consumeDecoded(_ count: Int) throws {
        guard count >= 0, count <= remainingDecoded, count <= remainingAggregate else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        remainingDecoded -= count
        remainingAggregate -= count
    }

    mutating func consumeStored(_ count: Int) throws {
        guard count >= 0, count <= remainingStored, count <= remainingAggregate else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        remainingStored -= count
        remainingAggregate -= count
    }

    mutating func consumeUncompressed(_ count: Int) throws {
        guard
            count >= 0,
            count <= remainingStored,
            count <= remainingDecoded,
            count <= remainingAggregate
        else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        remainingStored -= count
        remainingDecoded -= count
        remainingAggregate -= count
    }
}

private struct NativeLocalStoredFile: Equatable {
    let name: String
    let index: Int
    let compressed: Bool
}

private final class NativeLocalPinnedFile: @unchecked Sendable {
    let storedFile: NativeLocalStoredFile
    let descriptor: Int32
    let byteCount: UInt64

    var index: Int { storedFile.index }
    var compressed: Bool { storedFile.compressed }

    init(storedFile: NativeLocalStoredFile, descriptor: Int32, byteCount: UInt64) {
        self.storedFile = storedFile
        self.descriptor = descriptor
        self.byteCount = byteCount
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private enum NativeLocalRotationPhase: String, CaseIterable {
    case prepared
    case swapped
    case publishing
}

private struct NativeLocalRotationTransaction: Equatable {
    let activeFileName: String
    let identifier: String

    var artifactPrefix: String {
        "\(activeFileName).rotate.\(identifier)."
    }

    var replacementName: String {
        "\(artifactPrefix)replacement"
    }

    func markerName(for phase: NativeLocalRotationPhase) -> String {
        "\(artifactPrefix)phase-\(phase.rawValue)"
    }

    func stagedName(for file: NativeLocalStoredFile) -> String {
        "\(artifactPrefix)retained-\(file.index)\(file.compressed ? ".gz" : "")"
    }

    static func parseIdentifier(_ name: String, activeFileName: String) -> String? {
        let prefix = "\(activeFileName).rotate."
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let remainder = name.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: ".") else {
            return nil
        }
        let identifier = String(remainder[..<separator])
        guard let uuid = UUID(uuidString: identifier), uuid.uuidString == identifier else {
            return nil
        }
        let artifact = String(remainder[remainder.index(after: separator)...])
        let isMarker = NativeLocalRotationPhase.allCases.contains {
            artifact == "phase-\($0.rawValue)"
        }
        let isRetained =
            artifact.hasPrefix("retained-")
            && isCanonicalRotationSuffix(String(artifact.dropFirst("retained-".count)))
        guard artifact == "replacement" || isMarker || isRetained else {
            return nil
        }
        return identifier
    }

    func containsArtifact(named name: String) -> Bool {
        Self.parseIdentifier(name, activeFileName: activeFileName) == identifier
    }

    private static func isCanonicalRotationSuffix(_ rawSuffix: String) -> Bool {
        var suffix = rawSuffix
        if suffix.hasSuffix(".gz") {
            suffix.removeLast(3)
        }
        let bytes = Array(suffix.utf8)
        guard
            let first = bytes.first,
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(first),
            bytes.dropFirst().allSatisfy({
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            }),
            let index = Int(suffix)
        else {
            return false
        }
        return String(index) == suffix
    }
}

private final class NativeLocalSecureDirectory: @unchecked Sendable {
    static let fileMode = mode_t(0o600)
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
            name.utf8.count <= 150
        else {
            throw NativeLocalLogError.invalidActiveFileName
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
            throw NativeLocalLogError.io(.open, errno)
        }
        do {
            let metadata = try validateRegularFile(opened)
            guard Darwin.fchmod(opened, Self.fileMode) == 0 else {
                throw NativeLocalLogError.io(.metadata, errno)
            }
            guard metadata.st_size >= 0 else {
                throw NativeLocalLogError.unsafeStorage
            }
            return (opened, UInt64(metadata.st_size))
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
            throw NativeLocalLogError.io(.open, errno)
        }
        do {
            _ = try validateRegularFile(opened)
            return opened
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func createExclusiveReadWriteFile(named name: String) throws -> Int32 {
        let opened = name.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                Self.fileMode
            )
        }
        guard opened >= 0 else {
            throw NativeLocalLogError.io(.open, errno)
        }
        do {
            _ = try validateRegularFile(opened)
            return opened
        } catch {
            Darwin.close(opened)
            throw error
        }
    }

    func createRotationMarker(named name: String) throws {
        let marker = try createExclusiveWritableFile(named: name)
        guard Darwin.fsync(marker) == 0 else {
            let savedErrno = errno
            Darwin.close(marker)
            throw NativeLocalLogError.io(.sync, savedErrno)
        }
        guard Darwin.close(marker) == 0 else {
            throw NativeLocalLogError.io(.close, errno)
        }
    }

    func openReadableFile(named name: String) throws -> Int32 {
        let opened = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else {
            throw NativeLocalLogError.io(.open, errno)
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
            throw NativeLocalLogError.unsafeStorage
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
            throw NativeLocalLogError.io(.remove, errno)
        }
    }

    func renameFile(from source: String, to destination: String) throws {
        guard let sourceMetadata = try metadata(named: source) else {
            throw NativeLocalLogError.io(.rename, ENOENT)
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
            throw NativeLocalLogError.io(.rename, errno)
        }
    }

    func exchangeFiles(_ first: String, _ second: String) throws {
        guard
            let firstMetadata = try metadata(named: first),
            let secondMetadata = try metadata(named: second)
        else {
            throw NativeLocalLogError.io(.rename, ENOENT)
        }
        try validateRegularMetadata(firstMetadata)
        try validateRegularMetadata(secondMetadata)
        let result = first.withCString { firstPointer in
            second.withCString { secondPointer in
                Darwin.renameatx_np(
                    descriptor,
                    firstPointer,
                    descriptor,
                    secondPointer,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw NativeLocalLogError.io(.rename, errno)
        }
    }

    func synchronize() throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeLocalLogError.io(.sync, errno)
        }
    }

    func rotationFiles(
        activeFileName: String,
        maximumFileCount: Int
    ) throws -> [NativeLocalStoredFile] {
        let files = try allRotationFiles(activeFileName: activeFileName)
        var byIndex: [Int: NativeLocalStoredFile] = [:]
        for candidate in files {
            guard candidate.index < maximumFileCount else {
                continue
            }
            if let existing = byIndex[candidate.index] {
                if existing.compressed && !candidate.compressed {
                    byIndex[candidate.index] = candidate
                }
            } else {
                byIndex[candidate.index] = candidate
            }
        }
        return Array(byIndex.values)
    }

    func pinnedFiles(
        activeFileName: String,
        maximumFileCount: Int,
        activeCompletedSize: UInt64?,
        didEnumerate: (@Sendable () -> Void)?
    ) throws -> [NativeLocalPinnedFile] {
        var files = try rotationFiles(
            activeFileName: activeFileName,
            maximumFileCount: maximumFileCount
        )
        files.sort { $0.index > $1.index }
        if try fileExists(named: activeFileName) {
            files.append(
                NativeLocalStoredFile(name: activeFileName, index: 0, compressed: false)
            )
        }
        didEnumerate?()

        var pinned: [NativeLocalPinnedFile] = []
        pinned.reserveCapacity(files.count)
        do {
            for file in files {
                let fileDescriptor = try openReadableFile(named: file.name)
                do {
                    let observedSize = try fileSize(fileDescriptor)
                    let byteCount: UInt64
                    if file.index == 0, let activeCompletedSize {
                        // A store-owned reader must never expose bytes beyond the
                        // writer's last completed frame. If the file was shortened
                        // out of band (for example, while constructing a crash
                        // recovery fixture), pin the shorter inode boundary and let
                        // the decoder report the torn final frame.
                        byteCount = min(observedSize, activeCompletedSize)
                    } else {
                        byteCount = observedSize
                    }
                    pinned.append(
                        NativeLocalPinnedFile(
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

    func removeStaleRotations(
        activeFileName: String,
        maximumFileCount: Int
    ) throws {
        let files = try allRotationFiles(activeFileName: activeFileName)
        let grouped = Dictionary(grouping: files, by: \.index)
        var changed = false
        for (index, candidates) in grouped {
            if index >= maximumFileCount {
                for candidate in candidates {
                    try removeFileIfPresent(named: candidate.name)
                    changed = true
                }
                continue
            }
            if candidates.contains(where: { !$0.compressed }) {
                for candidate in candidates where candidate.compressed {
                    try removeFileIfPresent(named: candidate.name)
                    changed = true
                }
            }
        }
        if changed {
            try synchronize()
        }
    }

    func reconcileCompressionArtifacts(activeFileName: String) throws {
        let names = try entryNames()
        var changed = false
        for name in names
        where Self.isCanonicalCompressionTemporary(
            name,
            activeFileName: activeFileName
        ) {
            try removeFileIfPresent(named: name)
            changed = true
        }

        let grouped = Dictionary(
            grouping: try allRotationFiles(activeFileName: activeFileName),
            by: \.index
        )
        for candidates in grouped.values where candidates.count > 1 {
            guard candidates.contains(where: { !$0.compressed }) else {
                continue
            }
            for candidate in candidates where candidate.compressed {
                try removeFileIfPresent(named: candidate.name)
                changed = true
            }
        }
        if changed {
            try synchronize()
        }
    }

    func stageRotations(for transaction: NativeLocalRotationTransaction) throws {
        for file in try allRotationFiles(activeFileName: transaction.activeFileName) {
            let destination = transaction.stagedName(for: file)
            guard try !fileExists(named: destination) else {
                throw NativeLocalLogError.unsafeStorage
            }
            try renameFile(from: file.name, to: destination)
        }
    }

    func publishStagedRotations(
        for transaction: NativeLocalRotationTransaction,
        maximumFileCount: Int
    ) throws {
        let staged = try stagedRotations(for: transaction)
        let grouped = Dictionary(grouping: staged, by: \.index)
        for (index, candidates) in grouped {
            let selected = candidates.first(where: { !$0.compressed }) ?? candidates[0]
            for candidate in candidates where candidate.name != selected.name {
                try removeFileIfPresent(named: candidate.name)
            }

            let (destinationIndex, overflow) = index.addingReportingOverflow(1)
            guard !overflow, destinationIndex < maximumFileCount else {
                try removeFileIfPresent(named: selected.name)
                continue
            }
            let destination = Self.rotationName(
                activeFileName: transaction.activeFileName,
                index: destinationIndex,
                compressed: selected.compressed
            )
            if try fileExists(named: destination) {
                throw NativeLocalLogError.unsafeStorage
            }
            try renameFile(from: selected.name, to: destination)
        }

        if try fileExists(named: transaction.replacementName) {
            if maximumFileCount == 1 {
                try removeFileIfPresent(named: transaction.replacementName)
            } else {
                let destination = Self.rotationName(
                    activeFileName: transaction.activeFileName,
                    index: 1,
                    compressed: false
                )
                if try fileExists(named: destination) {
                    throw NativeLocalLogError.unsafeStorage
                }
                try renameFile(from: transaction.replacementName, to: destination)
            }
        } else if maximumFileCount > 1 {
            let destination = Self.rotationName(
                activeFileName: transaction.activeFileName,
                index: 1,
                compressed: false
            )
            guard try fileExists(named: destination) else {
                throw NativeLocalLogError.unsafeStorage
            }
        }
    }

    func removeRotationTransaction(_ transaction: NativeLocalRotationTransaction) throws {
        var changed = false
        for name in try entryNames() where transaction.containsArtifact(named: name) {
            try removeFileIfPresent(named: name)
            changed = true
        }
        if changed {
            try synchronize()
        }
    }

    func reconcileInterruptedRotation(
        activeFileName: String,
        maximumFileCount: Int
    ) throws {
        let names = try entryNames()
        let identifiers = Set(
            names.compactMap {
                NativeLocalRotationTransaction.parseIdentifier(
                    $0,
                    activeFileName: activeFileName
                )
            }
        )
        guard identifiers.count <= 1 else {
            throw NativeLocalLogError.unsafeStorage
        }
        guard let identifier = identifiers.first else {
            return
        }
        let transaction = NativeLocalRotationTransaction(
            activeFileName: activeFileName,
            identifier: identifier
        )
        let markerPhases = NativeLocalRotationPhase.allCases.filter {
            names.contains(transaction.markerName(for: $0))
        }
        guard markerPhases.count <= 1 else {
            throw NativeLocalLogError.unsafeStorage
        }

        var phase = markerPhases.first
        let replacementExists = try fileExists(named: transaction.replacementName)
        let activeExists = try fileExists(named: activeFileName)
        guard activeExists else {
            throw NativeLocalLogError.unsafeStorage
        }
        guard replacementExists else {
            if phase == .publishing {
                try publishStagedRotations(
                    for: transaction,
                    maximumFileCount: maximumFileCount
                )
                try removeTransactionMarkers(transaction)
                try synchronize()
                return
            }
            throw NativeLocalLogError.unsafeStorage
        }

        if phase == nil || phase == .prepared {
            let activeSize = try sizeOfNamedFile(activeFileName)
            let replacementSize = try sizeOfNamedFile(transaction.replacementName)
            let headerSize = UInt64(NativeLocalLogCodec.fileHeaderSize)
            if replacementSize == headerSize, activeSize > headerSize {
                try removeRotationTransaction(transaction)
                return
            }
            guard activeSize == headerSize, replacementSize > headerSize else {
                throw NativeLocalLogError.unsafeStorage
            }
            if phase == .prepared {
                try renameFile(
                    from: transaction.markerName(for: .prepared),
                    to: transaction.markerName(for: .swapped)
                )
            } else {
                try createRotationMarker(named: transaction.markerName(for: .swapped))
            }
            try synchronize()
            phase = .swapped
        }

        if phase == .swapped {
            try stageRotations(for: transaction)
            try renameFile(
                from: transaction.markerName(for: .swapped),
                to: transaction.markerName(for: .publishing)
            )
            try synchronize()
            phase = .publishing
        }

        guard phase == .publishing else {
            throw NativeLocalLogError.unsafeStorage
        }
        try publishStagedRotations(
            for: transaction,
            maximumFileCount: maximumFileCount
        )
        try removeTransactionMarkers(transaction)
        try synchronize()
    }

    private func allRotationFiles(activeFileName: String) throws -> [NativeLocalStoredFile] {
        try entryNames().compactMap { name in
            guard let parsed = Self.parseRotationName(name, activeFileName: activeFileName) else {
                return nil
            }
            return NativeLocalStoredFile(
                name: name,
                index: parsed.index,
                compressed: parsed.compressed
            )
        }
    }

    private func stagedRotations(
        for transaction: NativeLocalRotationTransaction
    ) throws -> [NativeLocalStoredFile] {
        try entryNames().compactMap { name in
            let prefix = "\(transaction.artifactPrefix)retained-"
            guard name.hasPrefix(prefix) else {
                return nil
            }
            let suffix = String(name.dropFirst(prefix.count))
            guard let parsed = Self.parseRotationSuffix(suffix) else {
                throw NativeLocalLogError.unsafeStorage
            }
            return NativeLocalStoredFile(
                name: name,
                index: parsed.index,
                compressed: parsed.compressed
            )
        }
    }

    private func removeTransactionMarkers(_ transaction: NativeLocalRotationTransaction) throws {
        for phase in NativeLocalRotationPhase.allCases {
            try removeFileIfPresent(named: transaction.markerName(for: phase))
        }
    }

    private func sizeOfNamedFile(_ name: String) throws -> UInt64 {
        let fileDescriptor = try openReadableFile(named: name)
        defer { Darwin.close(fileDescriptor) }
        return try fileSize(fileDescriptor)
    }

    private func entryNames() throws -> [String] {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else {
            throw NativeLocalLogError.io(.enumerate, errno)
        }
        guard let directory = fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            throw NativeLocalLogError.io(.enumerate, savedErrno)
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw NativeLocalLogError.io(.enumerate, errno)
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
        throw NativeLocalLogError.io(.metadata, errno)
    }

    private func validateRegularFile(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw NativeLocalLogError.io(.metadata, errno)
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
            permissions & mode_t(0o077) == 0
        else {
            throw NativeLocalLogError.unsafeStorage
        }
    }

    private static func openDirectory(_ url: URL, createIfAbsent: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw NativeLocalLogError.unsafeStorage
        }
        let canonicalPath = DarwinSystemDirectoryAlias.canonicalPath(for: url.path)
        let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard
            !components.isEmpty,
            components.allSatisfy({
                $0 != "." && $0 != ".." && !$0.utf8.contains(0) && $0.utf8.count <= 255
            })
        else {
            throw NativeLocalLogError.unsafeStorage
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            throw NativeLocalLogError.io(.open, errno)
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
                        throw NativeLocalLogError.io(.createDirectory, errno)
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
                    throw NativeLocalLogError.io(.open, errno)
                }
                Darwin.close(current)
                current = next
            }

            var metadata = stat()
            guard Darwin.fstat(current, &metadata) == 0 else {
                throw NativeLocalLogError.io(.metadata, errno)
            }
            guard
                metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                metadata.st_uid == getuid(),
                metadata.st_mode & mode_t(0o777) == Self.directoryMode
            else {
                throw NativeLocalLogError.unsafeStorage
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
        return parseRotationSuffix(String(name.dropFirst(prefix.count)))
    }

    private static func parseRotationSuffix(
        _ rawSuffix: String
    ) -> (index: Int, compressed: Bool)? {
        var suffix = rawSuffix
        let compressed = suffix.hasSuffix(".gz")
        if compressed {
            suffix.removeLast(3)
        }
        let bytes = Array(suffix.utf8)
        guard
            let first = bytes.first,
            (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(first),
            bytes.dropFirst().allSatisfy({
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            }),
            let index = Int(suffix),
            String(index) == suffix
        else {
            return nil
        }
        return (index, compressed)
    }

    private static func rotationName(
        activeFileName: String,
        index: Int,
        compressed: Bool
    ) -> String {
        "\(activeFileName).\(index)\(compressed ? ".gz" : "")"
    }

    private static func isCanonicalCompressionTemporary(
        _ name: String,
        activeFileName: String
    ) -> Bool {
        let prefix = "\(activeFileName)."
        guard name.hasPrefix(prefix) else {
            return false
        }
        let suffix = String(name.dropFirst(prefix.count))
        guard let range = suffix.range(of: ".gz.tmp.", options: .backwards) else {
            return false
        }
        let rotationSuffix = String(suffix[..<range.lowerBound]) + ".gz"
        guard parseRotationSuffix(rotationSuffix)?.compressed == true else {
            return false
        }
        let identifier = String(suffix[range.upperBound...])
        guard let uuid = UUID(uuidString: identifier) else {
            return false
        }
        return uuid.uuidString == identifier
    }
}

private enum NativeLocalFileSystem {
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
                    throw NativeLocalLogError.io(.write, errno)
                }
                written += result
            }
        }
    }

    static func readExactly(from descriptor: Int32, count: Int, offset: UInt64) throws -> Data {
        guard count >= 0, offset <= UInt64(Int64.max) else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { buffer in
            while total < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: total),
                    buffer.count - total,
                    off_t(offset) + off_t(total)
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    if result < 0 {
                        throw NativeLocalLogError.io(.read, errno)
                    }
                    throw NativeLocalLogError.unsafeStorage
                }
                total += result
            }
        }
        return data
    }

    static func truncate(_ descriptor: Int32, to size: UInt64) throws {
        guard size <= UInt64(Int64.max) else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        guard Darwin.ftruncate(descriptor, off_t(size)) == 0 else {
            throw NativeLocalLogError.io(.truncate, errno)
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NativeLocalLogError.io(.sync, errno)
        }
    }

    static func rollback(_ descriptor: Int32, to size: UInt64) -> Bool {
        guard
            descriptor >= 0,
            size <= UInt64(off_t.max),
            Darwin.ftruncate(descriptor, off_t(size)) == 0,
            Darwin.fsync(descriptor) == 0
        else {
            return false
        }
        return true
    }

    static func hasValidFrame(
        descriptor: Int32,
        after offset: UInt64,
        fileSize: UInt64
    ) throws -> Bool {
        let scanStart = offset + 1
        guard scanStart < fileSize else {
            return false
        }
        let available = fileSize - scanStart
        let scanCount = min(
            available,
            UInt64(NativeLocalLogCodec.maximumEncodedFrameBytes)
        )
        guard scanCount <= UInt64(Int.max) else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        let scan = try readExactly(
            from: descriptor,
            count: Int(scanCount),
            offset: scanStart
        )
        guard scan.count >= NativeLocalLogCodec.framePrefixSize else {
            return false
        }
        let lastCandidate = scan.count - NativeLocalLogCodec.framePrefixSize
        for relativeOffset in 0...lastCandidate
        where NativeLocalLogCodec.hasFrameMagic(scan, at: relativeOffset) {
            let prefix = Data(
                scan[relativeOffset..<(relativeOffset + NativeLocalLogCodec.framePrefixSize)]
            )
            guard
                let bodyLength = try? NativeLocalLogCodec.bodyLength(fromFramePrefix: prefix),
                let frameLength = try? NativeLocalLogCodec.frameLength(bodyLength: bodyLength)
            else {
                continue
            }
            let candidateOffset = scanStart + UInt64(relativeOffset)
            guard UInt64(frameLength) <= fileSize - candidateOffset else {
                continue
            }
            let frame = try readExactly(
                from: descriptor,
                count: frameLength,
                offset: candidateOffset
            )
            if (try? NativeLocalLogCodec.decode(frame)) != nil {
                return true
            }
        }
        return false
    }
}

private enum NativeLocalGzip {
    private static let header: [UInt8] = [
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    ]
    private static let chunkSize = 64 * 1024

    static func compress(source: Int32, destination: Int32) throws {
        try NativeLocalFileSystem.writeAll(Data(header), to: destination)

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
            throw NativeLocalLogError.compressionFailed
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
                        throw NativeLocalLogError.io(.read, errno)
                    }
                    return result
                }
            }
            guard count > 0 else {
                break
            }
            crc = NativeLocalGzipCRC32.update(crc, bytes: input[0..<count])
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
        try NativeLocalFileSystem.writeAll(trailer, to: destination)
    }

    static func decompress(_ data: Data, maximumDecodedBytes: Int) throws -> Data {
        guard maximumDecodedBytes > 0 else {
            throw NativeLocalLogError.storageLimitExceeded
        }
        let deflateRange = try deflatePayloadRange(data)
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
            compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR
        else {
            throw NativeLocalLogError.compressionFailed
        }
        defer { compression_stream_destroy(&stream) }

        var decoded = Data()
        var output = [UInt8](repeating: 0, count: chunkSize)
        try data.withUnsafeBytes { inputBuffer in
            guard let source = inputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw NativeLocalLogError.compressionFailed
            }
            stream.src_ptr = source.advanced(by: deflateRange.lowerBound)
            stream.src_size = deflateRange.count
            while true {
                let status = try output.withUnsafeMutableBytes { outputBuffer -> compression_status in
                    guard let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        throw NativeLocalLogError.compressionFailed
                    }
                    stream.dst_ptr = destination
                    stream.dst_size = outputBuffer.count
                    return compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw NativeLocalLogError.compressionFailed
                }
                let produced = output.count - stream.dst_size
                guard produced <= maximumDecodedBytes - decoded.count else {
                    throw NativeLocalLogError.storageLimitExceeded
                }
                if produced > 0 {
                    decoded.append(contentsOf: output[0..<produced])
                }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else {
                        throw NativeLocalLogError.compressionFailed
                    }
                    break
                }
                guard status == COMPRESSION_STATUS_OK, produced > 0 else {
                    throw NativeLocalLogError.compressionFailed
                }
            }
        }

        let expectedSize = readLittleEndianUInt32(data, at: data.count - 4)
        guard UInt32(truncatingIfNeeded: decoded.count) == expectedSize else {
            throw NativeLocalLogError.compressionFailed
        }
        let expectedCRC = readLittleEndianUInt32(data, at: data.count - 8)
        guard NativeLocalGzipCRC32.checksum(decoded) == expectedCRC else {
            throw NativeLocalLogError.compressionFailed
        }
        return decoded
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
                throw NativeLocalLogError.compressionFailed
            }
            stream.src_ptr = source
            stream.src_size = inputBuffer.count
            repeat {
                let status = try output.withUnsafeMutableBytes { outputBuffer -> compression_status in
                    guard let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        throw NativeLocalLogError.compressionFailed
                    }
                    stream.dst_ptr = destination
                    stream.dst_size = outputBuffer.count
                    return compression_stream_process(&stream, flags)
                }
                guard status != COMPRESSION_STATUS_ERROR, status != COMPRESSION_STATUS_END else {
                    throw NativeLocalLogError.compressionFailed
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    try NativeLocalFileSystem.writeAll(Data(output[0..<produced]), to: destination)
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
                    throw NativeLocalLogError.compressionFailed
                }
                stream.dst_ptr = destination
                stream.dst_size = outputBuffer.count
                return compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
            }
            guard status != COMPRESSION_STATUS_ERROR else {
                throw NativeLocalLogError.compressionFailed
            }
            let produced = output.count - stream.dst_size
            if produced > 0 {
                try NativeLocalFileSystem.writeAll(Data(output[0..<produced]), to: destination)
            }
            if status == COMPRESSION_STATUS_END {
                return
            }
        }
    }

    private static func deflatePayloadRange(_ data: Data) throws -> Range<Int> {
        guard
            data.count >= header.count + 8,
            data[0] == 0x1f,
            data[1] == 0x8b,
            data[2] == 0x08,
            data[3] == 0
        else {
            throw NativeLocalLogError.compressionFailed
        }
        return header.count..<(data.count - 8)
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

private enum NativeLocalGzipCRC32 {
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

/// Bounded physical-segment validator used by logging handoff import.
package enum NativeLocalLogHandoffSegmentValidator {
    package static func inspect(
        _ bytes: Data,
        compressed: Bool
    ) throws -> NativeLocalLogHandoffSegmentInspection {
        let decoded: Data
        if compressed {
            decoded = try NativeLocalGzip.decompress(
                bytes,
                maximumDecodedBytes:
                    NativeLocalLogHandoffSegmentCodec.maximumDecodedSegmentBytes
            )
        } else {
            decoded = bytes
        }
        return try NativeLocalLogHandoffSegmentCodec.inspect(decoded)
    }
}
/// Read-only export of every retained native-local physical segment.
///
/// Exact stored bytes are captured from already-open pinned inodes. No writer
/// is opened and no interrupted-rotation recovery is performed on the source
/// evidence path.
package enum NativeLocalLogHandoffSegmentExporter {
    package static func snapshot(
        directoryURL: URL,
        activeFileName: String
    ) throws -> [ContainerLogHandoffSegmentSnapshot] {
        try NativeLocalSecureDirectory.validateActiveFileName(activeFileName)
        let directory = try NativeLocalSecureDirectory(
            url: directoryURL,
            createIfAbsent: false
        )
        let files = try directory.pinnedFiles(
            activeFileName: activeFileName,
            maximumFileCount: 4097,
            activeCompletedSize: nil,
            didEnumerate: nil
        )
        return try files.map { file in
            guard
                file.index >= 0,
                file.byteCount <= UInt64(
                    NativeLocalLogHandoffSegmentCodec.maximumDecodedSegmentBytes
                ),
                file.byteCount <= UInt64(Int.max)
            else {
                throw NativeLocalLogError.storageLimitExceeded
            }
            let bytes = try NativeLocalFileSystem.readExactly(
                from: file.descriptor,
                count: Int(file.byteCount),
                offset: 0
            )
            _ = try NativeLocalLogHandoffSegmentValidator.inspect(
                bytes,
                compressed: file.compressed
            )
            var metadata = stat()
            guard Darwin.fstat(file.descriptor, &metadata) == 0 else {
                throw NativeLocalLogError.io(.metadata, errno)
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
