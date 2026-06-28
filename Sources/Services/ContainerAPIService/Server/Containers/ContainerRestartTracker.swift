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

/// Tracks Docker-style restart policy state for one container.
///
/// The API service owns runtime scheduling. This helper is intentionally pure so
/// policy decisions and backoff progression can be tested without a live
/// runtime process.
struct ContainerRestartTracker {
    static let initialDelayInNanoseconds: UInt64 = 100_000_000
    static let maximumDelayInNanoseconds: UInt64 = 60_000_000_000
    static let stableRunDurationInNanoseconds: UInt64 = 10_000_000_000

    static func stableRunDuration(for policy: ContainerRestartPolicy) -> UInt64 {
        policy.successfulRunDurationInNanoseconds ?? Self.stableRunDurationInNanoseconds
    }

    private var manuallyStopped = false
    private var consecutiveFailureCount: UInt32 = 0
    private var nextDelayInNanoseconds = Self.initialDelayInNanoseconds

    var allowsAutomaticRestart: Bool {
        !manuallyStopped
    }

    mutating func markStarted() {
        manuallyStopped = false
    }

    mutating func markManuallyStopped() {
        manuallyStopped = true
    }

    mutating func markStable() {
        consecutiveFailureCount = 0
        nextDelayInNanoseconds = Self.initialDelayInNanoseconds
    }

    mutating func restartDelay(policy: ContainerRestartPolicy, exitCode: Int32?) -> UInt64? {
        guard !manuallyStopped else {
            return nil
        }

        let shouldRestart: Bool
        switch policy.mode {
        case .no:
            shouldRestart = false
        case .onFailure:
            shouldRestart = exitCode != nil && exitCode != 0
        case .always, .unlessStopped:
            shouldRestart = true
        }
        guard shouldRestart else {
            return nil
        }

        consecutiveFailureCount += 1
        if policy.mode == .onFailure,
            let maximumRetryCount = policy.maximumRetryCount,
            consecutiveFailureCount > maximumRetryCount
        {
            return nil
        }

        guard let retryDelayInNanoseconds = policy.retryDelayInNanoseconds else {
            defer {
                nextDelayInNanoseconds = min(
                    nextDelayInNanoseconds * 2,
                    Self.maximumDelayInNanoseconds
                )
            }
            return nextDelayInNanoseconds
        }
        return retryDelayInNanoseconds
    }
}
