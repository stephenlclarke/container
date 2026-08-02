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
import Darwin
import Foundation

package enum ContainerLogReaderStreamFormat: Sendable {
    case raw
    case structuredRecords
}

/// Adapts the pull-based retained reader to one XPC-transferable stream.
///
/// A socket pair is intentional: unlike a one-way pipe, its server endpoint
/// can observe peer EOF while `next()` is suspended. Closing the client handle
/// therefore cancels the retained reader immediately and releases its bounded
/// history/live-buffer allocation even when no later record is published.
package enum ContainerLogReaderStream {
    package static func open(
        reader: any ContainerLogReader,
        format: ContainerLogReaderStreamFormat
    ) throws -> FileHandle {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let server = FileHandle(
            fileDescriptor: descriptors[0],
            closeOnDealloc: true
        )
        let client = FileHandle(
            fileDescriptor: descriptors[1],
            closeOnDealloc: true
        )

        server.readabilityHandler = { handle in
            do {
                if try handle.read(upToCount: 1)?.isEmpty != false {
                    handle.readabilityHandler = nil
                    Task { await reader.cancel() }
                }
            } catch {
                handle.readabilityHandler = nil
                Task { await reader.cancel() }
            }
        }

        Task.detached(priority: .utility) {
            defer {
                server.readabilityHandler = nil
                try? server.close()
            }
            let encoder = JSONEncoder()
            do {
                while true {
                    switch try await reader.next() {
                    case .record(let record):
                        switch format {
                        case .raw:
                            try server.write(contentsOf: record.data)
                        case .structuredRecords:
                            try server.write(
                                contentsOf: try encoder.encode(
                                    ContainerLogRecord(record)
                                )
                            )
                            try server.write(
                                contentsOf: Data([UInt8(ascii: "\n")])
                            )
                        }
                    case .endOfStream:
                        return
                    }
                }
            } catch {
                await reader.cancel()
            }
        }
        return client
    }
}

extension ContainerLogRecord {
    fileprivate init(_ record: ContainerLogReadRecordV1) {
        self.init(
            timestamp: Date(
                timeIntervalSince1970:
                    Double(record.timestamp.secondsSinceUnixEpoch)
                    + Double(record.timestamp.nanoseconds) / 1_000_000_000
            ),
            stream: record.stream == .stdout ? .stdout : .stderr,
            data: record.data
        )
    }
}
