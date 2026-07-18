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
    func runParsesSecurityOptionFlag() throws {
        let command = try Application.ContainerRun.parse(["--security-opt", "no-new-privileges:true", "alpine", "id"])

        #expect(command.managementFlags.securityOpts == ["no-new-privileges:true"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["id"])
    }

    @Test
    func createParsesSecurityOptionFlag() throws {
        let command = try Application.ContainerCreate.parse(["--security-opt", "no-new-privileges=false", "alpine", "id"])

        #expect(command.managementFlags.securityOpts == ["no-new-privileges=false"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["id"])
    }

    @Test
    func runParsesStopDefaults() throws {
        let command = try Application.ContainerRun.parse([
            "--stop-signal", "SIGUSR1",
            "--stop-timeout", "9",
            "alpine", "sleep", "infinity",
        ])

        #expect(command.managementFlags.stopSignal == "SIGUSR1")
        #expect(command.managementFlags.stopTimeout == 9)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["sleep", "infinity"])
    }

    @Test
    func createRejectsNegativeStopTimeout() throws {
        #expect(throws: (any Error).self) {
            _ = try Application.ContainerCreate.parse([
                "--stop-timeout", "-1",
                "alpine", "sleep", "infinity",
            ])
        }
    }

    @Test
    func runParsesFractionalCPUFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpus", "0.25", "alpine", "sleep", "infinity"])

        #expect(command.resourceFlags.cpus == 0.25)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["sleep", "infinity"])
    }

    @Test
    func runParsesUnlimitedCPUFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpus", "0", "alpine", "sleep", "infinity"])

        #expect(command.resourceFlags.cpus == 0)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["sleep", "infinity"])
    }

    @Test
    func createParsesCPUQuotaAndPeriodFlags() throws {
        let command = try Application.ContainerCreate.parse([
            "--cpu-period", "200000",
            "--cpu-quota", "50000",
            "alpine", "sleep", "infinity",
        ])

        #expect(command.resourceFlags.cpuPeriod == 200_000)
        #expect(command.resourceFlags.cpuQuota == 50_000)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["sleep", "infinity"])
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
    func runParsesPidsLimitFlag() throws {
        let command = try Application.ContainerRun.parse(["--pids-limit", "128", "alpine", "true"])

        #expect(command.managementFlags.pidsLimit == 128)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func createParsesPidsLimitFlag() throws {
        let command = try Application.ContainerCreate.parse(["--pids-limit", "-1", "alpine", "true"])

        #expect(command.managementFlags.pidsLimit == -1)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runParsesMemoryReservationFlag() throws {
        let command = try Application.ContainerRun.parse(["--memory-reservation", "512m", "alpine", "true"])

        #expect(command.managementFlags.memoryReservation == "512m")
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runParsesMemorySwapFlag() throws {
        let command = try Application.ContainerRun.parse(["--memory-swap", "1g", "alpine", "true"])

        #expect(command.managementFlags.memorySwap == "1g")
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func createParsesUnlimitedMemorySwapFlag() throws {
        let command = try Application.ContainerCreate.parse(["--memory-swap", "-1", "alpine", "true"])

        #expect(command.managementFlags.memorySwap == "-1")
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runParsesCPUSharesFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpu-shares", "512", "alpine", "true"])

        #expect(command.managementFlags.cpuShares == 512)
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
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

    @Test
    func runParsesGPUsFlag() throws {
        let command = try Application.ContainerRun.parse(["--gpus", "all", "alpine", "true"])

        #expect(command.managementFlags.gpus == ["all"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func createParsesGPUsFlag() throws {
        let command = try Application.ContainerCreate.parse(["--gpus", "device=0", "alpine", "true"])

        #expect(command.managementFlags.gpus == ["device=0"])
        #expect(command.image == "alpine")
        #expect(command.arguments == ["true"])
    }

    @Test
    func runtimeDataEncodesGPUsFlag() throws {
        let command = try Application.ContainerRun.parse(["--gpus", "all", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.gpuRequests == [LinuxGPURequest(count: -1)])
    }

    @Test
    func runtimeDataEncodesPidsLimitFlag() throws {
        let command = try Application.ContainerRun.parse(["--pids-limit", "128", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.pidsLimit == 128)
    }

    @Test
    func runtimeDataEncodesMemoryReservationFlag() throws {
        let command = try Application.ContainerRun.parse(["--memory-reservation", "512m", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.memoryReservationInBytes == Int64(512.mib()))
    }

    @Test
    func runtimeDataEncodesMemorySwapFlag() throws {
        let command = try Application.ContainerRun.parse(["--memory-swap", "-1", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.memorySwapLimitInBytes == -1)
    }

    @Test
    func runtimeDataEncodesCPUSharesFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpu-shares", "512", "alpine", "true"])

        let data = try #require(try LinuxRuntimeData.encoded(from: command.managementFlags))
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.cpuShares == 512)
    }

    @Test
    func runtimeDataOmitsDefaultCPUSharesFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpu-shares", "0", "alpine", "true"])

        #expect(try LinuxRuntimeData.encoded(from: command.managementFlags) == nil)
    }

    @Test
    func runtimeDataRejectsInvalidCPUSharesFlag() throws {
        let command = try Application.ContainerRun.parse(["--cpu-shares", "1", "alpine", "true"])

        #expect {
            _ = try LinuxRuntimeData.encoded(from: command.managementFlags)
        } throws: { _ in
            true
        }
    }

    @Test
    func runtimeDataRejectsInvalidPidsLimitFlag() throws {
        let command = try Application.ContainerRun.parse(["--pids-limit", "0", "alpine", "true"])

        #expect {
            _ = try LinuxRuntimeData.encoded(from: command.managementFlags)
        } throws: { _ in
            true
        }
    }
}
