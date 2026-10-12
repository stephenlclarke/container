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

import ContainerBuild
import ContainerPersistence
import ContainerizationError
import Logging
import Testing

struct BuilderNameTests {
    @Test
    func builderContainerIdUsesDefaultBuilder() throws {
        #expect(try Builder.containerId(for: nil) == "buildkit")
        #expect(try Builder.containerId(for: "") == "buildkit")
        #expect(try Builder.containerId(for: "  default  ") == "buildkit")
    }

    @Test
    func builderContainerIdScopesNamedBuilders() throws {
        #expect(try Builder.containerId(for: "remote") == "buildkit-remote")
        #expect(try Builder.containerId(for: "team.builder-1") == "buildkit-team.builder-1")
    }

    @Test
    func builderContainerIdRejectsInvalidNames() {
        #expect(throws: (any Error).self) {
            _ = try Builder.containerId(for: "-remote")
        }
        #expect(throws: (any Error).self) {
            _ = try Builder.containerId(for: "bad/name")
        }
    }

    @Test
    func optionsRejectInvalidBuilderBeforeContactingService() async {
        var options = Builder.StartOptions()
        options.builderContainerId = "bad/name"
        let error = await #expect(throws: ContainerizationError.self) {
            try await Builder.start(
                options: options, log: Logger(label: "BuilderNameTests"),
                progressUpdate: { _ in
                    Issue.record("Invalid builder must be rejected before image-fetch progress")
                }, containerSystemConfig: .init())
        }
        #expect(error?.code == .invalidArgument)
    }

    @Test
    func legacyStartPreservesBuilderValidation() async {
        let error = await #expect(throws: ContainerizationError.self) {
            try await Builder.start(
                cpus: nil, memory: nil, log: Logger(label: "BuilderNameTests"),
                builderContainerId: "bad/name",
                progressUpdate: { _ in
                    Issue.record("Legacy adapter must preserve validation before image fetch")
                }, containerSystemConfig: .init())
        }
        #expect(error?.code == .invalidArgument)
    }
}
