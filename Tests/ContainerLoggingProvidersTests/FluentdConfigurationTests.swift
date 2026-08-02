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
struct FluentdConfigurationTests {
    @Test func defaultsMatchPinnedMobyAndFluentLogger() throws {
        let semanticService = try semanticService("defaults")
        let configuration = try FluentdDriverConfiguration.resolve(
            options: [:],
            info: fluentdInfo(),
            semanticService: semanticService
        )

        #expect(
            configuration.endpoint
                == .tcp(
                    FluentdNetworkAddress(
                        host: "127.0.0.1",
                        port: 24_224
                    )
                )
        )
        #expect(configuration.async == false)
        #expect(configuration.asyncReconnectInterval == nil)
        #expect(configuration.bufferLimit == 1_048_576)
        #expect(configuration.maximumRetries == Int(Int32.max))
        #expect(configuration.retryWait == .seconds(1))
        #expect(configuration.requestAcknowledgement == false)
        #expect(configuration.subSecondPrecision == false)
        #expect(configuration.readTimeout == nil)
        #expect(configuration.writeTimeout == nil)
        #expect(configuration.tag == Data("0123456789ab".utf8))
        #expect(configuration.containerID == fluentdInfo().containerID)
        #expect(configuration.containerName == "/web")
        #expect(configuration.metadata.isEmpty)
        #expect(configuration.policy.connectTimeout == .seconds(3))
    }

    @Test func parsesTCPIPv6TLSAndUnixAddressesLikeMoby() throws {
        let semanticService = try semanticService("addresses")
        #expect(
            try FluentdEndpoint.parse(
                "collector.example:123",
                semanticService: semanticService
            )
                == .tcp(
                    FluentdNetworkAddress(host: "collector.example", port: 123)
                )
        )
        #expect(
            try FluentdEndpoint.parse(
                "tcp://[::1]:65535",
                semanticService: semanticService
            )
                == .tcp(FluentdNetworkAddress(host: "::1", port: 65_535))
        )
        #expect(
            try FluentdEndpoint.parse(
                "TCP://collector.example:123",
                semanticService: semanticService
            )
                == .tcp(
                    FluentdNetworkAddress(host: "collector.example", port: 123)
                )
        )
        let rawPortZeroEndpoint = try FluentdEndpoint.parse(
            "tcp://collector.example:0",
            semanticService: semanticService
        )
        let expectedRawPortZeroEndpoint = FluentdEndpoint.tcp(
            FluentdNetworkAddress(host: "collector.example", port: 0)
        )
        #expect(rawPortZeroEndpoint == expectedRawPortZeroEndpoint)
        let portZeroConfiguration = try fluentdTestConfiguration(
            endpoint: rawPortZeroEndpoint
        )
        let effectivePortZeroEndpoint = FluentdEndpoint.tcp(
            FluentdNetworkAddress(
                host: "collector.example",
                port: FluentdEndpoint.defaultPort
            )
        )
        #expect(
            portZeroConfiguration.endpoint
                == effectivePortZeroEndpoint
        )
        #expect(
            try FluentdEndpoint.parse(
                "tls://",
                semanticService: semanticService
            )
                == .tls(
                    FluentdNetworkAddress(
                        host: FluentdEndpoint.defaultHost,
                        port: FluentdEndpoint.defaultPort
                    )
                )
        )
        #expect(
            try FluentdEndpoint.parse(
                "unix:///tmp/fluentd%20log.sock",
                semanticService: semanticService
            )
                == .unix(path: Data("/tmp/fluentd log.sock".utf8))
        )
        #expect(
            try FluentdEndpoint.parse(
                "unix:///tmp/fluentd.sock:80",
                semanticService: semanticService
            )
                == .unix(path: Data("/tmp/fluentd.sock:80".utf8))
        )
    }

    @Test func parsesTypedOptionsAndFluentLoggerZeroFallbacks() throws {
        let semanticService = try semanticService("typed-options")
        let policy = try FluentdConnectionPolicy(
            connectTimeout: .milliseconds(25),
            closeTimeout: .milliseconds(30),
            maximumAcknowledgementBytes: 1_024
        )
        let configuration = try FluentdDriverConfiguration.resolve(
            options: [
                "fluentd-address": "tls://collector.example:24225",
                "fluentd-async": "T",
                "fluentd-async-reconnect-interval": "100.9ms",
                "fluentd-buffer-limit": "0",
                "fluentd-max-retries": "0",
                "fluentd-read-timeout": "250us",
                "fluentd-request-ack": "1",
                "fluentd-retry-wait": "500us",
                "fluentd-sub-second-precision": "TRUE",
                "fluentd-write-timeout": "1.5ms",
            ],
            info: fluentdInfo(),
            semanticService: semanticService,
            policy: policy
        )

        #expect(
            configuration.endpoint
                == .tls(
                    FluentdNetworkAddress(
                        host: "collector.example",
                        port: 24_225
                    )
                )
        )
        #expect(configuration.async)
        #expect(configuration.asyncReconnectInterval == .milliseconds(100))
        #expect(configuration.bufferLimit == 8_192)
        #expect(configuration.maximumRetries == 13)
        #expect(configuration.retryWait == .milliseconds(500))
        #expect(configuration.readTimeout == .microseconds(250))
        #expect(configuration.writeTimeout == .microseconds(1_500))
        #expect(configuration.requestAcknowledgement)
        #expect(configuration.subSecondPrecision)
        #expect(configuration.policy == policy)
    }

    @Test func preservesDockerMetadataPrecedenceAndTagTemplate() throws {
        let semanticService = try semanticService("metadata")
        let configuration = try FluentdDriverConfiguration.resolve(
            options: [
                "labels": "team,shared",
                "labels-regex": "^com\\.",
                "env": "shared,EXPLICIT",
                "env-regex": "^MATCH_",
                "tag": "{{.Name}}/{{.ID}}",
            ],
            info: fluentdInfo(
                environment: [
                    "shared=environment",
                    "EXPLICIT=value",
                    "MATCH_ONE=matched",
                    "IGNORED=no",
                ],
                labels: [
                    "team": "runtime",
                    "shared": "label",
                    "com.example.role": "frontend",
                    "ignored": "no",
                ]
            ),
            semanticService: semanticService
        )

        #expect(configuration.tag == Data("web/0123456789ab".utf8))
        #expect(
            configuration.metadata
                == [
                    "team": "runtime",
                    "shared": "environment",
                    "com.example.role": "frontend",
                    "EXPLICIT": "value",
                    "MATCH_ONE": "matched",
                ]
        )
    }

    @Test func rejectsUnknownMalformedAndOutOfRangeOptions() throws {
        let semanticService = try semanticService("invalid-options")
        #expect(throws: FluentdProviderError.unknownOption("opaque")) {
            try FluentdDriverConfiguration.resolve(
                options: ["opaque": "value"],
                info: fluentdInfo(),
                semanticService: semanticService
            )
        }
        #expect(
            throws: FluentdProviderError.invalidBoolean(
                option: "fluentd-async",
                value: "yes"
            )
        ) {
            try FluentdDriverConfiguration.resolve(
                options: ["fluentd-async": "yes"],
                info: fluentdInfo(),
                semanticService: semanticService
            )
        }
        for interval in ["99ms", "11s", "-1s"] {
            #expect(throws: (any Error).self) {
                try FluentdDriverConfiguration.resolve(
                    options: ["fluentd-async-reconnect-interval": interval],
                    info: fluentdInfo(),
                    semanticService: semanticService
                )
            }
        }
        for (option, value) in [
            ("fluentd-max-retries", "+1"),
            ("fluentd-max-retries", "2147483648"),
            ("fluentd-write-timeout", "-1s"),
            ("fluentd-read-timeout", "1"),
            ("fluentd-buffer-limit", "nonsense"),
        ] {
            #expect(throws: (any Error).self) {
                try FluentdDriverConfiguration.resolve(
                    options: [option: value],
                    info: fluentdInfo(),
                    semanticService: semanticService
                )
            }
        }
        for address in [
            "udp://localhost:24224",
            "tcp://localhost/path",
            "tcp://localhost:65536",
            "unix://",
        ] {
            #expect(throws: (any Error).self) {
                try FluentdEndpoint.parse(
                    address,
                    semanticService: semanticService
                )
            }
        }
    }

    @Test func rejectsNonRE2MetadataPatternsAndAcceptsDockerMetadataCardinality() throws {
        let semanticService = try semanticService("regular-expressions")
        #expect(
            throws: FluentdProviderError.invalidMetadataRegularExpression(
                option: "labels-regex",
                value: "(?=secret)"
            )
        ) {
            try FluentdDriverConfiguration.resolve(
                options: ["labels-regex": "(?=secret)"],
                info: fluentdInfo(labels: ["secret": "value"]),
                semanticService: semanticService
            )
        }
        for pattern in ["a++", "(?#comment)a", "a{1001}", "(a)\\1"] {
            #expect(throws: (any Error).self) {
                try FluentdDriverConfiguration.resolve(
                    options: ["labels-regex": pattern],
                    info: fluentdInfo(labels: ["a": "value"]),
                    semanticService: semanticService
                )
            }
        }

        let asciiConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "^(?:build-)?\\d+$"],
            info: fluentdInfo(
                labels: [
                    "123": "ascii",
                    "build-456": "prefixed",
                    "build-١": "unicode",
                ]
            ),
            semanticService: semanticService
        )
        #expect(
            asciiConfiguration.metadata
                == [
                    "123": "ascii",
                    "build-456": "prefixed",
                ]
        )

        let posixConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "^[[:digit:]]+$"],
            info: fluentdInfo(
                labels: [
                    "123": "ascii",
                    "١": "unicode",
                ]
            ),
            semanticService: semanticService
        )
        #expect(posixConfiguration.metadata == ["123": "ascii"])

        let boundaryConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "\\bprod\\b"],
            info: fluentdInfo(
                labels: [
                    "prod": "plain",
                    "xprodx": "embedded-ascii",
                    "éprodé": "unicode-boundaries",
                ]
            ),
            semanticService: semanticService
        )
        #expect(
            boundaryConfiguration.metadata
                == [
                    "prod": "plain",
                    "éprodé": "unicode-boundaries",
                ]
        )

        let nonBoundaryConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "^\\Bé\\B$"],
            info: fluentdInfo(labels: ["é": "non-word"]),
            semanticService: semanticService
        )
        #expect(nonBoundaryConfiguration.metadata == ["é": "non-word"])

        let octalConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "^\\123$"],
            info: fluentdInfo(labels: ["S": "octal", "123": "digits"]),
            semanticService: semanticService
        )
        #expect(octalConfiguration.metadata == ["S": "octal"])

        let ungreedyConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "(?U)^a.*b$"],
            info: fluentdInfo(labels: ["axxb": "matched"]),
            semanticService: semanticService
        )
        #expect(ungreedyConfiguration.metadata == ["axxb": "matched"])

        let quotedConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": "^\\Qliteral.*\\E$"],
            info: fluentdInfo(
                labels: [
                    "literal.*": "literal",
                    "literal-value": "expanded",
                ]
            ),
            semanticService: semanticService
        )
        #expect(quotedConfiguration.metadata == ["literal.*": "literal"])

        let labels = Dictionary(
            uniqueKeysWithValues: (0...256).map { ("label.\($0)", "value") }
        )
        let metadataConfiguration = try FluentdDriverConfiguration.resolve(
            options: ["labels-regex": ".*"],
            info: fluentdInfo(labels: labels),
            semanticService: semanticService
        )
        #expect(metadataConfiguration.metadata == labels)
    }

    @Test func parsesGoCompoundDurationsAndRetainsNegativeRetryWait() throws {
        let semanticService = try semanticService("durations")
        #expect(
            try FluentdGoDuration.parse("1h2m3.5s", option: "duration")
                == .seconds(3_723) + .milliseconds(500)
        )
        #expect(try FluentdGoDuration.parse("0", option: "duration") == .zero)
        #expect(
            try FluentdGoDuration.parse("0.9ns0.9ns", option: "duration")
                == .zero
        )
        #expect(
            try FluentdGoDuration.parse(
                "9223372036854775807ns",
                option: "duration"
            ) == .nanoseconds(Int64.max)
        )
        #expect(
            try FluentdGoDuration.parse(
                "-9223372036854775808ns",
                option: "duration"
            ) == .nanoseconds(Int64.min)
        )
        #expect(throws: (any Error).self) {
            try FluentdGoDuration.parse(
                "9223372036854775808ns",
                option: "duration"
            )
        }

        let configuration = try FluentdDriverConfiguration.resolve(
            options: ["fluentd-retry-wait": "-1s"],
            info: fluentdInfo(),
            semanticService: semanticService
        )
        #expect(configuration.retryWait == .seconds(-1))
    }

    private func semanticService(
        _ testName: String
    ) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClient(
            generation: DockerSemanticHelperGeneration(
                providerID: "tests.fluentd.\(testName)",
                providerGeneration: 1
            ),
            launchConfiguration: .discover()
        )
    }
}

private func fluentdInfo(
    environment: [String] = [],
    labels: [String: String] = [:]
) -> FluentdContainerInfo {
    FluentdContainerInfo(
        containerID: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        containerName: "/web",
        containerEntrypoint: "/bin/server",
        containerArguments: ["--listen", ":8080"],
        containerImageID: "sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        containerImageName: "example/web:latest",
        containerEnvironment: environment,
        containerLabels: labels,
        daemonName: "container"
    )
}
