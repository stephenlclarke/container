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

import AsyncHTTPClient
import ContainerTestSupport
import Containerization
import ContainerizationExtras
import Foundation
import Testing

@Suite
struct TestCLINetwork {

    // MARK: - Tests

    @available(macOS 26, *)
    @Test func testNetworkCreateAndUse() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try f.doNetworkCreate(net)

            let listResult = try f.run(["network", "ls", "--quiet"]).check()
            let networkIds = listResult.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            #expect(networkIds == networkIds.sorted(), "network IDs should be sorted")

            let port = UInt16.random(in: 50000..<60000)
            try await f.doLongRun(
                name: c, image: "docker.io/library/python:alpine",
                args: ["--network", net],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            let container = try f.inspectContainer(c)
            #expect(container.networks.count > 0)
            let ipv4Address = try #require(container.networks[0].ipv4Address)
            let ip = ipv4Address.address
            let url = "http://\(ip):\(port)"

            // waitForContainerRunning only tells us init is running; the python http
            // server inside is still starting, so retry until it accepts connections.
            let client = f.makeHTTPClient()
            defer { _ = client.shutdown() }
            try await f.retry(attempts: 10) {
                do {
                    var req = HTTPClientRequest(url: url)
                    req.method = .GET
                    let resp = try await client.execute(req, timeout: .seconds(3))
                    return resp.status.code >= 200 && resp.status.code < 300
                } catch {
                    return false
                }
            }
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkDeleteWithContainer() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            f.addCleanup { try? f.doRemove(c, force: true) }

            try f.doNetworkCreate(net)
            try f.doCreate(name: c, networks: [net])

            let deleteResult = try f.run(["network", "delete", net])
            try #require(deleteResult.status != 0, "network delete should fail while container references it")
            #expect(deleteResult.error.contains("delete failed"))
            #expect(deleteResult.error.contains("[\"\(net)\"]"))

            try f.doRemove(c, force: true)
            try f.doNetworkDelete(net)
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkLabels() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try f.doNetworkCreate(net, args: ["--label", "foo=bar", "--label", "baz=qux"])

            let network = try f.inspectNetwork(net)
            let expectedLabels = ["foo": "bar", "baz": "qux"]
            #expect(expectedLabels == network.configuration.labels.dictionary)
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkCreateWithIPv6Disabled() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-no-ipv6"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }

            try f.doNetworkCreate(net, args: ["--disable-ipv6"])

            let network = try f.inspectNetwork(net)
            #expect(!network.configuration.enableIPv6)
            #expect(network.status.ipv6Subnet == nil)
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkCreateWithIPv6Gateway() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-ipv6-gateway"
            let container = "\(f.testID)-ipv6-gateway-client"
            let subnet = "fd42:4242:4242::/64"
            let gateway = "fd42:4242:4242::53"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            f.addCleanup {
                try? f.doStop(container)
                try? f.doRemove(container)
            }

            try f.doNetworkCreate(net, args: ["--subnet-v6", subnet, "--gateway-v6", gateway])

            let network = try f.inspectNetwork(net)
            #expect(network.configuration.ipv6Gateway?.description == gateway)
            #expect(network.status.ipv6Subnet?.description == subnet)
            #expect(network.status.ipv6Gateway?.description == gateway)

            try await f.doLongRun(
                name: container,
                image: "docker.io/library/alpine",
                args: ["--network", net],
                containerArgs: ["sleep", "infinity"],
                autoRemove: false
            )
            try await f.waitForContainerRunning(container)

            let attachment = try #require(try f.inspectContainer(container).networks.first { $0.network == net })
            #expect(attachment.ipv6Address != nil)
            #expect(attachment.ipv6Gateway?.description == gateway)
            let routes = try f.doExec(container, cmd: ["ip", "-6", "route", "show", "default"])
            #expect(routes.contains("via \(gateway)"), "expected IPv6 default route through \(gateway): \(routes)")
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkRequestedIPv4Address() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            let c = "\(f.testID)-c"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }

