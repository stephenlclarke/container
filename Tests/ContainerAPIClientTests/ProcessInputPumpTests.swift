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

import Foundation
import Testing

@testable import ContainerAPIClient

@Suite(.timeLimit(.minutes(1)))
struct ProcessInputPumpTests {
    @Test
    func forwardsInputWhileTheDestinationIsDrainedAsynchronously() async throws {
        let source = Pipe()
        let destination = Pipe()
        let output = LockedOutput()
        let (completed, completion) = AsyncStream<Void>.makeStream()
        destination.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                completion.yield()
                completion.finish()
            } else {
                output.append(data)
            }
        }

        let pump = try ProcessInputPump(
            input: source.fileHandleForReading,
            output: destination.fileHandleForWriting
        )
        pump.start()
        let payload = Data((0..<(4 * 1024 * 1024)).lazy.map { UInt8($0 & 0xff) })
        let writer = Task.detached {
            try source.fileHandleForWriting.write(contentsOf: payload)
            try source.fileHandleForWriting.close()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in completed {
                    return
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw PumpTestError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
        try await writer.value
        pump.stop()

        #expect(output.data == payload)
    }
}

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }
}

private enum PumpTestError: Error {
    case timeout
}
