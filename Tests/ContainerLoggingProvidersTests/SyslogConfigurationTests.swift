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

import DockerSemanticHelper
import Foundation
import Testing

@testable import ContainerLoggingProviders

@Suite(.serialized)
struct SyslogConfigurationTests {
    @Test func parsesEveryMobyAddressSchemeAndDefaultPort() throws {
        let semanticService = try semanticService("addresses")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let streamPath = directory.appendingPathComponent("stream.sock").path
        let datagramPath = directory.appendingPathComponent("datagram.sock").path
        try Data().write(to: URL(fileURLWithPath: streamPath))
        try Data().write(to: URL(fileURLWithPath: datagramPath))

        #expect(
            try SyslogEndpoint.parse("", semanticService: semanticService)
                == .system
        )
        #expect(
            try SyslogEndpoint.parse(
                "udp://127.0.0.1",
                semanticService: semanticService
            )
                == .udp(SyslogNetworkAddress(host: "127.0.0.1", port: 514))
        )
        #expect(
            try SyslogEndpoint.parse(
                "tcp://logs.example:1514",
                semanticService: semanticService
            )
                == .tcp(SyslogNetworkAddress(host: "logs.example", port: 1_514))
        )
        #expect(
            try SyslogEndpoint.parse(
                "tcp+tls://[::1]:6514",
                semanticService: semanticService
            )
                == .tcpTLS(SyslogNetworkAddress(host: "::1", port: 6_514))
        )
        #expect(
            try SyslogEndpoint.parse(
                "unix://\(streamPath)",
                semanticService: semanticService
            )
                == .unixStream(path: Data(streamPath.utf8))
        )
        #expect(
            try SyslogEndpoint.parse(
                "unixgram://\(datagramPath)",
                semanticService: semanticService
            )
                == .unixDatagram(path: Data(datagramPath.utf8))
        )
    }

    @Test func rejectsUnsupportedMalformedAndMissingUnixAddresses() throws {
        let semanticService = try semanticService("invalid-addresses")

        #expect(throws: SyslogProviderError.malformedAddress("this is not an uri")) {
            try SyslogEndpoint.parse(
                "this is not an uri",
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.malformedAddress("http://127.0.0.1")) {
            try SyslogEndpoint.parse(
                "http://127.0.0.1",
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.malformedAddress("tcp://2001:db8::1")) {
            try SyslogEndpoint.parse(
                "tcp://2001:db8::1",
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.malformedAddress("unix:///missing")) {
            try SyslogEndpoint.parse(
                "unix:///missing",
                semanticService: semanticService
            )
        }
    }

    @Test func facilityNamesAndNumbersMatchMobyPriorities() throws {
        #expect(try SyslogFacility.parse("").number == 3)
        #expect(try SyslogFacility.parse("daemon").number == 3)
        #expect(try SyslogFacility.parse("local7").number == 23)
        #expect(try SyslogFacility.parse("0").number == 0)
        #expect(try SyslogFacility.parse("23").number == 23)
        #expect(try SyslogFacility.parse("daemon").priority(for: .stdout) == 30)
        #expect(try SyslogFacility.parse("daemon").priority(for: .stderr) == 27)
        #expect(throws: SyslogProviderError.invalidFacility("24")) {
            try SyslogFacility.parse("24")
        }
        #expect(throws: SyslogProviderError.invalidFacility("DAEMON")) {
            try SyslogFacility.parse("DAEMON")
        }
    }

    @Test func resolvesDockerTLSPresenceAndIgnoresTLSOptionsForPlainTransports() throws {
        let semanticService = try semanticService("tls")
        let info = SyslogContainerInfo(
            containerID: "0123456789abcdef",
            containerName: "/api",
            hostname: "engine-host"
        )
        let tls = try SyslogDriverConfiguration.resolve(
            options: [
                "syslog-address": "tcp+tls://logs.example:6514",
                "syslog-tls-ca-cert": "/ca.pem",
                "syslog-tls-cert": "/cert.pem",
                "syslog-tls-key": "/key.pem",
                "syslog-tls-skip-verify": "false",
            ],
            info: info,
            semanticService: semanticService,
            processID: 42
        )
        #expect(tls.tls?.skipServerVerification == true)
        #expect(tls.tls?.caCertificatePath == "/ca.pem")

        let udp = try SyslogDriverConfiguration.resolve(
            options: [
                "syslog-address": "udp://logs.example",
                "syslog-tls-ca-cert": "/missing.pem",
            ],
            info: info,
            semanticService: semanticService,
            processID: 42
        )
        #expect(udp.tls == nil)
    }

    @Test func tagFieldsAndRegisteredFunctionsMatchDockerContext() throws {
        let semanticService = try semanticService("tags")
        let info = SyslogContainerInfo(
            containerID: "sha256:0123456789abcdef",
            containerName: "/web",
            containerEntrypoint: "/bin/server",
            containerArguments: ["--port", "8080"],
            containerImageID: "sha256:fedcba9876543210",
            containerImageName: "Example/Web:Latest",
            containerLabels: ["tier": "frontend"],
            daemonName: "containerd",
            hostname: "engine-host"
        )

        #expect(
            try resolvedTag(
                "{{.ID}}",
                info: info,
                semanticService: semanticService
            ) == Data("sha256:01234".utf8)
        )
        #expect(
            try resolvedTag(
                "{{lower .ImageName}}/{{upper .Name}}",
                info: info,
                semanticService: semanticService
            ) == Data("example/web:latest/WEB".utf8)
        )
        #expect(
            try resolvedTag(
                "{{index .ContainerLabels \"tier\"}}-{{.DaemonName}}",
                info: info,
                semanticService: semanticService
            ) == Data("frontend-containerd".utf8)
        )
        #expect(
            try resolvedTag(
                "{{truncate .FullID 8}}",
                info: info,
                semanticService: semanticService
            ) == Data("sha256:0".utf8)
        )
        #expect(
            try resolvedTag(
                "{{json .ContainerLabels}}",
                info: info,
                semanticService: semanticService
            ) == Data(#"{"tier":"frontend"}"#.utf8)
        )
        #expect(
            try resolvedTag(
                #"{{json "value"}}"#,
                info: info,
                semanticService: semanticService
            ) == Data(#""value""#.utf8)
        )
        #expect(
            try resolvedTag(
                #"{{index .Config "syslog-format"}}"#,
                info: info,
                semanticService: semanticService,
                configuration: ["syslog-format": "rfc5424"]
            ) == Data("rfc5424".utf8)
        )
        #expect(throws: SyslogProviderError.invalidTagTemplate("{{.Missing}}")) {
            try resolvedTag(
                "{{.Missing}}",
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.invalidTagTemplate(#"{{print "ok" "unterminated}}"#)) {
            try resolvedTag(
                #"{{print "ok" "unterminated}}"#,
                info: info,
                semanticService: semanticService
            )
        }
    }

    @Test func emptyTagSelectsDockerDefaultInsteadOfAnEmptyApplicationName() throws {
        let semanticService = try semanticService("default-tag")
        let info = SyslogContainerInfo(
            containerID: "0123456789abcdef",
            containerName: "/api",
            hostname: "engine-host"
        )

        let omitted = try SyslogDriverConfiguration.resolve(
            options: [:],
            info: info,
            semanticService: semanticService,
            processID: 42
        )
        let explicitEmpty = try SyslogDriverConfiguration.resolve(
            options: ["tag": ""],
            info: info,
            semanticService: semanticService,
            processID: 42
        )

        #expect(omitted.tag == Data("0123456789ab".utf8))
        #expect(explicitEmpty.tag == omitted.tag)
    }

    @Test func enforcesProviderBoundsAndConfigurationInvariants() throws {
        let semanticService = try semanticService("bounds")
        let info = SyslogContainerInfo(containerID: "id", containerName: "name")
        let oversized = String(
            repeating: "x",
            count: SyslogDriverConfiguration.maximumTagUTF8Bytes + 1
        )
        #expect(
            throws: SyslogProviderError.tagExceedsUTF8Limit(
                maximumBytes: SyslogDriverConfiguration.maximumTagUTF8Bytes
            )
        ) {
            try SyslogDriverConfiguration.resolve(
                options: ["tag": oversized],
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.invalidConnectionPolicy) {
            try SyslogConnectionPolicy(
                connectTimeout: .zero,
                writeTimeout: .seconds(1),
                closeTimeout: .seconds(1)
            )
        }

        let plain = SyslogEndpoint.tcp(
            SyslogNetworkAddress(host: "localhost", port: 514)
        )
        #expect(
            throws: SyslogProviderError.invalidTLSConfiguration(
                "TLS configuration does not match the endpoint"
            )
        ) {
            try SyslogDriverConfiguration(
                endpoint: plain,
                facility: SyslogFacility(number: 3),
                format: .unix,
                tag: Data("tag".utf8),
                hostname: "host",
                processID: 1,
                tls: SyslogTLSConfiguration(
                    caCertificatePath: "",
                    clientCertificatePath: "",
                    clientPrivateKeyPath: "",
                    skipServerVerification: false
                ),
                policy: .dockerCompatible
            )
        }
    }

    @Test func rejectsUnknownOptionsAndInvalidFormatsBeforeTransportEffects() throws {
        let semanticService = try semanticService("invalid-options")
        let info = SyslogContainerInfo(containerID: "id", containerName: "name")
        #expect(throws: SyslogProviderError.unknownOption("future-option")) {
            try SyslogDriverConfiguration.resolve(
                options: ["future-option": "value"],
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SyslogProviderError.invalidFormat("RFC5424")) {
            try SyslogDriverConfiguration.resolve(
                options: ["syslog-format": "RFC5424"],
                info: info,
                semanticService: semanticService
            )
        }
    }

    private func resolvedTag(
        _ template: String,
        info: SyslogContainerInfo,
        semanticService: any DockerSemanticServicing,
        configuration: [String: String] = [:]
    ) throws -> Data {
        var options = configuration
        options["tag"] = template
        return try SyslogDriverConfiguration.resolve(
            options: options,
            info: info,
            semanticService: semanticService
        ).tag
    }

    private func semanticService(
        _ testName: String
    ) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClient(
            generation: DockerSemanticHelperGeneration(
                providerID: "tests.syslog.\(testName)",
                providerGeneration: 1
            ),
            launchConfiguration: .discover()
        )
    }
}