            try f.doNetworkCreate(net)
            let network = try f.inspectNetwork(net)
            let subnetText = try #require(network.status.ipv4Subnet)
            let subnet = try CIDRv4(subnetText)
            let requestedAddress = IPv4Address(subnet.lower.value + 2)

            try await f.doLongRun(
                name: c,
                image: "docker.io/library/alpine",
                args: ["--network", "\(net),ip=\(requestedAddress)"],
                containerArgs: ["sleep", "infinity"],
                autoRemove: false
            )
            try await f.waitForContainerRunning(c)

            let container = try f.inspectContainer(c)
            let attachment = try #require(container.networks.first { $0.network == net })
            #expect(try #require(attachment.ipv4Address).address == requestedAddress)
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkScopedAttachmentNames() async throws {
        try await ContainerFixture.with { f in
            let frontendNetwork = "\(f.testID)-frontend"
            let backendNetwork = "\(f.testID)-backend"
            let frontendContainer = "\(f.testID)-frontend-service"
            let backendContainer = "\(f.testID)-backend-service"

            f.addCleanup {
                f.doNetworkDeleteIfExists(frontendNetwork)
                f.doNetworkDeleteIfExists(backendNetwork)
            }
            f.addCleanup {
                try? f.doRemove(frontendContainer)
                try? f.doRemove(backendContainer)
            }

            try f.doNetworkCreate(frontendNetwork)
            try f.doNetworkCreate(backendNetwork)

            try f.doCreate(
                name: frontendContainer,
                networks: ["\(frontendNetwork),alias=api"]
            )
            try f.doCreate(
                name: backendContainer,
                networks: ["\(backendNetwork),alias=api"]
            )
        }
    }

    @available(macOS 26, *)
    @Test func testNetworkServiceDiscoveryUsesAttachedNetworkOrder() async throws {
        try await ContainerFixture.with { f in
            let frontendNetwork = "\(f.testID)-dns-frontend"
            let backendNetwork = "\(f.testID)-dns-backend"
            let frontendService = "\(f.testID)-frontend"
            let backendService = "\(f.testID)-backend"
            let client = "\(f.testID)-client"

            f.addCleanup {
                f.doNetworkDeleteIfExists(frontendNetwork)
                f.doNetworkDeleteIfExists(backendNetwork)
            }
            for container in [frontendService, backendService, client] {
                f.addCleanup {
                    try? f.doStop(container)
                    try? f.doRemove(container)
                }
            }

            try f.doNetworkCreate(frontendNetwork)
            try f.doNetworkCreate(backendNetwork)
            try await f.doLongRun(
                name: frontendService,
                args: [
                    "--network", "\(frontendNetwork),alias=API",
                    "--init-image", try f.getConfiguredVminitImage(),
                ],
                autoRemove: false,
                waitUntilRunning: true
            )
            try await f.doLongRun(
                name: backendService,
                args: [
                    "--network", "\(backendNetwork),alias=api",
                    "--init-image", try f.getConfiguredVminitImage(),
                ],
                autoRemove: false,
                waitUntilRunning: true
            )
            try await f.doLongRun(
                name: client,
                args: [
                    "--network", frontendNetwork,
                    "--network", backendNetwork,
                    "--init-image", try f.getConfiguredVminitImage(),
                ],
                autoRemove: false,
                waitUntilRunning: true
            )

            let frontendAttachment = try #require(
                try f.inspectContainer(frontendService).networks.first {
                    $0.network == frontendNetwork
                }
            )
            let frontendAddress = try #require(frontendAttachment.ipv4Address).address.description
            let backendAttachment = try #require(
                try f.inspectContainer(backendService).networks.first {
                    $0.network == backendNetwork
                }
            )
            let backendAddress = try #require(backendAttachment.ipv4Address).address.description

            let primaryLookup = try f.doExec(client, cmd: ["nslookup", frontendService])
            #expect(primaryLookup.contains(frontendAddress))

            let aliasLookup = try f.doExec(client, cmd: ["nslookup", "api"])
            #expect(aliasLookup.contains(frontendAddress))
            #expect(!aliasLookup.contains(backendAddress))

