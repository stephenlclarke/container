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

    @Test func stableRunResetsFailureBackoff() {
        var tracker = ContainerRestartTracker()
        let policy = ContainerRestartPolicy(mode: .always)

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == 200_000_000)

        tracker.markStable()

        #expect(tracker.restartDelay(policy: policy, exitCode: 1) == ContainerRestartTracker.initialDelayInNanoseconds)
    }
}
