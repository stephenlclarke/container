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

import ContainerizationArchive
import ContainerizationExtras
import CryptoKit
import Foundation

enum ConcurrentKernelArchiveIO {
    @concurrent
    static func run<Result: Sendable>(
        _ operation: @Sendable @escaping () throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        return try operation()
    }

    static func digest(of file: URL) async throws -> String {
        try await run {
            try sha256Hex(of: file)
        }
    }

    static func extractFile(tarFile: URL, at path: String, to directory: URL) async throws -> URL {
        try await run {
            var target = path
            var archiveReader = try ArchiveReader(file: tarFile)
            var (entry, data) = try archiveReader.extractFile(path: target)

            // Reopen the archive after reading a symlink because extractFile
            // advances the reader before the target is resolved.
            if entry.fileType == .symbolicLink, let symlinkRelative = entry.symlinkTarget {
                archiveReader = try ArchiveReader(file: tarFile)
                let symlinkTarget = URL(filePath: target).deletingLastPathComponent().appending(path: symlinkRelative)
                // Normalize relative path components before locating the target entry.
                target = symlinkTarget.standardized.relativePath
                let (_, targetData) = try archiveReader.extractFile(path: target)
                data = targetData
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let fileName = URL(filePath: target).lastPathComponent
            let fileURL = directory.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    static func sha256Hex(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: Int(1.mib())), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
