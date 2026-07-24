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

import ContainerTestSupport
import Darwin
import Foundation
import Testing

/// Tests for `container builder start`, `stop`, and `delete` lifecycle commands.
///
/// Serialized because they stop/delete the shared `buildkit` container, which
/// would race with in-flight builds in the concurrent pool.
@Suite(.serialized)
struct TestCLIBuilderLifecycleSerial {
    @Test func testBuilderStartStopCommand() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            try f.builderStart()
            try await f.waitForBuilderRunning()
            let status1 = try f.getContainerStatus("buildkit")
            #expect(status1 == "running", "buildkit container should be running")

            try f.builderStop()
            let status2 = try f.getContainerStatus("buildkit")
            #expect(status2 == "stopped", "buildkit container should be stopped")
        }
    }

    @Test func testNamedBuilderStartBuildStopDelete() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilderLock {
                let builderName = "integration-\(UUID().uuidString.lowercased())"
                let builderContainer = "buildkit-\(builderName)"
                let image = "registry.local/named-builder:\(UUID().uuidString)"

                f.addCleanup {
                    _ = try? f.run(["image", "delete", image])
                    try? f.builderDelete(builder: builderName, force: true)
                }

                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nRUN printf named-builder >/named-builder.txt\n")

                try f.builderStart(builder: builderName)
                try await f.waitForBuilderRunning(builderContainer)

                let status = try f.getContainerStatus(builderContainer)
                #expect(status == "running", "named buildkit container should be running")

                try f.build(tag: image, contextDir: dir, otherArgs: ["--builder", builderName])
                try f.assertImageBuilt(image)

                try f.builderStop(builder: builderName)
                let stoppedStatus = try f.getContainerStatus(builderContainer)
                #expect(stoppedStatus == "stopped", "named buildkit container should be stopped")
            }
        }
    }

    @Test func testBuilderEnvironmentColors() async throws {
        try await ContainerFixture.with { f in
            let originalColors = ProcessInfo.processInfo.environment["BUILDKIT_COLORS"]
            let originalNoColor = ProcessInfo.processInfo.environment["NO_COLOR"]
            f.addCleanup {
                if let c = originalColors { setenv("BUILDKIT_COLORS", c, 1) } else { unsetenv("BUILDKIT_COLORS") }
                if let n = originalNoColor { setenv("NO_COLOR", n, 1) } else { unsetenv("NO_COLOR") }
                _ = try? f.builderDelete(force: true)
            }

            _ = try? f.builderDelete(force: true)
            setenv("BUILDKIT_COLORS", "run=green:warning=yellow:error=red:cancel=cyan", 1)
            setenv("NO_COLOR", "true", 1)

            try f.run(["builder", "start"]).check()
            try await f.waitForBuilderRunning()

            let container = try f.inspectContainer("buildkit")
            let env = container.configuration.initProcess.environment
            #expect(
                env.contains("BUILDKIT_COLORS=run=green:warning=yellow:error=red:cancel=cyan"),
                "BUILDKIT_COLORS should be forwarded to the buildkit container")
            #expect(
                env.contains("NO_COLOR=true"),
                "NO_COLOR should be forwarded to the buildkit container")
        }
    }
}
