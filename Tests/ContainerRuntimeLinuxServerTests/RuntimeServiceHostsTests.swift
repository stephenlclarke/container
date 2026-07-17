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
import ContainerRuntimeLinuxClient
import Containerization
import ContainerizationExtras
import Testing

@testable import ContainerRuntimeLinuxServer

struct RuntimeServiceHostsTests {
    @Test
    func ownedFileMountPassesOwnershipToContainerization() {
        var filesystem = Filesystem.virtiofs(
            source: "/tmp/config.txt",
            destination: "/etc/config.txt",
            options: ["ro"]
        )
        filesystem.fileOwnership = .init(uid: 1000, gid: 1001)

        let mount = filesystem.asMount

        #expect(mount.fileOwnership == .init(uid: 1000, gid: 1001))
    }

    @Test
    func volumeMountPassesSubpathToContainerization() {
        let filesystem = Filesystem.volume(
            name: "data",
            format: "ext4",
            source: "/tmp/data.img",
            destination: "/data",
            options: ["ro"],
            subpath: "logs/app"
        )

        let mount = filesystem.asMount

        #expect(mount.sourceSubpath == "logs/app")
    }

    @Test
    func isolatedInterfaceStrategyPassesGuestInterfaceNameToContainerization() throws {
        let attachment = Attachment(
            network: "default",
            hostname: "demo-api-1",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )

        let interface = IsolatedInterfaceStrategy().toInterface(
            attachment: attachment,
            interfaceIndex: 0,
            guestInterfaceName: "frontend",
            additionalData: nil
        )

        #expect(interface.guestInterfaceName == "frontend")
    }

    @Test
    func isolatedInterfaceStrategyPassesAdditionalIPAddressesToContainerization() throws {
        let attachment = Attachment(
            network: "default",
            hostname: "demo-api-1",
            ipv4Address: try CIDRv4("192.168.64.2/24"),
            ipv4Gateway: try IPv4Address("192.168.64.1"),
            ipv6Address: nil,
            macAddress: nil
        )

        let interface = IsolatedInterfaceStrategy().toInterface(
            attachment: attachment,
            interfaceIndex: 0,
            guestInterfaceName: nil,
            additionalIPAddresses: [try CIDR("198.51.100.8/32")],
            additionalData: nil
        )

        #expect(interface.additionalIPAddresses == [try CIDR("198.51.100.8/32")])
    }

