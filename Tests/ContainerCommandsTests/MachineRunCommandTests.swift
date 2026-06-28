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

@testable import ContainerCommands

struct MachineRunCommandTests {
    @Test
    func runParsesPrivilegedFlagIntoProcessConfiguration() throws {
        let command = try Application.MachineRun.parse(["--privileged", "id"])

        let configuration = try command.processConfiguration(
            executable: "/sbin.machine/init",
            arguments: ["-s", "id"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: []
        )

        #expect(command.processFlags.privileged)
        #expect(configuration.executable == "/sbin.machine/init")
        #expect(configuration.arguments == ["-s", "id"])
        #expect(configuration.privileged)
    }

    @Test
    func runParsesUlimitsIntoProcessConfiguration() throws {
        let command = try Application.MachineRun.parse([
            "--ulimit", "nofile=1024:2048",
            "--ulimit", "stack=8192",
            "ulimit",
            "-a",
        ])

        let configuration = try command.processConfiguration(
            executable: "/sbin.machine/init",
            arguments: ["-s", "ulimit", "-a"],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: []
        )

        #expect(command.processFlags.ulimits == ["nofile=1024:2048", "stack=8192"])
        #expect(configuration.rlimits.count == 2)
        #expect(configuration.rlimits[0].limit == "RLIMIT_NOFILE")
        #expect(configuration.rlimits[0].soft == 1024)
        #expect(configuration.rlimits[0].hard == 2048)
        #expect(configuration.rlimits[1].limit == "RLIMIT_STACK")
        #expect(configuration.rlimits[1].soft == 8192)
        #expect(configuration.rlimits[1].hard == 8192)
    }
}
