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

import CryptoKit
import Darwin
import Foundation

/// Immutable physical file evidence captured from a pinned local log inode.
///
/// Handoff carries the exact stored representation, including gzip bytes, so
/// destination publication never repairs, re-encodes, or re-sequences source
/// history.
package struct ContainerLogHandoffSegmentSnapshot: Equatable, Sendable {
    package let rotationIndex: UInt64
    package let compressed: Bool
    package let sourceDeviceID: UInt64
    package let sourceInode: UInt64
    package let bytes: Data

    package init(
        rotationIndex: UInt64,
        compressed: Bool,
        sourceDeviceID: UInt64,
        sourceInode: UInt64,
        bytes: Data
    ) {
        self.rotationIndex = rotationIndex
        self.compressed = compressed
        self.sourceDeviceID = sourceDeviceID
        self.sourceInode = sourceInode
        self.bytes = bytes
    }
}

/// Private file-backed snapshot used by bounded handoff export.
package struct ContainerLogHandoffSegmentFileSnapshot: Equatable, Sendable {
    package let rotationIndex: UInt64
    package let compressed: Bool
    package let sourceDeviceID: UInt64
    package let sourceInode: UInt64
    package let byteLength: UInt64
    package let contentDigestSHA256: String
    package let maximumInternalSequence: UInt64
    package let fileURL: URL
}

package enum ContainerLogHandoffSegmentFileCopier {
    private static let copyChunkBytes = 64 * 1024

    package static func copy(
        descriptor: Int32,
        byteLength: UInt64,
        rotationIndex: UInt64,
        compressed: Bool,
        maximumInternalSequence: UInt64,
        destinationDirectoryURL: URL
    ) throws -> ContainerLogHandoffSegmentFileSnapshot {
        guard byteLength <= UInt64(Int64.max) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var sourceMetadata = stat()
        guard
            Darwin.fstat(descriptor, &sourceMetadata) == 0,
            sourceMetadata.st_mode & S_IFMT == S_IFREG,
            sourceMetadata.st_nlink == 1,
            sourceMetadata.st_size == off_t(byteLength)
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let target = destinationDirectoryURL.appendingPathComponent(
            "segment-\(rotationIndex)-\(UUID().uuidString).bin",
            isDirectory: false
        )
        let targetDescriptor = target.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard targetDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = FileHandle(
            fileDescriptor: targetDescriptor,
            closeOnDealloc: true
        )
        var completed = false
        defer {
            try? output.close()
            if !completed {
                _ = target.path.withCString(Darwin.unlink)
            }
        }
        var digest = SHA256()
        var offset: UInt64 = 0
        while offset < byteLength {
            let count = Int(
                min(UInt64(copyChunkBytes), byteLength - offset)
            )
            var chunk = Data(count: count)
            let readCount = try chunk.withUnsafeMutableBytes { buffer in
                var completedBytes = 0
                while completedBytes < count {
                    let result = Darwin.pread(
                        descriptor,
                        buffer.baseAddress?.advanced(by: completedBytes),
                        count - completedBytes,
                        off_t(offset + UInt64(completedBytes))
                    )
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    completedBytes += result
                }
                return completedBytes
            }
            guard readCount == count else {
                throw CocoaError(.fileReadUnknown)
            }
            try output.write(contentsOf: chunk)
            digest.update(data: chunk)
            offset += UInt64(count)
        }
        try output.synchronize()
        try output.close()
        completed = true
        return ContainerLogHandoffSegmentFileSnapshot(
            rotationIndex: rotationIndex,
            compressed: compressed,
            sourceDeviceID: UInt64(sourceMetadata.st_dev),
            sourceInode: UInt64(sourceMetadata.st_ino),
            byteLength: byteLength,
            contentDigestSHA256:
                Data(digest.finalize()).map {
                    String(format: "%02x", $0)
                }.joined(),
            maximumInternalSequence: maximumInternalSequence,
            fileURL: target
        )
    }
}
