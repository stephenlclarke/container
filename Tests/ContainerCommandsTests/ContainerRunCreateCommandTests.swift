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

import Testing

@testable import ContainerCommands

struct ContainerRunCreateCommandTests {
    @Test
    func runParsesPrivilegedFlag() throws {
        let command = try Application.ContainerRun.parse(["--privileged", "alpine", "id"])

        #expect(command.processFlags.privileged)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["id"])
    }

    @Test
    func createParsesPrivilegedFlag() throws {
        let command = try Application.ContainerCreate.parse(["--privileged", "alpine", "id"])

        #expect(command.processFlags.privileged)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["id"])
    }

    @Test
    func runParsesPIDHostFlag() throws {
        let command = try Application.ContainerRun.parse(["--pid", "host", "alpine", "ps"])

        #expect(command.managementFlags.pid == "host")
        #expect(command.image == "alpine")
        #expect(command.arguments == ["ps"])
    }

    @Test
    func createParsesPIDHostFlag() throws {
        let command = try Application.ContainerCreate.parse(["--pid", "host", "alpine", "ps"])

        #expect(command.managementFlags.pid == "host")
        #expect(command.image == "alpine")
        #expect(command.arguments == ["ps"])
    }
}
