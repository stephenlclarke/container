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

@testable import ContainerRuntimeLinuxServer

struct RuntimeServiceHostsTests {
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
