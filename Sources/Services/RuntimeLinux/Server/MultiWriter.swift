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

import Containerization
import Foundation

/// Fans container output out to caller-attached stdio and durable log writers.
/// A failed consumer is removed without preventing the remaining consumers
/// from receiving the same and subsequent writes.
final class MultiWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [any Writer]

    init(handles: [FileHandle]) {
        self.writers = handles
    }

    init(writers: [any Writer]) {
        self.writers = writers
    }

    var liveWriterCount: Int {
        lock.withLock { writers.count }
    }

    func close() throws {
        let current = lock.withLock {
            let current = writers
            writers.removeAll()
            return current
        }

        var lastError: (any Error)?
        var failureCount = 0
        for writer in current {
            do {
                try writer.close()
            } catch {
                failureCount += 1
                lastError = error
            }
        }
        if failureCount == current.count, let lastError {
            throw lastError
        }
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            var surviving: [any Writer] = []
            surviving.reserveCapacity(writers.count)
            var lastError: (any Error)?
            for writer in writers {
                do {
                    try writer.write(data)
                    surviving.append(writer)
                } catch {
                    lastError = error
                    try? writer.close()
                }
            }
            writers = surviving
            if surviving.isEmpty, let lastError {
                throw lastError
            }
        }
    }
}
