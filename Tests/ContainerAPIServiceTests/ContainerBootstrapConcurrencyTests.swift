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
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerBootstrapConcurrencyTests {
    @Test("Runtime bootstraps do not exceed the concurrency limit")
    func runtimeBootstrapConcurrencyLimit() async throws {
        let limiter = RuntimeBootstrapLimiter(limit: 2)
        let barrier = BootstrapStartBarrier(participantCount: 6)
        let releaseGate = BootstrapReleaseGate()
        let probe = BootstrapConcurrencyProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await barrier.arriveAndWait()
                    try await limiter.withPermit {
                        await probe.enter()
                        await releaseGate.wait()
                        await probe.leave()
                    }
                }
            }

            var reachedLimit = false
            for _ in 0..<1_000 {
                if (await probe.snapshot).entered == 2 {
                    reachedLimit = true
                    break
                }
                await Task.yield()
            }
            #expect(reachedLimit)
            let held = await probe.snapshot
            #expect(held.active == 2)
            #expect(held.entered == 2)
            #expect(held.maximumActive == 2)

            await releaseGate.release()
            try await group.waitForAll()
        }

        let completed = await probe.snapshot
        #expect(completed.active == 0)
        #expect(completed.entered == 6)
        #expect(completed.maximumActive == 2)
        let occupancy = await limiter.occupancy
        #expect(occupancy.active == 0)
        #expect(occupancy.waiting == 0)
    }

    @Test("A failed runtime bootstrap returns its permit")
    func runtimeBootstrapFailureReturnsPermit() async throws {
        let limiter = RuntimeBootstrapLimiter(limit: 1)

        await #expect(throws: BootstrapLimiterTestError.expected) {
            try await limiter.withPermit {
                throw BootstrapLimiterTestError.expected
            }
        }

        let result = try await limiter.withPermit { 42 }
        #expect(result == 42)
        let occupancy = await limiter.occupancy
        #expect(occupancy.active == 0)
        #expect(occupancy.waiting == 0)
    }

    @Test("Cancelling a queued runtime bootstrap does not consume a permit")
    func cancelledRuntimeBootstrapWaiter() async throws {
        let limiter = RuntimeBootstrapLimiter(limit: 1)
        let holderEntered = BootstrapReleaseGate()
        let releaseHolder = BootstrapReleaseGate()
        let waiterRan = BootstrapConcurrencyProbe()

        let holder = Task {
            try await limiter.withPermit {
                await holderEntered.release()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()

        let waiter = Task {
            try await limiter.withPermit {
                await waiterRan.enter()
            }
        }
        var waiterQueued = false
        for _ in 0..<1_000 {
            if (await limiter.occupancy).waiting == 1 {
                waiterQueued = true
                break
            }
            await Task.yield()
        }
        #expect(waiterQueued)

        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        await releaseHolder.release()
        try await holder.value

        let probe = await waiterRan.snapshot
        #expect(probe.entered == 0)
        let occupancy = await limiter.occupancy
        #expect(occupancy.active == 0)
        #expect(occupancy.waiting == 0)
    }

    @Test("Runtime bootstrap timing covers success, failure, and queued cancellation")
    func runtimeBootstrapTimingPhases() {
        let admitted = ContainersService.runtimeBootstrapPhases(
            waitStartedAt: 10,
            bootstrapStartedAt: 12,
            bootstrapFinishedAt: 15
        )
        #expect(admitted.map(\.0) == ["runtime-bootstrap-admission", "runtime-bootstrap"])
        #expect(admitted.map(\.1) == [2_000_000, 3_000_000])

        let cancelled = ContainersService.runtimeBootstrapPhases(
            waitStartedAt: 10,
            bootstrapStartedAt: nil,
            bootstrapFinishedAt: 14
        )
        #expect(cancelled.map(\.0) == ["runtime-bootstrap-admission", "runtime-bootstrap"])
        #expect(cancelled.map(\.1) == [4_000_000, 0])
    }

    @Test("An admitted bootstrap permit remains held until cleanup completes")
    func runtimeBootstrapPermitWaitsForCleanup() async throws {
        let limiter = RuntimeBootstrapLimiter(limit: 1)
        let permitAcquired = BootstrapReleaseGate()
        let cleanupCompleted = BootstrapReleaseGate()
        let waiterEntered = BootstrapReleaseGate()

        let admitted = Task {
            try await limiter.acquirePermit()
            await permitAcquired.release()
            await cleanupCompleted.wait()
            await limiter.releasePermit()
        }
        await permitAcquired.wait()

        let waiter = Task {
            try await limiter.withPermit {
                await waiterEntered.release()
            }
        }
        var waiterQueued = false
        for _ in 0..<1_000 {
            if (await limiter.occupancy).waiting == 1 {
                waiterQueued = true
                break
            }
            await Task.yield()
        }
        #expect(waiterQueued)
        #expect(!(await waiterEntered.isReleased))

        await cleanupCompleted.release()
        try await admitted.value
        try await waiter.value
        #expect(await waiterEntered.isReleased)
    }

    @Test("Runtime cleanup confirms a failed bootout did not leave a helper")
    func runtimeCleanupConfirmsInactiveHelper() throws {
        try ContainersService.stopRuntimeServiceAndConfirmInactive(
            fullServiceLabel: "test.runtime",
            deregisterService: { _ in 3 },
            isServiceRegistered: { _ in false }
        )

        #expect(throws: ContainerizationError.self) {
            try ContainersService.stopRuntimeServiceAndConfirmInactive(
                fullServiceLabel: "test.runtime",
                deregisterService: { _ in 3 },
                isServiceRegistered: { _ in true }
            )
        }
    }

    @Test("State copies retain identity while replacements receive a new generation")
    func stateGenerationDistinguishesReplacement() {
        let state = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "container")
        )
        let updatedState = state
        let replacementState = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "container")
        )

        #expect(updatedState.generation == state.generation)
        #expect(replacementState.generation != state.generation)
    }

    @Test("Bootstrap commit accepts only the captured container and lifecycle generations")
    func bootstrapCommitGenerationFence() {
        let containerGeneration = UUID()
        let replacementGeneration = UUID()

        #expect(
            ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 7
            )
        )
        #expect(
            !ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: replacementGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 7
            )
        )
        #expect(
            !ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 8
            )
        )
    }

    @Test("Failed bootstrap cleanup is retained only on the captured container generation")
    func bootstrapCleanupTombstoneGenerationFence() {
        let containerGeneration = UUID()

        #expect(
            ContainersService.bootstrapCleanupTombstoneMayCommit(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                currentClientExists: false
            )
        )
        #expect(
            !ContainersService.bootstrapCleanupTombstoneMayCommit(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: UUID(),
                currentClientExists: false
            )
        )
        #expect(
            !ContainersService.bootstrapCleanupTombstoneMayCommit(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                currentClientExists: true
            )
        )
    }

    @Test("Only never-started dedicated containers without caller-owned host endpoints prewarm")
    func dedicatedPrewarmEligibility() throws {
        let eligible = Self.snapshot(id: "eligible")
        #expect(ContainersService.shouldPrewarm(eligible))

        var shared = Self.snapshot(id: "shared")
        shared.configuration.effectiveIsolation = .sharedVM
        #expect(!ContainersService.shouldPrewarm(shared))

        var ssh = Self.snapshot(id: "ssh")
        ssh.configuration.ssh = true
        #expect(!ContainersService.shouldPrewarm(ssh))

        var publishedSocket = Self.snapshot(id: "published-socket")
        publishedSocket.configuration.publishedSockets = [
            try PublishSocket(
                containerPath: "/run/service.sock",
                hostPath: "/tmp/service.sock"
            )
        ]
        #expect(!ContainersService.shouldPrewarm(publishedSocket))

        var customRuntime = Self.snapshot(id: "custom-runtime")
        customRuntime.configuration.runtimeHandler = "example-runtime"
        #expect(!ContainersService.shouldPrewarm(customRuntime))

        var started = Self.snapshot(id: "started")
        started.startedDate = Date()
        #expect(!ContainersService.shouldPrewarm(started))

        var running = Self.snapshot(id: "running")
        running.status = .running
        #expect(!ContainersService.shouldPrewarm(running))
    }

    @Test("Boot prewarming excludes pending restart and removal lifecycle work")
    func dedicatedPrewarmBootRecoveryEligibility() {
        let snapshot = Self.snapshot(id: "recovered")
        var lifecycle = ContainerLifecycleRecordV2(
            containerID: snapshot.id,
            canonicalName: snapshot.id,
            immutableBundleKey: snapshot.id,
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(state: .created)
        )

        #expect(
            ContainersService.shouldPrewarmAtBoot(
                snapshot,
                lifecycle: lifecycle
            )
        )
        #expect(
            !ContainersService.shouldPrewarmAtBoot(
                snapshot,
                lifecycle: nil
            )
        )

        lifecycle.snapshot.state = .restarting
        lifecycle.snapshot.restarting = true
        #expect(
            !ContainersService.shouldPrewarmAtBoot(
                snapshot,
                lifecycle: lifecycle
            )
        )

        lifecycle.snapshot.state = .created
        lifecycle.snapshot.restarting = false
        lifecycle.intent.removalRequested = true
        #expect(
            !ContainersService.shouldPrewarmAtBoot(
                snapshot,
                lifecycle: lifecycle
            )
        )
    }

    @Test("Only runtime resource updates invalidate a prepared VM")
    func dedicatedPrewarmResourceInvalidation() {
        #expect(
            ContainersService.resourceUpdateInvalidatesPrewarm(
                prewarmed: true,
                memoryBytes: 512 * 1024 * 1024,
                nanoCPUs: nil
            )
        )
        #expect(
            ContainersService.resourceUpdateInvalidatesPrewarm(
                prewarmed: true,
                memoryBytes: nil,
                nanoCPUs: 1_000_000_000
            )
        )
        #expect(
            !ContainersService.resourceUpdateInvalidatesPrewarm(
                prewarmed: true,
                memoryBytes: nil,
                nanoCPUs: nil
            )
        )
        #expect(
            !ContainersService.resourceUpdateInvalidatesPrewarm(
                prewarmed: false,
                memoryBytes: 512 * 1024 * 1024,
                nanoCPUs: 1_000_000_000
            )
        )
    }

    @Test("A changed container name rebuilds a prepared VM")
    func dedicatedPrewarmRenameInvalidation() {
        #expect(
            ContainersService.renameInvalidatesPrewarm(
                prewarmed: true,
                currentName: "before",
                newName: "after"
            )
        )
        #expect(
            !ContainersService.renameInvalidatesPrewarm(
                prewarmed: true,
                currentName: "same",
                newName: "same"
            )
        )
        #expect(
            !ContainersService.renameInvalidatesPrewarm(
                prewarmed: false,
                currentName: "before",
                newName: "after"
            )
        )
    }

    @Test("Empty and nil standard-input arrays finish deferred stdin")
    func dedicatedPrewarmStdinCompletion() {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        #expect(ContainersService.deferredStdinNeedsEOF([]))
        #expect(ContainersService.deferredStdinNeedsEOF([nil]))
        #expect(
            !ContainersService.deferredStdinNeedsEOF([
                pipe.fileHandleForReading
            ])
        )
    }

    private static func snapshot(id: String) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        return ContainerSnapshot(
            configuration: ContainerConfiguration(
                id: id,
                image: image,
                process: process
            ),
            status: .stopped,
            networks: [],
            startedDate: nil
        )
    }
}

private enum BootstrapLimiterTestError: Error {
    case expected
}

private actor BootstrapStartBarrier {
    private let participantCount: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        arrivals += 1
        guard arrivals < participantCount else {
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor BootstrapReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isReleased: Bool {
        released
    }

    func wait() async {
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else {
            return
        }
        released = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.resume()
        }
    }
}

private actor BootstrapConcurrencyProbe {
    private var active = 0
    private var entered = 0
    private var maximumActive = 0

    var snapshot: (active: Int, entered: Int, maximumActive: Int) {
        (active, entered, maximumActive)
    }

    func enter() {
        active += 1
        entered += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }

}