    @Test
    func resolvedHostnamePrefersConfiguredHostname() {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.hostname = "custom-api"
        config.networks = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "demo-api-1.example.test.")
            )
        ]

        #expect(RuntimeService.resolvedHostname(config: config) == "custom-api")
    }

    @Test
    func resolvedHostnameUsesShortNameFromFirstNetworkAttachment() {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.networks = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "demo-api-1.example.test.")
            )
        ]

        #expect(RuntimeService.resolvedHostname(config: config) == "demo-api-1")
    }

    @Test
    func resolvedHostnameFallsBackToContainerId() {
        let config = runtimeTestConfiguration(id: "demo-api-1")

        #expect(RuntimeService.resolvedHostname(config: config) == "demo-api-1")
    }

    @Test
    func resolvedSysctlsMapsDomainname() throws {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.domainname = "example.test"

        let sysctls = try RuntimeService.resolvedSysctls(config: config)

        #expect(sysctls[RuntimeService.domainnameSysctl] == "example.test")
    }

    @Test
    func resolvedSysctlsPreservesConfiguredSysctls() throws {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.sysctls = ["net.ipv4.ip_forward": "1"]

        let sysctls = try RuntimeService.resolvedSysctls(config: config)

        #expect(sysctls == ["net.ipv4.ip_forward": "1"])
    }

    @Test
    func resolvedSysctlsPreservesMatchingDomainnameSysctl() throws {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.domainname = "example.test"
        config.sysctls = [RuntimeService.domainnameSysctl: "example.test"]

        let sysctls = try RuntimeService.resolvedSysctls(config: config)

        #expect(sysctls[RuntimeService.domainnameSysctl] == "example.test")
    }

    @Test
    func resolvedSysctlsRejectsConflictingDomainnameSysctl() {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.domainname = "example.test"
        config.sysctls = [RuntimeService.domainnameSysctl: "other.test"]

        #expect(throws: (any Error).self) {
            _ = try RuntimeService.resolvedSysctls(config: config)
        }
    }

    @Test
    func resolvedHostsIncludesDefaultsPrimaryAddressAndExtraHosts() throws {
        let hosts = try RuntimeService.resolvedHosts(
            hostname: "web",
            primaryAddress: "192.168.64.22",
            extraHosts: [
                .init(ipAddress: "192.168.64.1", hostnames: ["host.docker.internal"]),
                .init(ipAddress: "10.0.0.15", hostnames: ["db", "db.internal"]),
            ]
        )

        #expect(
            hosts.map(\.ipAddress) == [
                "127.0.0.1",
                "192.168.64.22",
                "192.168.64.1",
                "10.0.0.15",
            ])
        #expect(
            hosts.map(\.hostnames) == [
                ["localhost"],
                ["web"],
                ["host.docker.internal"],
                ["db", "db.internal"],
            ])
    }

    @Test
    func resolvedHostsResolvesHostGatewayToPrimaryGateway() throws {
        let hosts = try RuntimeService.resolvedHosts(
            hostname: "web",
            primaryAddress: "192.168.64.22",
            gatewayAddress: "192.168.64.1",
            extraHosts: [
                .init(ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress, hostnames: ["host.docker.internal"])
            ]
        )

        #expect(hosts.map(\.ipAddress) == ["127.0.0.1", "192.168.64.22", "192.168.64.1"])
        #expect(hosts.map(\.hostnames) == [["localhost"], ["web"], ["host.docker.internal"]])
    }

    @Test
    func resolvedHostsRejectsHostGatewayWithoutGatewayAddress() {
        #expect(throws: (any Error).self) {
            _ = try RuntimeService.resolvedHosts(
                hostname: "web",
                primaryAddress: nil,
                extraHosts: [
                    .init(ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress, hostnames: ["host.docker.internal"])
                ]
            )
        }
    }

    @Test
    func resolvedHostsDoesNotAddPrimaryAddressWhenNetworkingIsDisabled() throws {
        let hosts = try RuntimeService.resolvedHosts(
            hostname: "web",
            primaryAddress: nil,
            extraHosts: [.init(ipAddress: "10.0.0.15", hostnames: ["db"])]
        )

        #expect(hosts.map(\.ipAddress) == ["127.0.0.1", "10.0.0.15"])
        #expect(hosts.map(\.hostnames) == [["localhost"], ["db"]])
    }

    @Test
    func hostNetworkSuppressesSocketForwarders() {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.hostNetwork = true

        #expect(!RuntimeService.shouldStartSocketForwarders(config: config, hasInterfaces: true))
    }

    @Test
    func attachedNetworkingStartsSocketForwardersWhenNeeded() {
        let config = runtimeTestConfiguration(id: "demo-api-1")

        #expect(RuntimeService.shouldStartSocketForwarders(config: config, hasInterfaces: true))
        #expect(!RuntimeService.shouldStartSocketForwarders(config: config, hasInterfaces: false))
    }

    @Test
    func resolveLinuxDeviceUsesLinuxMajorMinorValues() throws {
        let metadata = try RuntimeService.resolveLinuxDevice(source: "/dev/null")

        #expect(metadata.type == "c")
        #expect(metadata.major == 1)
        #expect(metadata.minor == 3)
        #expect(metadata.fileMode == 0o666)
    }

    @Test
    func resolveDeviceMappingsCreatesDeviceNodesAndCgroupRules() throws {
        let resolved = try RuntimeService.resolveDeviceMappings([
            LinuxDeviceMapping(source: "/dev/null", target: "/dev/xnull", permissions: "rw"),
            LinuxDeviceMapping(source: "/dev/zero", target: "/dev/zero", permissions: "rwm"),
        ])

        #expect(resolved.devices.count == 2)
        #expect(resolved.devices[0].path == "/dev/xnull")
        #expect(resolved.devices[0].type == "c")
        #expect(resolved.devices[0].major == 1)
        #expect(resolved.devices[0].minor == 3)
        #expect(resolved.cgroupRules[0].access == "rw")
        #expect(resolved.devices[1].path == "/dev/zero")
        #expect(resolved.devices[1].major == 1)
        #expect(resolved.devices[1].minor == 5)
        #expect(resolved.cgroupRules[1].access == "rwm")
    }

    @Test
    func resolveLinuxDeviceRejectsUnknownDeviceSources() {
        #expect(throws: (any Error).self) {
            _ = try RuntimeService.resolveLinuxDevice(source: "/dev/not-a-known-device")
        }
    }

    @Test
    func resolveGPURequestsCreatesVirtioDRMGuestDeviceRequests() throws {
        let resolved = try RuntimeService.resolveGPURequests([LinuxGPURequest(count: -1)])

        #expect(resolved.enabled)
        #expect(resolved.guestDevices.map(\.path) == ["/dev/dri/card0", "/dev/dri/renderD128"])
        #expect(resolved.guestDevices.map(\.permissions) == ["rwm", "rwm"])
        #expect(resolved.guestDevices.map(\.required) == [false, true])
    }

    @Test
    func resolveGPURequestsAcceptsDeviceZero() throws {
        let resolved = try RuntimeService.resolveGPURequests([
            LinuxGPURequest(count: 0, deviceIDs: ["0"])
        ])

        #expect(resolved.enabled)
    }

    @Test(arguments: [
        LinuxGPURequest(driver: "nvidia"),
        LinuxGPURequest(count: 2),
        LinuxGPURequest(count: 0, deviceIDs: ["1"]),
        LinuxGPURequest(capabilities: ["compute", "gpu"]),
        LinuxGPURequest(options: ["mode": "fast"]),
    ])
    func resolveGPURequestsRejectsUnsupportedSemantics(request: LinuxGPURequest) {
        #expect(throws: (any Error).self) {
            _ = try RuntimeService.resolveGPURequests([request])
        }
    }

    @Test
    func execCapabilitiesHonorContainerCapabilityDropsByDefault() throws {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.capDrop = ["ALL"]
        let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])

        let capabilities = try RuntimeService.execCapabilities(containerConfig: config, processConfig: process)

        #expect(capabilities.bounding.isEmpty)
        #expect(capabilities.effective.isEmpty)
        #expect(capabilities.permitted.isEmpty)
    }

    @Test
    func privilegedExecCapabilitiesUseAllCapabilities() throws {
        var config = runtimeTestConfiguration(id: "demo-api-1")
        config.capDrop = ["ALL"]
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            privileged: true
        )

        let capabilities = try RuntimeService.execCapabilities(containerConfig: config, processConfig: process)
        let allCapabilities = LinuxCapabilities.allCapabilities

        #expect(Set(capabilities.bounding) == Set(allCapabilities.bounding))
        #expect(Set(capabilities.effective) == Set(allCapabilities.effective))
        #expect(Set(capabilities.permitted) == Set(allCapabilities.permitted))
        #expect(Set(capabilities.ambient) == Set(allCapabilities.ambient))
    }

    private func runtimeTestConfiguration(id: String) -> ContainerConfiguration {
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
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }
}
