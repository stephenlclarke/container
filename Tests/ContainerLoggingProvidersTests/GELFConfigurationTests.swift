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

struct GELFConfigurationTests {
    @Test func resolvesPinnedUDPDefaultsTagAndMetadataPrecedence() throws {
        let info = gelfInfo(
            environment: [
                "shared=environment",
                "container_id=metadata-id",
                "MATCH_ONE=matched",
                "MALFORMED",
            ],
            labels: [
                "team": "runtime",
                "shared": "label",
                "com.example.role": "frontend",
                "ignored": "no",
            ]
        )
        let configuration = try GELFDriverConfiguration.resolve(
            options: [
                "env": "shared,container_id",
                "env-regex": "^MATCH_",
                "gelf-address": "udp://collector.example:12201",
                "labels": "team,shared",
                "labels-regex": "^com\\.",
                "tag": "{{.Name}}/{{.ID}}",
            ],
            info: info
        )

        #expect(
            configuration.endpoint
                == .udp(
                    GELFNetworkAddress(
                        host: "collector.example",
                        port: "12201"
                    )
                )
        )
        #expect(configuration.compressionType == .gzip)
        #expect(configuration.compressionLevel == 1)
        #expect(configuration.maximumReconnects == 3)
        #expect(configuration.reconnectDelay == .seconds(1))
        #expect(configuration.tag == "web/0123456789ab")
        #expect(configuration.hostname == "container-host")
        #expect(configuration.containerName == "web")
        #expect(configuration.command == "/bin/server --listen :8080")
        #expect(
            configuration.metadata
                == [
                    "_MATCH_ONE": "matched",
                    "_com.example.role": "frontend",
                    "_container_id": "metadata-id",
                    "_shared": "environment",
                    "_team": "runtime",
                ]
        )
    }

    @Test func parsesUppercaseIPv6EmptyHostAndIgnoredURLSuffixes() throws {
        #expect(
            try GELFEndpoint.parse("UDP://[::1]:12201/path?ignored=true")
                == .udp(GELFNetworkAddress(host: "::1", port: "12201"))
        )
        #expect(
            try GELFEndpoint.parse("tcp://:12201#fragment")
                == .tcp(GELFNetworkAddress(host: "", port: "12201"))
        )
        #expect(
            throws: GELFProviderError.malformedAddress(
                "udp://user:password@collector:syslog"
            )
        ) {
            try GELFEndpoint.parse("udp://user:password@collector:syslog")
        }
        for address in [
            "udp://collector:+12201",
            "udp://collector:-1",
            "udp://collector:%31%32%32%30%31",
        ] {
            #expect(throws: GELFProviderError.malformedAddress(address)) {
                try GELFEndpoint.parse(address)
            }
        }
    }

    @Test func acceptsCompletePinnedUDPAndTCPNumericDomains() throws {
        for level in -1...9 {
            let configuration = try GELFDriverConfiguration.resolve(
                options: [
                    "gelf-address": "udp://127.0.0.1:12201",
                    "gelf-compression-level": String(level),
                    "gelf-compression-type": "zlib",
                ],
                info: gelfInfo()
            )
            #expect(configuration.compressionLevel == Int32(level))
            #expect(configuration.compressionType == .zlib)
        }

        for value in ["0", "+1", "2147483648"] {
            let configuration = try GELFDriverConfiguration.resolve(
                options: [
                    "gelf-address": "tcp://127.0.0.1:12201",
                    "gelf-tcp-max-reconnect": value,
                    "gelf-tcp-reconnect-delay": value,
                ],
                info: gelfInfo()
            )
            #expect(configuration.maximumReconnects == Int(value))
            #expect(configuration.reconnectDelay == .seconds(Int(value) ?? 0))
        }
    }

    @Test func rejectsMalformedAddressesProtocolCrossoversAndBadNumbers() throws {
        #expect(throws: GELFProviderError.missingAddress) {
            try GELFDriverConfiguration.resolve(options: [:], info: gelfInfo())
        }
        #expect(throws: GELFProviderError.unsupportedAddressScheme("unix")) {
            try GELFEndpoint.parse("unix:///tmp/gelf.sock")
        }
        for address in ["127.0.0.1:12201", "udp://collector", "udp://[::1"] {
            #expect(throws: (any Error).self) {
                try GELFEndpoint.parse(address)
            }
        }
        #expect(throws: GELFProviderError.unknownOption("opaque")) {
            try GELFDriverConfiguration.resolve(
                options: [
                    "gelf-address": "udp://127.0.0.1:12201",
                    "opaque": "value",
                ],
                info: gelfInfo()
            )
        }
        for (option, value) in [
            ("gelf-compression-level", "10"),
            ("gelf-compression-level", " 1"),
            ("gelf-compression-level", "one"),
        ] {
            #expect(throws: (any Error).self) {
                try GELFDriverConfiguration.resolve(
                    options: [
                        "gelf-address": "udp://127.0.0.1:12201",
                        option: value,
                    ],
                    info: gelfInfo()
                )
            }
        }
        for option in ["gelf-compression-level", "gelf-compression-type"] {
            #expect(throws: GELFProviderError.optionRequiresUDP(option)) {
                try GELFDriverConfiguration.resolve(
                    options: [
                        "gelf-address": "tcp://127.0.0.1:12201",
                        option: option == "gelf-compression-level" ? "1" : "gzip",
                    ],
                    info: gelfInfo()
                )
            }
        }
        for option in ["gelf-tcp-max-reconnect", "gelf-tcp-reconnect-delay"] {
            #expect(throws: GELFProviderError.optionRequiresTCP(option)) {
                try GELFDriverConfiguration.resolve(
                    options: [
                        "gelf-address": "udp://127.0.0.1:12201",
                        option: "1",
                    ],
                    info: gelfInfo()
                )
            }
            for value in ["-1", " 1", ""] {
                #expect(throws: (any Error).self) {
                    try GELFDriverConfiguration.resolve(
                        options: [
                            "gelf-address": "tcp://127.0.0.1:12201",
                            option: value,
                        ],
                        info: gelfInfo()
                    )
                }
            }
        }
    }

    @Test func appliesRE2CompatibleSelectionAndRejectsUnsupportedSyntax() throws {
        let configuration = try GELFDriverConfiguration.resolve(
            options: [
                "gelf-address": "udp://127.0.0.1:12201",
                "labels-regex": "^(?:build-)?\\d+$",
            ],
            info: gelfInfo(
                labels: [
                    "123": "ascii",
                    "build-456": "prefixed",
                    "build-١": "unicode",
                ]
            )
        )
        #expect(
            configuration.metadata
                == [
                    "_123": "ascii",
                    "_build-456": "prefixed",
                ]
        )

        let posix = try GELFDriverConfiguration.resolve(
            options: [
                "gelf-address": "udp://127.0.0.1:12201",
                "labels-regex": "^[[:digit:]]+$",
            ],
            info: gelfInfo(labels: ["123": "ascii", "١": "unicode"])
        )
        #expect(posix.metadata == ["_123": "ascii"])

        let exactRE2Cases: [(pattern: String, labels: [String: String], selected: [String: String])] = [
            (#"^\bfoo\b$"#, ["afoo": "no", "foo": "yes", "fooé": "no"], ["_foo": "yes"]),
            (#"^\141+$"#, ["aaa": "yes", "b": "no"], ["_aaa": "yes"]),
            (#"(?U)^a+$"#, ["aaa": "yes", "b": "no"], ["_aaa": "yes"]),
            (#"(?-U)^a+$"#, ["aaa": "yes", "b": "no"], ["_aaa": "yes"]),
            (#"^\Q[a]+\E$"#, ["[a]+": "yes", "aaa": "no"], ["_[a]+": "yes"]),
            (#"^\Q[a]+$"#, ["[a]+$": "yes", "aaa": "no"], ["_[a]+$": "yes"]),
        ]
        for item in exactRE2Cases {
            let resolved = try GELFDriverConfiguration.resolve(
                options: [
                    "gelf-address": "udp://127.0.0.1:12201",
                    "labels-regex": item.pattern,
                ],
                info: gelfInfo(labels: item.labels)
            )
            #expect(resolved.metadata == item.selected)
        }

        for pattern in ["(?=secret)", "a++", "a{1001}", "(a)\\1", "\\1", "\\8"] {
            #expect(throws: (any Error).self) {
                try GELFDriverConfiguration.resolve(
                    options: [
                        "gelf-address": "udp://127.0.0.1:12201",
                        "labels-regex": pattern,
                    ],
                    info: gelfInfo(labels: ["secret": "value"])
                )
            }
        }
    }

    @Test func `rejects docker deferred tag and metadata syntax`() throws {
        let info = gelfInfo(
            environment: ["secret=value"],
            labels: ["secret": "value"],
        )
        #expect(throws: GELFProviderError.invalidTagTemplate("{{.Missing}}")) {
            try GELFDriverConfiguration.resolve(
                options: [
                    "gelf-address": "udp://127.0.0.1:12201",
                    "tag": "{{.Missing}}",
                ],
                info: info,
            )
        }
        for (option, value) in [
            ("labels-regex", "(?=secret)"),
            ("env-regex", "("),
        ] {
            #expect(
                throws: GELFProviderError.invalidMetadataRegularExpression(
                    option: option,
                    value: value,
                ),
            ) {
                try GELFDriverConfiguration.resolve(
                    options: [
                        "gelf-address": "udp://127.0.0.1:12201",
                        option: value,
                    ],
                    info: info,
                )
            }
        }
    }

    @Test func descriptorExposesAllOptionsAtTheirValidationPhases() throws {
        let descriptor = GELFLogDriverContract.descriptor(providerGeneration: 7)
        #expect(descriptor.driver == "gelf")
        #expect(descriptor.providerIdentity == GELFLogDriverContract.providerIdentity)
        #expect(descriptor.providerGeneration == 7)
        #expect(Set(descriptor.options.map(\.name)) == GELFDriverConfiguration.knownOptionNames)
        #expect(descriptor.acceptsUnknownOptions == false)
        #expect(descriptor.capabilities.nativeRead == false)
        #expect(descriptor.capabilities.supportsDualCache)
        #expect(descriptor.capabilities.requiresDeliverySession)

        let byName = Dictionary(uniqueKeysWithValues: descriptor.options.map { ($0.name, $0) })
        for name in [
            "gelf-address",
            "gelf-compression-level",
            "gelf-compression-type",
            "gelf-tcp-max-reconnect",
            "gelf-tcp-reconnect-delay",
        ] {
            #expect(try #require(byName[name]).validationPhase == .create)
        }
        for name in ["env-regex", "labels-regex", "tag"] {
            #expect(try #require(byName[name]).validationPhase == .start)
        }
        for name in ["cache-compress", "cache-max-file", "cache-max-size"] {
            let option = try #require(byName[name])
            #expect(option.valueKind == .string)
            #expect(option.validationPhase == .create)
        }
        #expect(try #require(byName["cache-disabled"]).valueKind == .boolean)
    }
}

private func gelfInfo(
    environment: [String] = [],
    labels: [String: String] = [:]
) -> GELFContainerInfo {
    GELFContainerInfo(
        containerID: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        containerName: "/web",
        containerEntrypoint: "/bin/server",
        containerArguments: ["--listen", ":8080"],
        containerImageID: "sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        containerImageName: "example/web:latest",
        containerCreated: Date(timeIntervalSince1970: 1.25),
        containerEnvironment: environment,
        containerLabels: labels,
        daemonName: "container",
        hostname: "container-host"
    )
}
