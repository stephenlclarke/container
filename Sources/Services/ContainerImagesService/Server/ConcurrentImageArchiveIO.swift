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
import Foundation

enum ConcurrentImageArchiveIO {
    @concurrent
    static func run<Result: Sendable>(
        _ operation: @Sendable @escaping () throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        return try operation()
    }

    static func writeDirectory(_ source: URL, to destination: URL) async throws {
        try await run {
            let writer = try ArchiveWriter(format: .pax, filter: .none, file: destination)
            try writer.archiveDirectory(source)
            try writer.finishEncoding()
        }
    }

    static func extract(_ source: URL, to destination: URL) async throws -> [String] {
        try await run {
            let reader = try ArchiveReader(file: source)
            return try reader.extractContents(to: destination)
        }
    }
}
