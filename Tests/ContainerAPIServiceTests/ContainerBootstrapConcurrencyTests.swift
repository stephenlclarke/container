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

struct ContainerBootstrapConcurrencyTests {
    @Test("State copies retain identity while replacements receive a new generation")
    func stateGenerationDistinguishesReplacement() {
        let state = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "container")
        )
        let updatedState = state
        let replacementState = ContainersService.ContainerState(
            snapshot: Self.snapshot(id: "container")
        )

        #expect(updatedState.generation == state.generation)
        #expect(replacementState.generation != state.generation)
    }

    @Test("Bootstrap commit accepts only the captured container and lifecycle generations")
    func bootstrapCommitGenerationFence() {
        let containerGeneration = UUID()
        let replacementGeneration = UUID()

        #expect(
            ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 7
            )
        )
        #expect(
            !ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: replacementGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 7
            )
        )
        #expect(
            !ContainersService.bootstrapCommitIsCurrent(
                plannedContainerGeneration: containerGeneration,
                currentContainerGeneration: containerGeneration,
                plannedOperationGeneration: 7,
                currentOperationGeneration: 8
            )
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
