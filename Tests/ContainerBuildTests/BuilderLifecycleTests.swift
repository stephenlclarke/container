//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import Darwin
import Foundation
import Logging
import NIOPosix
import Testing

@testable import ContainerBuild

@Suite("Builder lifecycle tests")
struct BuilderLifecycleTests {
    @Test("Shutdown releases the event loop after a connection failure")
    func shutdownReleasesEventLoopAfterConnectionFailure() async throws {
        var descriptors: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)

        let socket = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false)
        let peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = ShutdownRecorder()
        let builder = try await Builder(
            socket: socket,
            group: group,
            logger: Logger(label: "BuilderLifecycleTests"),
            shutdownEventLoopGroup: {
                recorder.record()
                try await group.shutdownGracefully()
            }
        )

        try peer.close()
        try await builder.shutdown()

        #expect(recorder.count == 1)
    }
}

private final class ShutdownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        self.lock.withLock { self._count }
    }

    func record() {
        self.lock.withLock {
            self._count += 1
        }
    }
}
