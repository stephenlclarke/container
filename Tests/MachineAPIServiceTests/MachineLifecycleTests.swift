//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Testing

@testable import MachineAPIService

struct MachineLifecycleTests {
    @Test("Operations for one machine are serialized")
    func sameMachineSerializesOperations() async throws {
        let state = MachinesService.MachineState(snapshot: try Self.snapshot(id: "same"))
        let firstEntered = OneShotGate()
        let secondAttempted = OneShotGate()
        let releaseFirst = OneShotGate()
        let events = EventRecorder()

        async let first: Void = state.lifecycleLock.withLock { _ in
            await events.append("first-enter")
            await firstEntered.open()
            await releaseFirst.wait()
            await events.append("first-exit")
        }
        await firstEntered.wait()
        async let second: Void = {
            await secondAttempted.open()
            await state.lifecycleLock.withLock { _ in
                await events.append("second-enter")
            }
        }()
        await secondAttempted.wait()
        await releaseFirst.open()
        _ = await (first, second)

        #expect(await events.values == ["first-enter", "first-exit", "second-enter"])
    }

    @Test("Independent machines can run lifecycle operations concurrently")
    func differentMachinesRunConcurrently() async throws {
        let firstState = MachinesService.MachineState(snapshot: try Self.snapshot(id: "first"))
        let secondState = MachinesService.MachineState(snapshot: try Self.snapshot(id: "second"))
        let firstEntered = OneShotGate()
        let secondEntered = OneShotGate()
        let releaseFirst = OneShotGate()

        async let first: Void = firstState.lifecycleLock.withLock { _ in
            await firstEntered.open()
            await releaseFirst.wait()
        }
        await firstEntered.wait()
        async let second: Void = secondState.lifecycleLock.withLock { _ in
            await secondEntered.open()
        }

        await secondEntered.wait()
        await releaseFirst.open()
        _ = await (first, second)
    }

    @Test("State copies retain identity while replacements receive a new generation")
    func generationDistinguishesReplacement() throws {
        let state = MachinesService.MachineState(snapshot: try Self.snapshot(id: "machine"))
        let updatedState = state
        let replacementState = MachinesService.MachineState(snapshot: try Self.snapshot(id: "machine"))

        #expect(updatedState.generation == state.generation)
        #expect(replacementState.generation != state.generation)
    }

    @Test("A failed lifecycle operation releases the machine lock for retry")
    func failureAllowsRetry() async throws {
        let state = MachinesService.MachineState(snapshot: try Self.snapshot(id: "retry"))
        let retried = EventRecorder()

        await #expect(throws: LifecycleTestError.self) {
            try await state.lifecycleLock.withLock { _ in
                throw LifecycleTestError.expected
            }
        }
        await state.lifecycleLock.withLock { _ in
            await retried.append("retry")
        }

        #expect(await retried.values == ["retry"])
    }

    @Test("The final boot commit records runtime state atomically")
    func markMachineRunning() throws {
        var state = MachinesService.MachineState(snapshot: try Self.snapshot(id: "running"))
        let startedDate = Date(timeIntervalSince1970: 1_700_000_000)

        MachinesService.markMachineRunning(
            &state,
            containerID: "running-123456",
            startedDate: startedDate,
            initialized: true
        )

        #expect(state.snapshot.status == .running)
        #expect(state.snapshot.startedDate == startedDate)
        #expect(state.snapshot.containerId == "running-123456")
        #expect(state.snapshot.initialized)
    }

    @Test("The final exit commit clears transient runtime state")
    func markMachineStopped() throws {
        var state = MachinesService.MachineState(snapshot: try Self.snapshot(id: "stopped"))
        state.snapshot.status = .running
        state.snapshot.startedDate = Date(timeIntervalSince1970: 1_700_000_000)
        state.snapshot.containerId = "stopped-123456"
        state.snapshot.ipAddress = "192.0.2.1"

        MachinesService.markMachineStopped(&state)

        #expect(state.snapshot.status == .stopped)
        #expect(state.snapshot.startedDate == nil)
        #expect(state.snapshot.containerId == nil)
        #expect(state.snapshot.ipAddress == nil)
    }

    @Test("Cleanup removes only the reserved machine generation")
    func cleanupRespectsMachineGeneration() throws {
        let original = MachinesService.MachineState(snapshot: try Self.snapshot(id: "machine"))
        let replacement = MachinesService.MachineState(snapshot: try Self.snapshot(id: "machine"))
        var machines = ["machine": replacement]

        #expect(
            !MachinesService.removeMachineState(
                id: "machine",
                generation: original.generation,
                from: &machines
            )
        )
        #expect(machines["machine"]?.generation == replacement.generation)
        #expect(
            MachinesService.removeMachineState(
                id: "machine",
                generation: replacement.generation,
                from: &machines
            )
        )
        #expect(machines.isEmpty)
    }

    private static func snapshot(id: String) throws -> MachineSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let configuration = try MachineConfiguration(
            id: id,
            image: image,
            platform: .init(arch: "arm64", os: "linux", variant: "v8"),
            userSetup: .init(username: "test", uid: 501, gid: 20)
        )
        return MachineSnapshot(
            configuration: configuration,
            status: .stopped,
            bootConfig: .default
        )
    }
}

private enum LifecycleTestError: Error {
    case expected
}

private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
