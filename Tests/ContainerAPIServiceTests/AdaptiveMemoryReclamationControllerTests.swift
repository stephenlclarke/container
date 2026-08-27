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

struct AdaptiveMemoryReclamationControllerTests {
    private let policy = ContainerConfiguration.Resources.AdaptiveMemoryReclamation(
        floorInBytes: 256.mib(),
        headroomInBytes: 128.mib(),
        hysteresisInBytes: 64.mib(),
        sampleIntervalInNanoseconds: 1_000_000_000,
        cooldownInNanoseconds: 10_000_000_000
    )

    @Test func sustainedLowUsageShrinksToAlignedUsageWithHeadroom() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        #expect(
            controller.observe(
                usageInBytes: 300.mib() + 1,
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 10
            ) == nil)
        #expect(
            controller.observe(
                usageInBytes: 300.mib() + 1,
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 11
            ) == nil)
        #expect(
            controller.observe(
                usageInBytes: 300.mib() + 1,
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 12
            ) == 429.mib())
    }

    @Test func floorBoundsLowUsageTarget() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        for now in [10.0, 11.0] {
            #expect(
                controller.observe(
                    usageInBytes: 32.mib(),
                    currentTargetInBytes: 1024.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
        #expect(
            controller.observe(
                usageInBytes: 32.mib(),
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 12
            ) == 256.mib())
    }

    @Test func cooldownAndHysteresisPreventTargetChurn() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        for now in [1.0, 2.0, 3.0] {
            #expect(
                controller.observe(
                    usageInBytes: 300.mib(),
                    currentTargetInBytes: 512.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
        #expect(
            controller.observe(
                usageInBytes: 300.mib(),
                currentTargetInBytes: 512.mib(),
                maximumInBytes: 1024.mib(),
                now: 10
            ) == 428.mib())
        #expect(
            controller.observe(
                usageInBytes: 340.mib(),
                currentTargetInBytes: 512.mib(),
                maximumInBytes: 1024.mib(),
                now: 20
            ) == nil)
    }

    @Test func zeroHysteresisDoesNotRequestTheCurrentTarget() {
        var zeroHysteresisPolicy = policy
        zeroHysteresisPolicy.hysteresisInBytes = 0
        var controller = AdaptiveMemoryReclamationController(
            policy: zeroHysteresisPolicy,
            now: 0
        )

        for now in [10.0, 11.0, 12.0] {
            #expect(
                controller.observe(
                    usageInBytes: 128.mib(),
                    currentTargetInBytes: 256.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
    }

    @Test func risingDemandDoesNotAccumulateShrinkEvidence() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        for (now, usage) in [(10.0, 100.mib()), (11.0, 132.mib()), (12.0, 164.mib())] {
            #expect(
                controller.observe(
                    usageInBytes: usage,
                    currentTargetInBytes: 1024.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
        for now in [13.0, 14.0] {
            #expect(
                controller.observe(
                    usageInBytes: 164.mib(),
                    currentTargetInBytes: 1024.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
        #expect(
            controller.observe(
                usageInBytes: 164.mib(),
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 15
            ) == 292.mib())
    }

    @Test func sustainedPressureRestoresBootMaximum() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        #expect(
            controller.observe(
                usageInBytes: 200.mib(),
                currentTargetInBytes: 256.mib(),
                maximumInBytes: 1024.mib(),
                now: 1
            ) == nil)
        #expect(
            controller.observe(
                usageInBytes: 200.mib(),
                currentTargetInBytes: 256.mib(),
                maximumInBytes: 1024.mib(),
                now: 2
            ) == 1024.mib())
    }

    @Test func successfulGrowthStartsCooldownBeforeTheNextShrink() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        _ = controller.observe(
            usageInBytes: 200.mib(),
            currentTargetInBytes: 256.mib(),
            maximumInBytes: 1024.mib(),
            now: 1
        )
        #expect(
            controller.observe(
                usageInBytes: 200.mib(),
                currentTargetInBytes: 256.mib(),
                maximumInBytes: 1024.mib(),
                now: 2
            ) == 1024.mib())
        controller.recordAdjustment(at: 2)

        for now in [3.0, 4.0, 5.0] {
            #expect(
                controller.observe(
                    usageInBytes: 32.mib(),
                    currentTargetInBytes: 1024.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
    }

    @Test func samplingFailureClearsAccumulatedEvidence() {
        var controller = AdaptiveMemoryReclamationController(policy: policy, now: 0)

        for now in [10.0, 11.0] {
            #expect(
                controller.observe(
                    usageInBytes: 32.mib(),
                    currentTargetInBytes: 1024.mib(),
                    maximumInBytes: 1024.mib(),
                    now: now
                ) == nil)
        }
        controller.recordSamplingFailure()
        #expect(
            controller.observe(
                usageInBytes: 32.mib(),
                currentTargetInBytes: 1024.mib(),
                maximumInBytes: 1024.mib(),
                now: 12
            ) == nil)
    }
}
