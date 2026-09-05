//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
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
    func defaultUserEnvironmentPreservesProvisionedAlias() throws {
        let command = try Application.MachineRun.parse(["id"])
        let defaultUser = ProcessConfiguration.User.raw(userString: "machine-user")
        let defaultEnvironment = [
            "PATH=/usr/bin:/bin",
            "CONTAINER_USER=machine-user",
            "CONTAINER_UID=501",
            "CONTAINER_GID=20",
        ]

        #expect(
            command.baseEnvironment(
                defaultEnvironment: defaultEnvironment,
                defaultUser: defaultUser,
                user: defaultUser
            ) == defaultEnvironment
        )
        #expect(
            command.baseEnvironment(
                defaultEnvironment: defaultEnvironment,
                defaultUser: defaultUser,
                user: .id(uid: 0, gid: 0)
            ) == ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
        )
    }
}
