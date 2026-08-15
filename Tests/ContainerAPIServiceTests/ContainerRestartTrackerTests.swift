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
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerRestartTrackerTests {
    @Test func noPolicyDoesNotRestart() {
        var tracker = ContainerRestartTracker()

        #expect(tracker.restartDelay(policy: .no, exitCode: 1) == nil)
    }

    @Test func onFailureRestartsOnlyNonZeroExit() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .onFailure)

        #expect(tracker.restartDelay(policy: policy, exitCode: 0) == nil)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
    }

    @Test func onFailureHonorsMaximumRetryCount() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .onFailure, maximumRetryCount: 2)

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 200_000_000)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == nil)
    }

    @Test func restoredOnFailureStatePreservesRetryBudgetAndBackoff() {
        let policy = ContainerRestartPolicy(mode: .onFailure, maximumRetryCount: 2)
        var firstAuthority = ContainerRestartTracker()
        #expect(
            firstAuthority.restartDelay(policy: policy, exitCode: 1)
                == ContainerRestartTracker.initialDelayInNanoseconds
        )
        #expect(firstAuthority.consecutiveFailures == 1)
        #expect(
            ContainerRestartTracker.pendingDelay(
                policy: policy,
                consecutiveFailureCount: firstAuthority.consecutiveFailures
            ) == ContainerRestartTracker.initialDelayInNanoseconds
        )

        var restartedAuthority = ContainerRestartTracker(
            restoringConsecutiveFailureCount: firstAuthority.consecutiveFailures
        )
        #expect(restartedAuthority.restartDelay(policy: policy, exitCode: 1) == 200_000_000)
        #expect(restartedAuthority.consecutiveFailures == 2)
        #expect(restartedAuthority.restartDelay(policy: policy, exitCode: 1) == nil)
    }

    @Test func corruptedMaximumFailureCountCannotOverflow() {
        var tracker = ContainerRestartTracker(
            restoringConsecutiveFailureCount: .max
        )

        #expect(
            tracker.restartDelay(
                policy: ContainerRestartPolicy(mode: .always),
                exitCode: 1
            ) == ContainerRestartTracker.maximumDelayInNanoseconds
        )
        #expect(tracker.consecutiveFailures == .max)
    }

    @Test func boundedOnFailurePolicyStopsAtSaturatedRetryCount() {
        let policy = ContainerRestartPolicy(
            mode: .onFailure,
            maximumRetryCount: .max
        )
        var tracker = ContainerRestartTracker(
            restoringConsecutiveFailureCount: .max - 1
        )

        #expect(
            tracker.restartDelay(policy: policy, exitCode: 1)
                == ContainerRestartTracker.maximumDelayInNanoseconds
        )
        #expect(tracker.consecutiveFailures == .max)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == nil)
    }

    @Test func onFailureZeroMaximumRetryCountMeansUnlimited() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .onFailure, maximumRetryCount: 0)

        #expect(policy.maximumRetryCount == nil)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 200_000_000)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 400_000_000)
    }

    @Test func alwaysRestartsZeroAndNonZeroExit() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .always)

        #expect(tracker.restartDelay(policy: policy, exitCode: 0) == ContainerRestartTracker.initialDelayInNanoseconds)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 200_000_000)
    }

    @Test func configuredRestartDelayDoesNotUseBackoff() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(
            mode: .always,
            retryDelayInNanoseconds: 5_000_000_000
        )

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 5_000_000_000)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 5_000_000_000)
    }

    @Test func configuredStableRunDurationOverridesDefault() {
        let policy = ContainerRestartPolicy(
            mode: .always,
            successfulRunDurationInNanoseconds: 30_000_000_000
        )

        #expect(ContainerRestartTracker.stableRunDuration(for: policy) == 30_000_000_000)
        #expect(ContainerRestartTracker.stableRunDuration(for: .no) == ContainerRestartTracker.stableRunDurationInNanoseconds)
    }

    @Test func manualStopSuppressesRestartUntilStartedAgain() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .always)

        tracker.markManuallyStopped()
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == nil)

        tracker.markStarted()
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
    }

    @Test func failedExplicitRestartStopRestoresAutomaticRestartEligibility() {
        var tracker = ContainerRestartTracker()

        tracker.markManuallyStopped()
        #expect(!tracker.allowsAutomaticRestart)

        tracker.restoreAutomaticRestartEligibility()
        #expect(tracker.allowsAutomaticRestart)
    }

    @Test func nonterminatingSignalDoesNotSuppressRestartPolicy() {
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.chld))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.cont))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.stop))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.tstp))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.ttin))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.ttou))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.urg))
        #expect(!ContainersService.signalTerminatesByDefault(.Linux.winch))
        #expect(!ContainersService.signalTerminatesByDefault(nil))
        #expect(ContainersService.signalTerminatesByDefault(.term))
        #expect(ContainersService.signalTerminatesByDefault(.kill))
        #expect(ContainersService.signalTerminatesByDefault(.Linux.usr1))
        #expect(!ContainersService.signalOutcomeConfirmsTermination(.unknown))
        #expect(!ContainersService.signalOutcomeConfirmsTermination(.running))
        #expect(!ContainersService.signalOutcomeConfirmsTermination(.paused))
        #expect(ContainersService.signalOutcomeConfirmsTermination(.stopping))
        #expect(ContainersService.signalOutcomeConfirmsTermination(.stopped))
    }

    @Test func stableRunResetsFailureBackoff() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .always)

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 200_000_000)

        tracker.markStable()

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
    }

    @Test func stableResetAdvancesLifecycleRevisions() throws {
        var snapshot = ContainerLifecycleSnapshotV2(
            state: .running,
            restartConsecutiveFailureCount: 3,
            transitionRevision: 7,
            operationGeneration: 8
        )

        try ContainersService.resetRestartFailureState(&snapshot)

        #expect(snapshot.restartConsecutiveFailureCount == 0)
        #expect(snapshot.transitionRevision == 8)
        #expect(snapshot.operationGeneration == 9)
    }

    @Test func failedTerminationRestoresOnlyTheRemainingStabilityWindow() {
        let startedDate = Date(timeIntervalSince1970: 100)
        let duration: UInt64 = 10_000_000_000

        #expect(
            ContainersService.remainingRestartStabilityDuration(
                startedDate: startedDate,
                durationInNanoseconds: duration,
                now: Date(timeIntervalSince1970: 104)
            ) == 6_000_000_000
        )
        #expect(
            ContainersService.remainingRestartStabilityDuration(
                startedDate: startedDate,
                durationInNanoseconds: duration,
                now: Date(timeIntervalSince1970: 111)
            ) == 0
        )
    }
}
