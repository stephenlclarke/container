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
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct RuntimeAttachIOTests {
    @Test("Prewarming keeps stdin attachable before the first client arrives")
    func prewarmingCreatesDeferredInputRelay() {
        let ordinary = RuntimeService.attachableInput(
            initial: nil,
            prewarming: false
        )
        let prewarmed = RuntimeService.attachableInput(
            initial: nil,
            prewarming: true
        )

        #expect(ordinary == nil)
        #expect(prewarmed != nil)
        prewarmed?.close()
    }

    @Test("Attach is accepted after prewarm and during the live lifecycle")
    func attachableRuntimeStates() {
        #expect(!RuntimeService.acceptsAttach(in: .created))
        #expect(RuntimeService.acceptsAttach(in: .booted))
        #expect(RuntimeService.acceptsAttach(in: .running))
        #expect(RuntimeService.acceptsAttach(in: .paused))
        #expect(!RuntimeService.acceptsAttach(in: .stopping))
        #expect(!RuntimeService.acceptsAttach(in: .stopped))
        #expect(!RuntimeService.acceptsAttach(in: .shuttingDown))
    }

    @Test("Shutdown cleans a booted prewarm before the helper exits")
    func runtimeShutdownDisposition() {
        #expect(RuntimeService.shutdownDisposition(in: .created) == .immediate)
        #expect(
            RuntimeService.shutdownDisposition(in: .booted)
                == .cleanBootedContainer
        )
        #expect(
            RuntimeService.shutdownDisposition(in: .stopping)
                == .cleanBootedContainer
        )
        #expect(RuntimeService.shutdownDisposition(in: .stopped) == .immediate)
        #expect(RuntimeService.shutdownDisposition(in: .running) == .reject)
        #expect(RuntimeService.shutdownDisposition(in: .paused) == .reject)
        #expect(
            RuntimeService.shutdownDisposition(in: .shuttingDown) == .immediate
        )
    }

    @Test
    func outputForwardsToInitialAndReattachedClients() throws {
        let initial = Pipe()
        let reattached = Pipe()
        let output = AttachableOutput(initial: initial.fileHandleForWriting)
        output.add(reattached.fileHandleForWriting)

        try output.write(Data("attached output\n".utf8))
        try output.close()

        #expect(try initial.fileHandleForReading.readToEnd() == Data("attached output\n".utf8))
        #expect(try reattached.fileHandleForReading.readToEnd() == Data("attached output\n".utf8))
    }

    @Test
    func outputKeepsPersistentLogAfterClientWriteFails() throws {
        let disconnectedClient = Pipe()
        let persistentLog = Pipe()
        let output = AttachableOutput(
            initial: disconnectedClient.fileHandleForReading,
            persistent: persistentLog.fileHandleForWriting
        )

        try output.write(Data("before detach\n".utf8))
        try output.write(Data("after detach\n".utf8))
        try output.close()

        #expect(
            try persistentLog.fileHandleForReading.readToEnd()
                == Data("before detach\nafter detach\n".utf8)
        )
    }

    @Test
    func persistentFailureDoesNotSuppressLiveAttachOutput() throws {
        let attached = Pipe()
        let observedFailure = Mutex<[AttachableOutputPersistentFailure]>([])
        let output = AttachableOutput(
            initial: attached.fileHandleForWriting,
            persistent: FailingRuntimeWriter(),
            persistentFailureHandler: { message in
                observedFailure.withLock { $0.append(message) }
            }
        )

        try output.write(Data("still attached\n".utf8))
        try output.close()

        #expect(try attached.fileHandleForReading.readToEnd() == Data("still attached\n".utf8))
        #expect(observedFailure.withLock { $0 } == [.write, .close])
    }

    @Test
    func inputRemainsOpenWhenOneClientEnds() async throws {
        let first = Pipe()
        let second = Pipe()
        let input = AttachableInput(initial: first.fileHandleForReading)
        input.add(second.fileHandleForReading)
        var iterator = input.stream().makeAsyncIterator()

        try first.fileHandleForWriting.close()
        try second.fileHandleForWriting.write(contentsOf: Data("next session\n".utf8))

        let received = await iterator.next()
        #expect(received == Data("next session\n".utf8))

        input.close()
        let finished = await iterator.next()
        #expect(finished == nil)
    }

    @Test("Closing deferred stdin delivers EOF before process start")
    func deferredInputCanFinishWithoutAClientHandle() async {
        let input = AttachableInput()
        var iterator = input.stream().makeAsyncIterator()

        input.close()

        #expect(await iterator.next() == nil)
    }
}

private enum ExpectedRuntimeWriterError: Error {
    case failure
}

private struct FailingRuntimeWriter: Writer {
    func write(_ data: Data) throws {
        throw ExpectedRuntimeWriterError.failure
    }

    func close() throws {
        throw ExpectedRuntimeWriterError.failure
    }
}
