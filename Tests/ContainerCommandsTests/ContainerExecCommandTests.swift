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

import ArgumentParser
import ContainerResource
import Testing

@testable import ContainerCommands

struct ContainerExecCommandTests {
    @Test
    func execParsesPrivilegedFlag() throws {
        let command = try Application.ContainerExec.parse(["--privileged", "demo-api-1", "id"])

        #expect(command.processFlags.privileged)
        #expect(command.containerId == "demo-api-1")
        #expect(command.arguments == ["id"])
    }

    @Test
    func execParsesUlimitsIntoProcessConfiguration() throws {
        let command = try Application.ContainerExec.parse([
            "--ulimit", "nofile=1024:2048",
            "--ulimit", "nproc=512",
            "demo-api-1",
            "id",
        ])

        let configuration = try command.processConfiguration(
            baseProcess: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: ["BASE=true"],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            executable: "id",
            arguments: [],
            tty: false
        )

        #expect(command.processFlags.ulimits == ["nofile=1024:2048", "nproc=512"])
        #expect(configuration.rlimits.count == 2)
        #expect(configuration.rlimits[0].limit == "RLIMIT_NOFILE")
        #expect(configuration.rlimits[0].soft == 1024)
        #expect(configuration.rlimits[0].hard == 2048)
        #expect(configuration.rlimits[1].limit == "RLIMIT_NPROC")
        #expect(configuration.rlimits[1].soft == 512)
        #expect(configuration.rlimits[1].hard == 512)
    }

    @Test
    func execPreservesBaseRlimitsWithoutUlimitFlags() throws {
        let command = try Application.ContainerExec.parse(["demo-api-1", "id"])
        let inheritedRlimit = ProcessConfiguration.Rlimit(limit: "RLIMIT_NOFILE", soft: 64, hard: 128)

        let configuration = try command.processConfiguration(
            baseProcess: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0),
                rlimits: [inheritedRlimit]
            ),
            executable: "id",
            arguments: [],
            tty: false
        )

        #expect(configuration.rlimits.count == 1)
        #expect(configuration.rlimits[0].limit == inheritedRlimit.limit)
        #expect(configuration.rlimits[0].soft == inheritedRlimit.soft)
        #expect(configuration.rlimits[0].hard == inheritedRlimit.hard)
    }
}
