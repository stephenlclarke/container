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
import Testing

@testable import ContainerAPIService

struct ContainerStopDispositionTests {
    @Test(arguments: RuntimeStatus.allCases)
    func stoppedSnapshotsNeverContactRuntime(status: RuntimeStatus) {
        #expect(
            ContainersService.shouldSendRuntimeStop(for: status)
                == (status != .stopped)
        )
    }

    @Test func stopCancelsRestartScheduledDuringDelayWindow() {
        #expect(
            ContainersService.shouldCancelPendingRestart(
                runtimeStatus: .stopped,
                lifecycleState: .restarting,
                restartScheduled: true
            )
        )
        #expect(
            ContainersService.shouldCancelPendingRestart(
                runtimeStatus: .stopped,
                lifecycleState: .exited,
                restartScheduled: true
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                runtimeStatus: .stopped,
                lifecycleState: .exited,
                restartScheduled: false
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                runtimeStatus: .running,
                lifecycleState: .restarting,
                restartScheduled: true
            )
        )
    }

    @Test func restartUsesConfiguredStopDefaultsUnlessExplicitlyOverridden() {
        let defaults = ContainersService.resolvedStopOptions(
            .default,
            configuredSignal: "SIGUSR1",
            configuredTimeoutInSeconds: 17
        )
        #expect(defaults.signal == "SIGUSR1")
        #expect(defaults.timeoutInSeconds == 17)

        let explicit = ContainersService.resolvedStopOptions(
            ContainerStopOptions(timeoutInSeconds: 3, signal: "SIGKILL"),
            configuredSignal: "SIGUSR1",
            configuredTimeoutInSeconds: 17
        )
        #expect(explicit.signal == "SIGKILL")
        #expect(explicit.timeoutInSeconds == 3)
    }

    @Test func disablingRestartPolicyCancelsDelayedRestart() {
        #expect(
            ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                manualRestartSuppressed: false,
                updatedPolicy: .no,
                exitCode: 0,
                restartConsecutiveFailureCount: 0
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                manualRestartSuppressed: true,
                updatedPolicy: .no,
                exitCode: 0,
                restartConsecutiveFailureCount: 0
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                updatedPolicy: ContainerRestartPolicy(mode: .always),
                exitCode: 0,
                restartConsecutiveFailureCount: 0
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                lifecycleState: .exited,
                restartScheduled: true,
                updatedPolicy: .no,
                exitCode: 1,
                restartConsecutiveFailureCount: 0
            )
        )
        #expect(
            ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                updatedPolicy: ContainerRestartPolicy(mode: .onFailure),
                exitCode: 0,
                restartConsecutiveFailureCount: 1
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                updatedPolicy: ContainerRestartPolicy(mode: .onFailure),
                exitCode: 1,
                restartConsecutiveFailureCount: 1
            )
        )
        #expect(
            ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                updatedPolicy: ContainerRestartPolicy(
                    mode: .onFailure,
                    maximumRetryCount: 1
                ),
                exitCode: 1,
                restartConsecutiveFailureCount: 2
            )
        )
        #expect(
            !ContainersService.shouldCancelPendingRestart(
                lifecycleState: .restarting,
                restartScheduled: true,
                updatedPolicy: ContainerRestartPolicy(
                    mode: .onFailure,
                    maximumRetryCount: 1
                ),
                exitCode: 1,
                restartConsecutiveFailureCount: 1
            )
        )
    }

    @Test func pendingRemovalCannotBootstrap() {
        #expect(
            ContainersService.lifecycleMayBootstrap(
                removalRequested: false,
                removalInProgress: false
            )
        )
        #expect(
            !ContainersService.lifecycleMayBootstrap(
                removalRequested: true,
                removalInProgress: false
            )
        )
        #expect(
            !ContainersService.lifecycleMayBootstrap(
                removalRequested: false,
                removalInProgress: true
            )
        )
    }
}
