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
import ContainerRuntimeClient
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerLifecycleValidationTests {
    @Test
    func emptyPostStartProcessSnapshotDefersToTheExitMonitor() {
        #expect(ContainersService.reportedInitPID([]) == 0)
        #expect(ContainersService.reportedInitPID([-1, 42, 7]) == 7)
    }

    @Test
    func finalStartCommitRecordsRuntimeStateAtomically() {
        var state = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "started")
        )
        state.snapshot.exitCode = 1
        state.snapshot.exitedDate = Date(timeIntervalSince1970: 100)
        let startedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let runtimeState = SandboxSnapshot(
            status: .running,
            networks: [],
            containers: []
        )

        ContainersService.markContainerStarted(
            &state,
            from: runtimeState,
            at: startedDate
        )

        #expect(state.snapshot.status == .running)
        #expect(state.snapshot.networks.isEmpty)
        #expect(state.snapshot.startedDate == startedDate)
        #expect(state.snapshot.exitCode == nil)
        #expect(state.snapshot.exitedDate == nil)
    }

    @Test
    func exitedPostStartProcessSnapshotDefersToTheExitMonitor() {
        let exited = ContainerizationError(
            .invalidState,
            message: "failed to processIdentifiers: container must be running or paused"
        )
        let wrapped = ContainerizationError(
            .internalError,
            message: "failed to get processes for container example",
            cause: exited
        )

        #expect(ContainersService.isPostStartProcessExitRace(wrapped))
        #expect(
            !ContainersService.isPostStartProcessExitRace(
                ContainerizationError(.timeout, message: "process snapshot timed out")
            )
        )
    }

    @Test
    func createAndUpdateShareTheBootableMemoryFloor() throws {
        try ContainersService.validateBootableMemory(
            ContainersService.minimumBootableMemoryInBytes
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateBootableMemory(
                ContainersService.minimumBootableMemoryInBytes - 1
            )
        }
    }

    @Test
    func nanoCPUsRequireARepresentablePositiveQuota() throws {
        #expect(throws: ContainerizationError.self) {
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 0)
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 9_999)
        }
        #expect(
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 10_000) == 1
        )
        #expect(
            try ContainersService.cpuQuotaInMicroseconds(nanoCPUs: 1_000_000_000)
                == 100_000
        )
    }

    @Test
    func autoRemoveRejectsRestartPolicyUpdates() throws {
        try ContainersService.validateRestartPolicy(.no, autoRemove: true)
        try ContainersService.validateRestartPolicy(
            ContainerRestartPolicy(mode: .always),
            autoRemove: false
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersService.validateRestartPolicy(
                ContainerRestartPolicy(mode: .always),
                autoRemove: true
            )
        }
    }

    @Test
    func containerNamesAndDockerIDsRemainReservedForCreate() {
        let dockerID = String(repeating: "a", count: 64)
        let containers = [
            (
                id: "immutable-storage-id",
                dockerName: Optional("renamed"),
                dockerID: Optional(dockerID)
            )
        ]

        #expect(
            ContainersService.hasContainer(
                named: "renamed",
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            !ContainersService.hasContainer(
                named: "available",
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            ContainersService.hasContainer(
                named: dockerID,
                excluding: "new-container",
                among: containers
            )
        )
        #expect(
            ContainersService.hasContainer(
                named: "quarantined-name",
                excluding: "new-container",
                among: [],
                reservedNames: ["quarantined-name"]
            )
        )
        #expect(
            !ContainersService.hasContainer(
                named: dockerID,
                excluding: "immutable-storage-id",
                among: containers
            )
        )
    }

    @Test
    func overflowingLifecycleRevisionsAreRejected() {
        #expect(throws: ContainerizationError.self) {
            var snapshot = ContainerLifecycleSnapshotV2(
                state: .restarting,
                transitionRevision: .max,
                operationGeneration: 8
            )
            try ContainersService.advanceLifecycleRevisions(&snapshot)
        }
        #expect(throws: ContainerizationError.self) {
            var snapshot = ContainerLifecycleSnapshotV2(
                state: .restarting,
                transitionRevision: 7,
                operationGeneration: .max
            )
            try ContainersService.advanceLifecycleRevisions(&snapshot)
        }
        #expect(throws: ContainerizationError.self) {
            try ContainersService.nextLifecycleCounter(
                .max,
                named: "process generation"
            )
        }
    }

    @Test
    func persistedOptionsOverrideTheOriginalRuntimeConfiguration() {
        let original = ContainerCreateOptions(
            autoRemove: false,
            restartPolicy: .no
        )
        let updated = ContainerCreateOptions(
            autoRemove: true,
            restartPolicy: ContainerRestartPolicy(mode: .always)
        )

        let selected = ContainersService.authoritativeCreateOptions(
            persisted: updated,
            runtime: original
        )

        #expect(selected.autoRemove)
        #expect(selected.restartPolicy.mode == .always)
    }

    @Test
    func failedExitPersistenceStillPublishesAnInMemoryExitedLifecycle() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 120)
        let existing = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "api",
            immutableBundleKey: "api",
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .running,
                running: true,
                paused: true,
                restarting: true,
                removalInProgress: true,
                dead: true,
                oomKillCountBaseline: 2,
                pid: 42,
                transitionRevision: 7,
                operationGeneration: 8
            )
        )

        let recovered = ContainersService.recoveredLifecycleAfterExitPersistenceFailure(
            existing,
            exitCode: 137,
            startedAt: startedAt,
            finishedAt: finishedAt,
            health: "unhealthy",
            restartConsecutiveFailureCount: 3,
            observedOOMKillCount: 4,
            manualRestartSuppressed: true,
            terminalError: "restart failed",
            persistenceError: "disk full"
        )

        #expect(recovered.snapshot.state == .exited)
        #expect(!recovered.snapshot.running)
        #expect(!recovered.snapshot.paused)
        #expect(!recovered.snapshot.restarting)
        #expect(!recovered.snapshot.removalInProgress)
        #expect(!recovered.snapshot.dead)
        #expect(recovered.snapshot.pid == 0)
        #expect(recovered.snapshot.exitCode == 137)
        #expect(recovered.snapshot.startedAt == startedAt)
        #expect(recovered.snapshot.finishedAt == finishedAt)
        #expect(recovered.snapshot.health == "unhealthy")
        #expect(recovered.snapshot.restartConsecutiveFailureCount == 3)
        #expect(recovered.snapshot.oomKilled)
        #expect(recovered.snapshot.transitionRevision == 8)
        #expect(recovered.snapshot.operationGeneration == 9)
        #expect(recovered.snapshot.error.contains("restart failed"))
        #expect(recovered.snapshot.error.contains("disk full"))
        #expect(recovered.intent.manualRestartSuppressed)
    }

    @Test
    func failedStartDropsTheInvalidRuntimeClientState() {
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
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        let configuration = ContainerConfiguration(
            id: "api",
            image: image,
            process: process
        )
        let state = ContainersService.ContainerState(
            snapshot: ContainerSnapshot(
                configuration: configuration,
                status: .running,
                networks: [],
                health: .healthy
            )
        )

        let recovered = ContainersService.recoveredContainerStateAfterFailedStart(
            state
        )

        #expect(recovered.client == nil)
        #expect(recovered.snapshot.status == .stopped)
        #expect(recovered.snapshot.networks.isEmpty)
        #expect(recovered.snapshot.health == nil)
    }

    @Test
    func exitPersistenceRecoveryRejectsStaleOrLiveState() {
        #expect(
            ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 9,
                expectedOperationGeneration: 9,
                status: .stopped
            )
        )
        #expect(
            !ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 10,
                expectedOperationGeneration: 9,
                status: .stopped
            )
        )
        #expect(
            !ContainersService.exitPersistenceRecoveryIsCurrent(
                currentOperationGeneration: 9,
                expectedOperationGeneration: 9,
                status: .running
            )
        )
    }

    @Test
    func restartStabilityPersistenceRecoveryRejectsStaleOrStoppedState() {
        let startedDate = Date(timeIntervalSince1970: 100)
        #expect(
            ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .running,
                startedDate: startedDate,
                expectedStartedDate: startedDate
            )
        )
        #expect(
            !ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .stopped,
                startedDate: startedDate,
                expectedStartedDate: startedDate
            )
        )
        #expect(
            !ContainersService.restartStabilityPersistenceRecoveryIsCurrent(
                status: .running,
                startedDate: Date(timeIntervalSince1970: 101),
                expectedStartedDate: startedDate
            )
        )
    }

    @Test
    func restartBackoffClearsTheExitedProcessPID() {
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .restarting,
                runtimeStatus: .stopped,
                reportedPID: nil
            ) == 0
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .restarting,
                runtimeStatus: .running,
                reportedPID: nil
            ) == 42
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .running,
                runtimeStatus: .running,
                reportedPID: 84
            ) == 84
        )
        #expect(
            ContainersService.lifecyclePID(
                previousPID: 42,
                publicState: .exited,
                runtimeStatus: .stopped,
                reportedPID: 84
            ) == 0
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
