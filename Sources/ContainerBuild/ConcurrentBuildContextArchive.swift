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

import ContainerAPIClient
import ContainerizationArchive
import CryptoKit
import Foundation

enum ConcurrentBuildContextArchive {
    @concurrent
    static func run(
        _ operation: @Sendable @escaping () throws -> SHA256.Digest
    ) async throws -> SHA256.Digest {
        try Task.checkCancellation()
        return try operation()
    }

    static func archive(
        contextDir: URL,
        destination: URL,
        includedPaths: Set<String>
    ) async throws -> SHA256.Digest {
        try await run {
            let writerConfiguration = ArchiveWriterConfiguration(
                format: .paxRestricted,
                filter: .none)
            _ = try Archiver.compress(
                source: contextDir,
                destination: destination,
                writerConfiguration: writerConfiguration
            ) { url in
                guard
                    let rel = try? url.relativeChildPath(to: contextDir),
                    includedPaths.contains(rel)
                else {
                    return nil
                }

                return Archiver.ArchiveEntryInfo(
                    pathOnHost: url,
                    pathInArchive: URL(fileURLWithPath: rel))
            }

            let archive = try FileHandle(forReadingFrom: destination)
            defer { try? archive.close() }
            var hasher = SHA256()
            while let chunk = try archive.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize()
        }
    }
}
