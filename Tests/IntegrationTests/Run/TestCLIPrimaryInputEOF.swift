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
import Foundation
import Testing

@Suite(.serialized)
struct TestCLIPrimaryInputEOF {
    private let image = WarmupImage.alpine320.rawValue

    @Test
    func foregroundDedicatedRunClosesFiniteInput() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-eof-dedicated"
            fixture.addCleanup { try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let marker = "EOF-DEDICATED-\(fixture.testID)"
            let result = try fixture.run(
                ["run", "-i", "--name", name, image, "sh"],
                stdin: Data("printf '\(marker)\\n'\n".utf8),
                timeout: 120
            ).check()
            #expect(result.output.contains(marker))
            let inspect = try fixture.inspectContainer(name)
            #expect(inspect.configuration.effectiveIsolation == .dedicatedVM)
            #expect(inspect.status.state == "stopped")
        }
    }

    @Test
    func prewarmedDedicatedStartClosesFiniteInput() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-eof-prewarm"
            fixture.addCleanup { try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            try fixture.run(["create", "-i", "--name", name, image, "sh"], timeout: 120).check()
            // Create schedules an asynchronous dedicated bootstrap. Observe its
            // successful completion before start, so a cold retry cannot pass.
            try await waitForDedicatedPrewarm(name)
            let marker = "EOF-PREWARM-\(fixture.testID)"
            let result = try fixture.run(
                ["start", "-a", "-i", name],
                stdin: Data("printf '\(marker)\\n'\n".utf8),
                timeout: 120
            ).check()
            #expect(result.output.contains(marker))
            let inspect = try fixture.inspectContainer(name)
            #expect(inspect.configuration.effectiveIsolation == .dedicatedVM)
            #expect(inspect.status.state == "stopped")
        }
    }

    @Test
    func foregroundSharedRunClosesFiniteInput() async throws {
        try await ContainerFixture.with { fixture in
            let name = "\(fixture.testID)-eof-shared"
            fixture.addCleanup { try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let marker = "EOF-SHARED-\(fixture.testID)"
            let result = try fixture.run(
                ["run", "-i", "--isolation", "shared-vm", "--name", name, image, "sh"],
                stdin: Data("printf '\(marker)\\n'\n".utf8),
                timeout: 120
            ).check()
            #expect(result.output.contains(marker))
            let inspect = try fixture.inspectContainer(name)
            #expect(inspect.configuration.effectiveIsolation == .sharedVM)
            #expect(inspect.status.state == "stopped")
        }
    }

    private func waitForDedicatedPrewarm(_ name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["CLITEST_APISERVER_LOG"] else {
            throw CommandError.executionFailed("CLITEST_APISERVER_LOG is required for prewarm proof")
        }
        let log = URL(fileURLWithPath: path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: log, encoding: .utf8),
                text.split(separator: "\n").contains(where: {
                    $0.contains("container bootstrap timings")
                        && $0.contains("\"id\": \(name)")
                        && $0.contains("\"outcome\": success")
                })
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommandError.executionFailed("dedicated prewarm did not complete before start")
    }
}
