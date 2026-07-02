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

import ContainerRuntimeLinuxClient
import Foundation
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
    func runParsesNetworkHostFlag() throws {
        let command = try Application.ContainerRun.parse(["--network", "host", "alpine", "ip", "addr"])

        #expect(command.managementFlags.networks == ["host"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["ip", "addr"])
    }

    @Test
    func createParsesNetworkHostFlag() throws {
        let command = try Application.ContainerCreate.parse(["--network", "host", "alpine", "ip", "addr"])

        #expect(command.managementFlags.networks == ["host"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["ip", "addr"])
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

    @Test
    func runParsesDeviceCgroupRuleFlag() throws {
        let command = try Application.ContainerRun.parse(["--device-cgroup-rule", "c 1:3 mr", "alpine", "true"])

        #expect(command.managementFlags.deviceCgroupRules == ["c 1:3 mr"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func createParsesDeviceCgroupRuleFlag() throws {
        let command = try Application.ContainerCreate.parse(["--device-cgroup-rule", "a *:* rwm", "alpine", "true"])

        #expect(command.managementFlags.deviceCgroupRules == ["a *:* rwm"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runParsesDeviceFlag() throws {
        let command = try Application.ContainerRun.parse(["--device", "/dev/null:/dev/xnull:rw", "alpine", "true"])

        #expect(command.managementFlags.devices == ["/dev/null:/dev/xnull:rw"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func createParsesDeviceFlag() throws {
        let command = try Application.ContainerCreate.parse(["--device", "/dev/null:rw", "alpine", "true"])

        #expect(command.managementFlags.devices == ["/dev/null:rw"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runtimeDataEncodesDeviceFlag() throws {
        let command = try Application.ContainerRun.parse(["--device", "/dev/null:/dev/xnull:rw", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(
            decoded.devices == [
                LinuxDeviceMapping(source: "/dev/null", target: "/dev/xnull", permissions: "rw")
            ])
    }
}