            let canonicalLookup = try f.doExec(client, cmd: ["nslookup", "API."])
            #expect(canonicalLookup.contains(frontendAddress))
            #expect(!canonicalLookup.contains(backendAddress))

            let resolvConf = try f.doExec(client, cmd: ["cat", "/etc/resolv.conf"])
            #expect(resolvConf.contains("nameserver \(DNSProxyProtocol.guestAddress)"))

            let externalLookup = try f.doExec(client, cmd: ["nslookup", "example.com"])
            #expect(externalLookup.lowercased().contains("name:\texample.com"))
        }
    }

    @Test func testNetworkMTU() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let c = "\(f.testID)-c"
            try await f.doLongRun(name: c, image: image, args: ["--network", "default,mtu=1500"], autoRemove: false, waitUntilRunning: true)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            let output = try f.doExec(c, cmd: ["ip", "link", "show", "eth0"])
            #expect(output.contains("mtu 1500"), "expected mtu 1500 in ip link output: \(output)")
        }
    }

    @available(macOS 26, *)
    @Test func testIsolatedNetwork() async {
        await withKnownIssue("curl error 7 despite retries", isIntermittent: true) {
            try await ContainerFixture.with { f in
                let net = "\(f.testID)-net"
                let server = "\(f.testID)-server"
                let pythonImage = "docker.io/library/python:alpine"
                let curlImage = "docker.io/curlimages/curl:8.6.0"

                f.addCleanup { f.doNetworkDeleteIfExists(net) }
                f.addCleanup {
                    try? f.doStop(server)
                    try? f.doRemove(server)
                }

                try f.doNetworkCreate(net, args: ["--internal"])

                let port = UInt16.random(in: 50000..<60000)
                try await f.doLongRun(
                    name: server, image: pythonImage,
                    args: ["--network", net],
                    containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"],
                    autoRemove: false, waitUntilRunning: true)

                let container = try f.inspectContainer(server)
                #expect(container.networks.count > 0)
                let ipv4Address = try #require(container.networks[0].ipv4Address)
                let ip = ipv4Address.address
                let serverURL = "http://\(ip):\(port)"

                // Internal connection should succeed. `waitForContainerRunning` only
                // proves the container's init is up; the python http.server inside
                // may still be starting, so retry until it accepts connections.
                try await f.retry(attempts: 10) {
                    let result = try f.run([
                        "run", "--rm", "--network", net, curlImage,
                        "curl", "--connect-timeout", "3", serverURL,
                    ])
                    return result.status == 0
                }

                // A literal address proves TCP egress is blocked rather than merely
                // relying on the absence of external DNS resolution.
                let externalResult = try f.run([
                    "run", "--rm", "--network", net, curlImage,
                    "curl", "--connect-timeout", "5", "http://1.1.1.1",
                ])
                let hostOnlyBlockedCodes: Set<Int32> = [7, 28]
                #expect(
                    hostOnlyBlockedCodes.contains(externalResult.status),
                    "external connection from isolated network should be blocked, got exit \(externalResult.status)")
            }
        }
    }

    @Test func testNetworkListTableFormat() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            try f.doNetworkCreate(net)

            let result = try f.run(["network", "list"]).check()
            #expect(["NETWORK", "SUBNET"].allSatisfy { result.output.contains($0) })
            #expect(result.output.contains(net))
        }
    }

    @Test func testNetworkListJSONFormat() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            try f.doNetworkCreate(net)

            let result = try f.run(["network", "list", "--format", "json"]).check()
            guard let json = try JSONSerialization.jsonObject(with: result.outputData) as? [[String: Any]] else {
                Issue.record("JSON output should be an array of objects")
                return
            }
            #expect(json.contains { ($0["id"] as? String) == net })
        }
    }

    @Test func testInspectMissingNetworkFails() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["network", "inspect", "definitely-missing-\(f.testID)"])
            #expect(result.status != 0)
            #expect(result.error.contains("network not found"))
        }
    }
}
