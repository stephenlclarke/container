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

struct ContainerHealthMonitorTests {
    private let process = ProcessConfiguration(
        executable: "/bin/true",
        arguments: [],
        environment: []
    )

    @Test func startPeriodFailuresDoNotCountAgainstRetries() {
        var tracker = ContainerHealthProbeTracker(retries: 2)

        #expect(tracker.record(exitCode: 1, countsFailure: false) == .starting)
        #expect(tracker.record(exitCode: 1, countsFailure: false) == .starting)
        #expect(tracker.record(exitCode: 0, countsFailure: true) == .healthy)
    }

    @Test func firstProbeUsesStartIntervalAndSubsequentHealthyProbeUsesNormalInterval() {
        var tracker = ContainerHealthProbeTracker(retries: 2)
        let healthCheck = ContainerHealthCheck(
            process: process,
            intervalInNanoseconds: 30_000_000_000,
            startPeriodInNanoseconds: 60_000_000_000,
            startIntervalInNanoseconds: 1_000_000_000
        )

        #expect(tracker.nextProbeDelay(healthCheck: healthCheck, withinStartPeriod: true) == 1_000_000_000)
        #expect(tracker.record(exitCode: 0, countsFailure: false) == .healthy)
        #expect(tracker.nextProbeDelay(healthCheck: healthCheck, withinStartPeriod: true) == 30_000_000_000)
    }

    @Test func omittedAndZeroProbeIntervalsUseDockerDefaults() {
        let omitted = ContainerHealthCheck(
            process: process,
            startPeriodInNanoseconds: 60_000_000_000
        )
        let zero = ContainerHealthCheck(
            process: process,
            intervalInNanoseconds: 0,
            startPeriodInNanoseconds: 60_000_000_000,
            startIntervalInNanoseconds: 0
        )
        let tracker = ContainerHealthProbeTracker(retries: 1)

        #expect(
            tracker.nextProbeDelay(healthCheck: omitted, withinStartPeriod: true)
                == ContainerHealthCheck.defaultStartIntervalInNanoseconds
        )
        #expect(
            tracker.nextProbeDelay(healthCheck: zero, withinStartPeriod: true)
                == ContainerHealthCheck.defaultStartIntervalInNanoseconds
        )
        #expect(
            tracker.nextProbeDelay(healthCheck: zero, withinStartPeriod: false)
                == ContainerHealthCheck.defaultIntervalInNanoseconds
        )
    }

    @Test func countedFailuresTransitionToUnhealthyAfterRetries() {
        var tracker = ContainerHealthProbeTracker(retries: 2)

        #expect(tracker.record(exitCode: 1, countsFailure: true) == .starting)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
    }

    @Test func healthyContainersRemainHealthyUntilFailureThreshold() {
        var tracker = ContainerHealthProbeTracker(retries: 3)

        #expect(tracker.record(exitCode: 0, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
    }

    @Test func successfulProbeResetsFailureStreak() {
        var tracker = ContainerHealthProbeTracker(retries: 2)

        #expect(tracker.record(exitCode: 1, countsFailure: true) == .starting)
        #expect(tracker.record(exitCode: 0, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
    }

    @Test func healthyProbeEndsStartPeriodFailureGrace() {
        var tracker = ContainerHealthProbeTracker(retries: 2)

        #expect(!tracker.shouldCountFailure(withinStartPeriod: true))
        #expect(tracker.record(exitCode: 0, countsFailure: false) == .healthy)
        #expect(tracker.shouldCountFailure(withinStartPeriod: true))
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .healthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
    }

    @Test func zeroRetriesUsesDockerDefaultRetryCount() {
        var tracker = ContainerHealthProbeTracker(retries: 0)

        #expect(tracker.record(exitCode: 1, countsFailure: true) == .starting)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .starting)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
        #expect(tracker.record(exitCode: 1, countsFailure: true) == .unhealthy)
    }
}
