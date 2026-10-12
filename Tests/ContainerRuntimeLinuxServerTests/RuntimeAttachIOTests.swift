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
import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerRuntimeLinuxServer

struct RuntimeAttachIOTests {
    @Test("Finite primary input must finish guest stdin after EOF", .timeLimit(.minutes(1)))
    func finitePrimaryInputFinishesAfterEOF() async throws {
        let pipe = Pipe()
        let input = AttachableInput(initial: pipe.fileHandleForReading, closeOnEOF: true)
        defer { input.close() }
        let payload = Data("echo complete\n".utf8)
        let timedOut = Mutex(false)
        let reader = Task {
            var received = Data()
            for await chunk in input.stream() {
                received.append(chunk)
            }
            return received
        }
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                timedOut.withLock { $0 = true }
                input.close()
            }
        }
        let received = await reader.value
        watchdog.cancel()
        #expect(received == payload)
        #expect(!timedOut.withLock { $0 })
    }

    @Test("Regular-file input delivers every byte and EOF", arguments: [0, 262_145])
    func regularFileInputFinishes(byteCount: Int) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data((0..<byteCount).map { UInt8($0 % 251) })
        try payload.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            handle.readabilityHandler = nil
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        let received = try await withThrowingTaskGroup(of: Data.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var result = Data()
                for await chunk in handle.stream() {
                    result.append(chunk)
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw CancellationError()
            }
            return try #require(await group.next())
        }
        #expect(received == payload)
    }

    @Test("Pipe input delivers bytes, EOF, and clears its readability handler")
    func pipeInputFinishes() async throws {
        let pipe = Pipe()
        let input = pipe.fileHandleForReading
        let output = pipe.fileHandleForWriting
        defer {
            input.readabilityHandler = nil
            try? input.close()
            try? output.close()
        }

        let stream = input.stream()
        let payload = Data("attached input\n".utf8)
        try output.write(contentsOf: payload)
        try output.close()

        let received = try await withThrowingTaskGroup(of: Data.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var result = Data()
                for await chunk in stream {
                    result.append(chunk)
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw CancellationError()
            }
            return try #require(await group.next())
        }
        #expect(received == payload)
        #expect(input.readabilityHandler == nil)
    }

    @Test("Process output close cannot close a subsequently reused descriptor")
    func processOutputCloseTracksFileHandleOwnership() throws {
        let source = Pipe()
        let ownedDescriptor = Darwin.fcntl(
            source.fileHandleForWriting.fileDescriptor,
            F_DUPFD_CLOEXEC,
            10_000
        )
        try #require(ownedDescriptor >= 10_000)
        let originalWrite = FileHandle(fileDescriptor: ownedDescriptor, closeOnDealloc: true)
        defer {
            try? source.fileHandleForReading.close()
            try? source.fileHandleForWriting.close()
            try? originalWrite.close()
        }

        try RuntimeService.closeProcessOutputHandles([nil, originalWrite, nil])

        let replacement = Pipe()
        try #require(
            Darwin.dup2(replacement.fileHandleForReading.fileDescriptor, ownedDescriptor)
                == ownedDescriptor
        )
        defer {
            _ = Darwin.close(ownedDescriptor)
            try? replacement.fileHandleForReading.close()
            try? replacement.fileHandleForWriting.close()
        }
        try replacement.fileHandleForWriting.write(contentsOf: Data("ok".utf8))

        // A raw close leaves originalWrite marked open. Closing it again would
        // then close the replacement after the kernel reuses the descriptor.
        try originalWrite.close()
        var buffer = [UInt8](repeating: 0, count: 2)
        let bytesRead = buffer.withUnsafeMutableBytes {
            Darwin.read(ownedDescriptor, $0.baseAddress, $0.count)
        }
        #expect(bytesRead == 2)
        #expect(buffer == Array("ok".utf8))
    }

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

    @Test("Owned stdin drains four MiB before EOF", .timeLimit(.minutes(1)))
    func ownedInputDrainsBeforeEOF() async throws {
        let pipe = Pipe()
        let input = AttachableInput(initial: pipe.fileHandleForReading, closeOnEOF: true)
        defer { input.close() }
        let expected = Data((0..<4 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0) })
        let writer = Task.detached {
            try pipe.fileHandleForWriting.write(contentsOf: expected)
            try pipe.fileHandleForWriting.close()
        }
        // EOF may arrive before the guest starts consuming buffered input.
        try await writer.value
        var actual = Data()
        for await chunk in input.stream() {
            actual.append(chunk)
        }
        #expect(actual == expected)
        input.close()
    }

    @Test("Prewarmed owned stdin finishes only its original generation", .timeLimit(.minutes(1)))
    func ownedDeferredInputDoesNotFinishReplacement() async throws {
        let oldPipe = Pipe()
        let replacementPipe = Pipe()
        let old = AttachableInput()
        let replacement = AttachableInput(initial: replacementPipe.fileHandleForReading)
        defer {
            old.close()
            replacement.close()
        }
        old.add(oldPipe.fileHandleForReading, closeOnEOF: true)
        var previous = old.stream().makeAsyncIterator()
        var current = replacement.stream().makeAsyncIterator()

        try oldPipe.fileHandleForWriting.close()
        #expect(await previous.next() == nil)
        old.close()
        try replacementPipe.fileHandleForWriting.write(contentsOf: Data("still open".utf8))
        #expect(await current.next() == Data("still open".utf8))
        try replacementPipe.fileHandleForWriting.close()
    }

    @Test("Cold bootstrap forwards descriptor-owned EOF", .timeLimit(.minutes(1)))
    func coldBootstrapOwnsEOFOnlyWhenRequested() async throws {
        let pipe = Pipe()
        let input = try #require(
            RuntimeService.attachableInput(
                initial: pipe.fileHandleForReading, prewarming: false, closeOnEOF: true
            ))
        defer { input.close() }
        var iterator = input.stream().makeAsyncIterator()
        try pipe.fileHandleForWriting.close()
        #expect(await iterator.next() == nil)
    }

    @Test("Queued input callbacks cannot read after owner EOF", .timeLimit(.minutes(1)))
    func queuedReadAfterOwnerEOFIgnoresClosedRegistration() async throws {
        let owner = Pipe()
        let peer = Pipe()
        let input = AttachableInput(initial: owner.fileHandleForReading, closeOnEOF: true)
        input.add(peer.fileHandleForReading)
        let queued = try #require(peer.fileHandleForReading.readabilityHandler)
        var iterator = input.stream().makeAsyncIterator()
        try owner.fileHandleForWriting.close()
        #expect(await iterator.next() == nil)
        // Even if the EOF callback is still returning from handle teardown,
        // the stale registration has already lost read authority.
        input.close()
        queued(peer.fileHandleForReading)
        let late = Pipe()
        input.add(late.fileHandleForReading, closeOnEOF: true)
        #expect(late.fileHandleForReading.readabilityHandler == nil)
        try peer.fileHandleForWriting.close()
        try late.fileHandleForWriting.close()
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
