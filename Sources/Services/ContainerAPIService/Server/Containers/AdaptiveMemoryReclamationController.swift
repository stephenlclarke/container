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

/// Pure decision state for the opt-in dedicated-VM memory controller.
/// Runtime effects and durable persistence remain owned by `ContainersService`.
struct AdaptiveMemoryReclamationController: Sendable {
    static let lowUsageSamplesBeforeShrink = 3
    static let pressureSamplesBeforeGrow = 2

    private let policy: ContainerConfiguration.Resources.AdaptiveMemoryReclamation
    private var lowUsageSamples = 0
    private var pressureSamples = 0
    private var previousDesiredTargetInBytes: UInt64?
    private var lastAdjustmentAt: TimeInterval

    init(
        policy: ContainerConfiguration.Resources.AdaptiveMemoryReclamation,
        now: TimeInterval
    ) {
        self.policy = policy
        self.lastAdjustmentAt = now
    }

    mutating func observe(
        usageInBytes: UInt64,
        currentTargetInBytes: UInt64,
        maximumInBytes: UInt64,
        now: TimeInterval
    ) -> UInt64? {
        let desiredTarget = Self.desiredTarget(
            usageInBytes: usageInBytes,
            policy: policy,
            maximumInBytes: maximumInBytes
        )

        if desiredTarget > currentTargetInBytes {
            lowUsageSamples = 0
            pressureSamples += 1
            previousDesiredTargetInBytes = desiredTarget
            guard pressureSamples >= Self.pressureSamplesBeforeGrow,
                currentTargetInBytes < maximumInBytes
            else {
                return nil
            }
            pressureSamples = 0
            return maximumInBytes
        }

        pressureSamples = 0
        guard desiredTarget < currentTargetInBytes else {
            lowUsageSamples = 0
            previousDesiredTargetInBytes = desiredTarget
            return nil
        }
        let demandIsStableOrFalling =
            previousDesiredTargetInBytes.map {
                desiredTarget <= $0
            } ?? true
        previousDesiredTargetInBytes = desiredTarget
        guard demandIsStableOrFalling else {
            lowUsageSamples = 0
            return nil
        }
        let reduction = currentTargetInBytes - desiredTarget
        guard reduction >= policy.hysteresisInBytes else {
            lowUsageSamples = 0
            return nil
        }

        lowUsageSamples += 1
        guard lowUsageSamples >= Self.lowUsageSamplesBeforeShrink,
            now - lastAdjustmentAt
                >= TimeInterval(policy.cooldownInNanoseconds) / 1_000_000_000
        else {
            return nil
        }
        lowUsageSamples = 0
        return desiredTarget
    }

    mutating func recordAdjustment(at now: TimeInterval) {
        lastAdjustmentAt = now
    }

    mutating func recordSamplingFailure() {
        lowUsageSamples = 0
        pressureSamples = 0
        previousDesiredTargetInBytes = nil
    }

    private static func desiredTarget(
        usageInBytes: UInt64,
        policy: ContainerConfiguration.Resources.AdaptiveMemoryReclamation,
        maximumInBytes: UInt64
    ) -> UInt64 {
        let (usageWithHeadroom, overflow) = usageInBytes.addingReportingOverflow(
            policy.headroomInBytes
        )
        let requested = overflow ? UInt64.max : usageWithHeadroom
        let aligned = alignUpToMiB(requested)
        return min(max(aligned, policy.floorInBytes), maximumInBytes)
    }

    private static func alignUpToMiB(_ value: UInt64) -> UInt64 {
        let alignment = ContainersService.liveMemoryTargetAlignmentInBytes
        let remainder = value % alignment
        guard remainder != 0 else {
            return value
        }
        let increment = alignment - remainder
        let (aligned, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : aligned
    }
}
