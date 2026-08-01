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

import Foundation
import Testing

@testable import ContainerLoggingProviders

struct SyslogConfigurationTests {
    @Test func parsesEveryMobyAddressSchemeAndDefaultPort() throws {
        let paths = FakePathInspector(existing: ["/var/run/syslog", "/tmp/syslog.sock"])

        #expect(try SyslogEndpoint.parse("", pathInspector: paths) == .system)
        #expect(
            try SyslogEndpoint.parse("udp://127.0.0.1", pathInspector: paths)
                == .udp(SyslogNetworkAddress(host: "127.0.0.1", port: "514"))
        )
        #expect(
            try SyslogEndpoint.parse("tcp://logs.example:1514", pathInspector: paths)
                == .tcp(SyslogNetworkAddress(host: "logs.example", port: "1514"))
        )
        #expect(
            try SyslogEndpoint.parse("tcp+tls://[::1]:6514", pathInspector: paths)
                == .tcpTLS(SyslogNetworkAddress(host: "::1", port: "6514"))
        )
        #expect(
            try SyslogEndpoint.parse("unix:///tmp/syslog.sock", pathInspector: paths)
                == .unixStream(path: "/tmp/syslog.sock")
        )
        #expect(
            try SyslogEndpoint.parse("unixgram:///var/run/syslog", pathInspector: paths)
                == .unixDatagram(path: "/var/run/syslog")
        )
    }

    @Test func rejectsUnsupportedMalformedAndMissingUnixAddresses() {
        let paths = FakePathInspector(existing: [])

        #expect(throws: SyslogProviderError.unsupportedAddressScheme("")) {
            try SyslogEndpoint.parse("this is not an uri", pathInspector: paths)
        }
        #expect(throws: SyslogProviderError.unsupportedAddressScheme("http")) {
            try SyslogEndpoint.parse("http://127.0.0.1", pathInspector: paths)
        }
        #expect(throws: SyslogProviderError.malformedAddress("tcp://2001:db8::1")) {
            try SyslogEndpoint.parse("tcp://2001:db8::1", pathInspector: paths)
        }
        #expect(throws: SyslogProviderError.unixSocketDoesNotExist("/missing")) {
            try SyslogEndpoint.parse("unix:///missing", pathInspector: paths)
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
            processID: 42
        )
        #expect(udp.tls == nil)
    }

    @Test func tagFieldsAndRegisteredFunctionsMatchDockerContext() throws {
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

        #expect(try SyslogTagTemplate.render("{{.ID}}", info: info) == "0123456789ab")
        #expect(
            try SyslogTagTemplate.render("{{lower .ImageName}}/{{upper .Name}}", info: info)
                == "example/web:latest/WEB"
        )
        #expect(
            try SyslogTagTemplate.render("{{index .ContainerLabels \"tier\"}}-{{.DaemonName}}", info: info)
                == "frontend-containerd"
        )
        #expect(try SyslogTagTemplate.render("{{truncate .FullID 8}}", info: info) == "sha256:0")
        #expect(
            try SyslogTagTemplate.render("{{json .ContainerLabels}}", info: info)
                == #"{"tier":"frontend"}"#
        )
        #expect(try SyslogTagTemplate.render(#"{{json "value"}}"#, info: info) == #""value""#)
        #expect(
            try SyslogTagTemplate.render(
                #"{{index .Config "syslog-format"}}"#,
                info: info,
                configuration: ["syslog-format": "rfc5424"]
            ) == "rfc5424"
        )
        #expect(throws: SyslogProviderError.invalidTagTemplate("{{.Missing}}")) {
            try SyslogTagTemplate.render("{{.Missing}}", info: info)
        }
        #expect(throws: SyslogProviderError.invalidTagTemplate(#"{{print "ok" "unterminated}}"#)) {
            try SyslogTagTemplate.render(#"{{print "ok" "unterminated}}"#, info: info)
        }
    }

    @Test func emptyTagSelectsDockerDefaultInsteadOfAnEmptyApplicationName() throws {
        let info = SyslogContainerInfo(
            containerID: "0123456789abcdef",
            containerName: "/api",
            hostname: "engine-host"
        )

        let omitted = try SyslogDriverConfiguration.resolve(
            options: [:],
            info: info,
            processID: 42
        )
        let explicitEmpty = try SyslogDriverConfiguration.resolve(
            options: ["tag": ""],
            info: info,
            processID: 42
        )

        #expect(omitted.tag == "0123456789ab")
        #expect(explicitEmpty.tag == omitted.tag)
    }

    @Test func enforcesProviderBoundsAndConfigurationInvariants() throws {
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
                info: info
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
            SyslogNetworkAddress(host: "localhost", port: "514")
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
                tag: "tag",
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

    @Test func rejectsUnknownOptionsAndInvalidFormatsBeforeTransportEffects() {
        let info = SyslogContainerInfo(containerID: "id", containerName: "name")
        #expect(throws: SyslogProviderError.unknownOption("future-option")) {
            try SyslogDriverConfiguration.resolve(
                options: ["future-option": "value"],
                info: info
            )
        }
        #expect(throws: SyslogProviderError.invalidFormat("RFC5424")) {
            try SyslogDriverConfiguration.resolve(
                options: ["syslog-format": "RFC5424"],
                info: info
            )
        }
    }
}

private struct FakePathInspector: SyslogPathInspecting {
    let existing: Set<String>

    func pathExists(_ path: String) -> Bool {
        existing.contains(path)
    }
}
