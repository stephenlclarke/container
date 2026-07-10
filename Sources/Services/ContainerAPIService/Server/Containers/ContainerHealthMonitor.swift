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

/// Tracks Docker-style health probe failure streaks.
///
/// Probe execution is handled by `ContainersService`; this helper is pure so
/// retry and start-period semantics can be tested without a running container.
struct ContainerHealthProbeTracker {
    private let retries: UInt32
    private var consecutiveFailures: UInt32 = 0
    private var lastStatus: HealthStatus = .starting

    init(retries: UInt32) {
        self.retries = retries == 0 ? ContainerHealthCheck.defaultRetries : retries
    }

    var status: HealthStatus {
        lastStatus
    }

    func shouldCountFailure(withinStartPeriod: Bool) -> Bool {
        lastStatus != .starting || !withinStartPeriod
    }

    func nextProbeDelay(healthCheck: ContainerHealthCheck, withinStartPeriod: Bool) -> UInt64 {
        if lastStatus == .starting, withinStartPeriod {
            let startInterval = healthCheck.startIntervalInNanoseconds ?? ContainerHealthCheck.defaultStartIntervalInNanoseconds
            return startInterval == 0 ? ContainerHealthCheck.defaultStartIntervalInNanoseconds : startInterval
        }
        return healthCheck.intervalInNanoseconds == 0
            ? ContainerHealthCheck.defaultIntervalInNanoseconds
            : healthCheck.intervalInNanoseconds
    }

    mutating func record(exitCode: Int32, countsFailure: Bool) -> HealthStatus {
        guard exitCode != 0 else {
            consecutiveFailures = 0
            lastStatus = .healthy
            return lastStatus
        }

        guard countsFailure else {
            return lastStatus
        }

        if consecutiveFailures < retries {
            consecutiveFailures += 1
        }
        if consecutiveFailures >= retries {
            lastStatus = .unhealthy
        }
        return lastStatus
    }
}
