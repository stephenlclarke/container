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

import ContainerizationError
import Testing

@testable import ContainerCommands

struct BuilderReadinessBackoffTests {
    @Test("Builder readiness retries quickly and cap at one second")
    func delaySequence() {
        var backoff = BuilderReadinessBackoff()

        #expect(
            (0..<7).map { _ in backoff.nextDelay() }
                == [
                    .milliseconds(50),
                    .milliseconds(100),
                    .milliseconds(200),
                    .milliseconds(400),
                    .milliseconds(800),
                    .seconds(1),
                    .seconds(1),
                ])
    }

    @Test("Builder readiness restarts a builder missing from status")
    func missingBuilderStatus() {
        let readinessError = ContainerizationError(
            .internalError,
            message: "failed to dial builder"
        )
        let statusError = ContainerizationError(
            .notFound,
            message: "builder disappeared"
        )

        #expect(
            BuilderReadinessRecovery.shouldRestart(
                after: readinessError,
                builderStatusError: statusError
            ))
    }

    @Test("Builder readiness does not restart a builder with observable status")
    func existingBuilderStatus() {
        let readinessError = ContainerizationError(
            .internalError,
            message: "builder is not ready"
        )

        #expect(
            !BuilderReadinessRecovery.shouldRestart(
                after: readinessError,
                builderStatusError: nil
            ))
    }

    @Test("Builder readiness preserves direct restart errors")
    func directRestartError() {
        let readinessError = ContainerizationError(
            .invalidState,
            message: "builder state changed"
        )

        #expect(
            BuilderReadinessRecovery.shouldRestart(
                after: readinessError,
                builderStatusError: nil
            ))
    }

    @Test("Builder readiness does not restart after an inconclusive status failure")
    func inconclusiveBuilderStatus() {
        let readinessError = ContainerizationError(
            .internalError,
            message: "failed to dial builder"
        )
        let statusError = ContainerizationError(
            .internalError,
            message: "failed to query builder status"
        )

        #expect(
            !BuilderReadinessRecovery.shouldRestart(
                after: readinessError,
                builderStatusError: statusError
            ))
    }
}
