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

import ContainerLoggingStorage
import ContainerResource
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct ContainerLogReaderStreamTests {
    @Test
    func emitsRawAndStructuredRecords() async throws {
        let records = [
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1_767_323_045,
                    nanoseconds: 123_456_789
                ),
                data: Data("stdout\n".utf8),
                attributes: ["compose.service": "web"],
                sequence: 1,
                processGeneration: 4
            ),
            try ContainerLogReadRecordV1(
                stream: .stderr,
                timestamp: ContainerLogTimestamp(
                    secondsSinceUnixEpoch: 1_767_323_046,
                    nanoseconds: 987_654_321
                ),
                data: Data("stderr\n".utf8),
                sequence: 2,
                processGeneration: 4
            ),
        ]

        let rawHandle = try ContainerLogReaderStream.open(
            reader: ContainerLogBufferedReader(records: records),
            format: .raw
        )
        defer { try? rawHandle.close() }
        #expect(
            try rawHandle.readToEnd()
                == Data("stdout\nstderr\n".utf8)
        )

        let structuredHandle = try ContainerLogReaderStream.open(
            reader: ContainerLogBufferedReader(records: records),
            format: .structuredRecords
        )
        defer { try? structuredHandle.close() }
        let structuredData = try #require(try structuredHandle.readToEnd())
        let decoded =
            try structuredData
            .split(separator: UInt8(ascii: "\n"))
            .map {
                try JSONDecoder().decode(
                    ContainerLogRecord.self,
                    from: Data($0)
                )
            }

        #expect(decoded.map(\.stream) == [.stdout, .stderr])
        #expect(decoded.map(\.data) == records.map(\.data))
        #expect(
            abs(
                decoded[0].timestamp.timeIntervalSince1970
                    - 1_767_323_045.123_456_7
            ) < 0.001
        )

        let losslessHandle = try ContainerLogReaderStream.open(
            reader: ContainerLogBufferedReader(records: records),
            format: .structuredReadRecordsV1
        )
        defer { try? losslessHandle.close() }
        let losslessData = try #require(try losslessHandle.readToEnd())
        let losslessRecords =
            try losslessData
            .split(separator: UInt8(ascii: "\n"))
            .map {
                try JSONDecoder().decode(
                    ContainerLogReadRecordWireV1.self,
                    from: Data($0)
                ).record()
            }
        #expect(losslessRecords == records)
    }

    @Test
    func closingConsumerCancelsSuspendedReader() async throws {
        let reader = SuspendedLogReader()
        let handle = try ContainerLogReaderStream.open(
            reader: reader,
            format: .raw
        )

        try await waitUntil { reader.isWaiting }
        try handle.close()
        try await waitUntil { reader.isCancelled }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ContainerLogReaderStreamTestError.timeout
    }
}

private enum ContainerLogReaderStreamTestError: Error {
    case timeout
}

private final class SuspendedLogReader: ContainerLogReader, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<ContainerLogReaderEventV1, any Error>?
        var cancelled = false
    }

    private let state = Mutex(State())

    var isWaiting: Bool {
        state.withLock { $0.continuation != nil }
    }

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func next() async throws -> ContainerLogReaderEventV1 {
        try await withCheckedThrowingContinuation { continuation in
            let cancelled = state.withLock { state in
                guard !state.cancelled else {
                    return true
                }
                state.continuation = continuation
                return false
            }
            if cancelled {
                continuation.resume(
                    throwing: ContainerLogReaderError.cancelled
                )
            }
        }
    }

    func cancel() async {
        let continuation = state.withLock { state in
            state.cancelled = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: ContainerLogReaderError.cancelled)
    }
}
