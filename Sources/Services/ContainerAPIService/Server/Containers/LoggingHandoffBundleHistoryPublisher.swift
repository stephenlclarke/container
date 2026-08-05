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

import ContainerEngineRuntimeSPI
import ContainerResource
import Darwin
import Foundation

enum LoggingHandoffBundleHistoryPublisherError: Error, Equatable, Sendable {
    case collision
    case invalidHistory
    case unsafeStorage
    case io(Int32)
}

/// Atomically publishes one complete immutable history directory per local
/// store kind. A crash leaves either a hidden deterministic temporary
/// directory or the exact final directory; replay validates and resumes it.
enum LoggingHandoffBundleHistoryPublisher {
    private static let loggingRootName = "logging-v2"
    private static let maximumDirectoryEntries = 4_096

    static func publish(
        bundle: ContainerResource.Bundle,
        segments: [LoggingHandoffPromotedHistorySegmentV1],
        transactionID: String
    ) throws {
        let grouped = Dictionary(grouping: segments, by: \.kind)
        guard
            grouped.count <= 1,
            grouped.keys.allSatisfy({
                $0 == .dockerJSONFile || $0 == .nativeLocal
                    || $0 == .dualCache
            })
        else {
            throw LoggingHandoffBundleHistoryPublisherError.invalidHistory
        }
        let bundleDescriptor = try openDirectory(
            bundle.path,
            expectedMode: nil,
            create: false
        )
        defer { Darwin.close(bundleDescriptor) }
        let loggingDescriptor = try openOrCreateDirectory(
            parent: bundleDescriptor,
            name: loggingRootName,
            mode: mode_t(0o700)
        )
        defer { Darwin.close(loggingDescriptor) }

        let transactionDigest = ProviderHandoffDigest.sha256(
            Data(transactionID.utf8)
        )
        for kind in grouped.keys.sorted(by: {
            $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8)
        }) {
            guard let values = grouped[kind] else { continue }
            try publishDirectory(
                values,
                kind: kind,
                transactionDigest: transactionDigest,
                loggingDescriptor: loggingDescriptor
            )
        }
    }

    private static func publishDirectory(
        _ segments: [LoggingHandoffPromotedHistorySegmentV1],
        kind: LoggingHandoffHistoryKindV1,
        transactionDigest: String,
        loggingDescriptor: Int32
    ) throws {
        let target = directoryName(kind)
        let temporary = ".handoff-\(target)-\(transactionDigest)"
        let ordered = try orderedSegments(segments, kind: kind)

        if let existing = try openDirectoryIfPresent(
            parent: loggingDescriptor,
            name: target,
            expectedMode: mode_t(0o700)
        ) {
            defer { Darwin.close(existing) }
            try validateDirectory(existing, segments: ordered, kind: kind)
            try removeTemporaryIfPresent(
                parent: loggingDescriptor,
                name: temporary,
                segments: ordered,
                kind: kind
            )
            return
        }

        let temporaryDescriptor: Int32
        if let existing = try openDirectoryIfPresent(
            parent: loggingDescriptor,
            name: temporary,
            expectedMode: mode_t(0o700)
        ) {
            do {
                try validateDirectory(existing, segments: ordered, kind: kind)
                temporaryDescriptor = existing
            } catch {
                Darwin.close(existing)
                try removeTemporaryIfPresent(
                    parent: loggingDescriptor,
                    name: temporary,
                    segments: nil,
                    kind: kind
                )
                temporaryDescriptor = try createDirectory(
                    parent: loggingDescriptor,
                    name: temporary,
                    mode: mode_t(0o700)
                )
                try write(ordered, kind: kind, directory: temporaryDescriptor)
            }
        } else {
            temporaryDescriptor = try createDirectory(
                parent: loggingDescriptor,
                name: temporary,
                mode: mode_t(0o700)
            )
            try write(ordered, kind: kind, directory: temporaryDescriptor)
        }
        defer { Darwin.close(temporaryDescriptor) }
        try validateDirectory(
            temporaryDescriptor,
            segments: ordered,
            kind: kind
        )
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        let result = temporary.withCString { source in
            target.withCString { destination in
                Darwin.renameatx_np(
                    loggingDescriptor,
                    source,
                    loggingDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if result != 0 {
            let code = errno
            guard code == EEXIST,
                let existing = try openDirectoryIfPresent(
                    parent: loggingDescriptor,
                    name: target,
                    expectedMode: mode_t(0o700)
                )
            else {
                throw LoggingHandoffBundleHistoryPublisherError.io(code)
            }
            defer { Darwin.close(existing) }
            try validateDirectory(existing, segments: ordered, kind: kind)
            try removeTemporaryIfPresent(
                parent: loggingDescriptor,
                name: temporary,
                segments: ordered,
                kind: kind
            )
        }
        guard Darwin.fsync(loggingDescriptor) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
    }

    private static func write(
        _ segments: [LoggingHandoffPromotedHistorySegmentV1],
        kind: LoggingHandoffHistoryKindV1,
        directory: Int32
    ) throws {
        for group in fileGroups(segments) {
            let mode =
                kind == .dockerJSONFile
                ? mode_t(0o640) : mode_t(0o600)
            let descriptor = group.name.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode
                )
            }
            guard descriptor >= 0 else {
                throw LoggingHandoffBundleHistoryPublisherError.io(errno)
            }
            defer { Darwin.close(descriptor) }
            try validateRegular(descriptor, expectedMode: mode)
            for segment in group.segments {
                try writeAll(segment.bytes, descriptor: descriptor)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw LoggingHandoffBundleHistoryPublisherError.io(errno)
            }
        }
        guard Darwin.fsync(directory) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        segments: [LoggingHandoffPromotedHistorySegmentV1],
        kind: LoggingHandoffHistoryKindV1
    ) throws {
        let names = try directoryEntries(descriptor)
        guard names == Set(segments.map(\.destinationFileName)) else {
            throw LoggingHandoffBundleHistoryPublisherError.collision
        }
        let expectedMode =
            kind == .dockerJSONFile
            ? mode_t(0o640) : mode_t(0o600)
        for group in fileGroups(segments) {
            let file = group.name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard file >= 0 else {
                throw LoggingHandoffBundleHistoryPublisherError.io(errno)
            }
            defer { Darwin.close(file) }
            try validateRegular(file, expectedMode: expectedMode)
            try validateContents(file, segments: group.segments)
        }
    }

    private static func orderedSegments(
        _ segments: [LoggingHandoffPromotedHistorySegmentV1],
        kind: LoggingHandoffHistoryKindV1
    ) throws -> [LoggingHandoffPromotedHistorySegmentV1] {
        guard !segments.isEmpty else {
            throw LoggingHandoffBundleHistoryPublisherError.invalidHistory
        }
        let chunked = segments.compactMap { segment in
            segment.portableChunk.map { (segment: segment, value: $0) }
        }
        if !chunked.isEmpty {
            let ordered = chunked.sorted {
                $0.value.index < $1.value.index
            }
            guard
                chunked.count == segments.count,
                kind == .dockerJSONFile,
                ordered.allSatisfy({
                    $0.segment.rotationIndex == 0 && !$0.segment.compressed
                }),
                let count = ordered.first?.value.count,
                count == UInt64(ordered.count),
                ordered.allSatisfy({ $0.value.count == count }),
                ordered.enumerated().allSatisfy({ offset, value in
                    value.value.index == UInt64(offset)
                }),
                Set(ordered.map(\.segment.terminalHistoryEpoch)).count == 1,
                Set(ordered.map(\.segment.maximumInternalSequence)).count == 1
            else {
                throw LoggingHandoffBundleHistoryPublisherError.invalidHistory
            }
            return ordered.map(\.segment)
        }
        guard
            !segments.contains(where: {
                $0.storeID.hasPrefix(
                    ProviderHandoffPortableLoggingPayloadCodec.historyStoreID
                        + ".chunk."
                )
            })
        else {
            throw LoggingHandoffBundleHistoryPublisherError.invalidHistory
        }
        let ordered = segments.sorted { $0.rotationIndex < $1.rotationIndex }
        guard
            ordered.first?.rotationIndex == 0,
            Set(ordered.map(\.destinationFileName)).count == ordered.count
        else {
            throw LoggingHandoffBundleHistoryPublisherError.invalidHistory
        }
        return ordered
    }

    private static func fileGroups(
        _ segments: [LoggingHandoffPromotedHistorySegmentV1]
    ) -> [(name: String, segments: [LoggingHandoffPromotedHistorySegmentV1])] {
        var result: [(name: String, segments: [LoggingHandoffPromotedHistorySegmentV1])] = []
        for segment in segments {
            if result.last?.name == segment.destinationFileName {
                result[result.count - 1].segments.append(segment)
            } else {
                result.append((segment.destinationFileName, [segment]))
            }
        }
        return result
    }

    private static func validateContents(
        _ descriptor: Int32,
        segments: [LoggingHandoffPromotedHistorySegmentV1]
    ) throws {
        var expectedSize: UInt64 = 0
        for segment in segments {
            let (next, overflow) = expectedSize.addingReportingOverflow(
                UInt64(segment.bytes.count)
            )
            guard
                !overflow,
                ProviderHandoffDigest.sha256(segment.bytes)
                    == segment.contentDigestSHA256
            else {
                throw LoggingHandoffBundleHistoryPublisherError.collision
            }
            expectedSize = next
        }
        var metadata = stat()
        guard
            expectedSize <= UInt64(Int64.max),
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_size == off_t(expectedSize)
        else {
            throw LoggingHandoffBundleHistoryPublisherError.collision
        }
        var offset: UInt64 = 0
        for segment in segments {
            let data = try readExactly(
                descriptor,
                count: segment.bytes.count,
                offset: offset
            )
            guard data == segment.bytes else {
                throw LoggingHandoffBundleHistoryPublisherError.collision
            }
            offset += UInt64(segment.bytes.count)
        }
    }

    private static func removeTemporaryIfPresent(
        parent: Int32,
        name: String,
        segments: [LoggingHandoffPromotedHistorySegmentV1]?,
        kind: LoggingHandoffHistoryKindV1
    ) throws {
        guard
            let descriptor = try openDirectoryIfPresent(
                parent: parent,
                name: name,
                expectedMode: mode_t(0o700)
            )
        else { return }
        defer { Darwin.close(descriptor) }
        if let segments {
            try validateDirectory(descriptor, segments: segments, kind: kind)
        }
        let names = try directoryEntries(descriptor)
        for entry in names {
            guard entry.hasPrefix(activeName(kind)) else {
                throw LoggingHandoffBundleHistoryPublisherError.unsafeStorage
            }
            let result = entry.withCString {
                Darwin.unlinkat(descriptor, $0, 0)
            }
            guard result == 0 || errno == ENOENT else {
                throw LoggingHandoffBundleHistoryPublisherError.io(errno)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        let result = name.withCString { Darwin.unlinkat(parent, $0, AT_REMOVEDIR) }
        guard result == 0 || errno == ENOENT else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        guard Darwin.fsync(parent) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
    }

    private static func directoryEntries(_ descriptor: Int32) throws -> Set<String> {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        defer { closedir(directory) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumDirectoryEntries, names.insert(name).inserted else {
                throw LoggingHandoffBundleHistoryPublisherError.unsafeStorage
            }
        }
        guard errno == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        return names
    }

    private static func directoryName(_ kind: LoggingHandoffHistoryKindV1) -> String {
        switch kind {
        case .dockerJSONFile: "json-file"
        case .nativeLocal: "local"
        case .dualCache: "cache"
        case .legacyLocalV1, .providerOwned:
            preconditionFailure("non-local history has no bundle directory")
        }
    }

    private static func activeName(_ kind: LoggingHandoffHistoryKindV1) -> String {
        switch kind {
        case .dockerJSONFile: ContainerResource.Bundle.jsonFileLogName
        case .nativeLocal: ContainerResource.Bundle.nativeLocalLogName
        case .dualCache: ContainerResource.Bundle.nativeLogCacheName
        case .legacyLocalV1, .providerOwned:
            preconditionFailure("non-local history has no active filename")
        }
    }

    private static func openDirectory(
        _ url: URL,
        expectedMode: mode_t?,
        create: Bool
    ) throws -> Int32 {
        if create, mkdir(url.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        do {
            try validateDirectoryMetadata(descriptor, expectedMode: expectedMode)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openOrCreateDirectory(
        parent: Int32,
        name: String,
        mode: mode_t
    ) throws -> Int32 {
        if name.withCString({ Darwin.mkdirat(parent, $0, mode) }) != 0,
            errno != EEXIST
        {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        guard
            let descriptor = try openDirectoryIfPresent(
                parent: parent,
                name: name,
                expectedMode: mode
            )
        else {
            throw LoggingHandoffBundleHistoryPublisherError.io(ENOENT)
        }
        return descriptor
    }

    private static func createDirectory(
        parent: Int32,
        name: String,
        mode: mode_t
    ) throws -> Int32 {
        guard name.withCString({ Darwin.mkdirat(parent, $0, mode) }) == 0 else {
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        guard
            let descriptor = try openDirectoryIfPresent(
                parent: parent,
                name: name,
                expectedMode: mode
            )
        else {
            throw LoggingHandoffBundleHistoryPublisherError.io(ENOENT)
        }
        return descriptor
    }

    private static func openDirectoryIfPresent(
        parent: Int32,
        name: String,
        expectedMode: mode_t
    ) throws -> Int32? {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw LoggingHandoffBundleHistoryPublisherError.io(errno)
        }
        do {
            try validateDirectoryMetadata(
                descriptor,
                expectedMode: expectedMode
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectoryMetadata(
        _ descriptor: Int32,
        expectedMode: mode_t?
    ) throws {
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == Darwin.geteuid(),
            expectedMode.map({ metadata.st_mode & mode_t(0o777) == $0 })
                ?? true
        else {
            throw LoggingHandoffBundleHistoryPublisherError.unsafeStorage
        }
    }

    private static func validateRegular(
        _ descriptor: Int32,
        expectedMode: mode_t
    ) throws {
        var metadata = stat()
        guard
            Darwin.fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == Darwin.geteuid(),
            metadata.st_nlink == 1,
            metadata.st_mode & mode_t(0o777) == expectedMode
        else {
            throw LoggingHandoffBundleHistoryPublisherError.unsafeStorage
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        let count = data.count
        while offset < count {
            let result = data.withUnsafeBytes {
                Darwin.write(
                    descriptor,
                    $0.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw LoggingHandoffBundleHistoryPublisherError.io(
                    result == 0 ? EIO : errno
                )
            }
            offset += result
        }
    }

    private static func readExactly(
        _ descriptor: Int32,
        count: Int,
        offset initialOffset: UInt64
    ) throws -> Data {
        guard initialOffset <= UInt64(Int64.max) else {
            throw LoggingHandoffBundleHistoryPublisherError.unsafeStorage
        }
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { buffer in
            while offset < count {
                let readCount = Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset,
                    off_t(initialOffset + UInt64(offset))
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    throw LoggingHandoffBundleHistoryPublisherError.io(
                        readCount == 0 ? EIO : errno
                    )
                }
                offset += readCount
            }
        }
        return result
    }
}
