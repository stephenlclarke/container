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

struct SplunkConfigurationTests {
    @Test func resolvesPinnedDefaultsRequiredOptionsAndProtectedContract() throws {
        let semanticService = try helper("defaults")
        let info = splunkInfo()
        let configuration = try SplunkDriverConfiguration.resolve(
            options: [
                "splunk-url": "https://collector.example:8088/",
                "splunk-token": "protected",
            ],
            info: info,
            semanticService: semanticService
        )

        #expect(
            configuration.endpoint.eventURL
                == "https://collector.example:8088/services/collector/event/1.0"
        )
        #expect(configuration.token == "protected")
        #expect(configuration.format == .inline)
        #expect(configuration.tag == info.shortContainerID)
        #expect(configuration.verifyConnection)
        #expect(!configuration.gzipEnabled)
        #expect(configuration.gzipLevel == -1)
        #expect(!configuration.indexAcknowledgement)
        #expect(configuration.policy.postBatchSize == 1_000)
        #expect(configuration.policy.bufferMaximum == 10_000)
        #expect(configuration.policy.streamCapacity == 4_000)

        let descriptor = SplunkLogDriverContract.descriptor(
            providerGeneration: 9
        )
        #expect(descriptor.driver == "splunk")
        #expect(descriptor.providerGeneration == 9)
        #expect(descriptor.capabilities.supportsDualCache)
        let token = try #require(
            descriptor.options.first { $0.name == "splunk-token" }
        )
        #expect(token.isSecret)
        #expect(token.validationPhase == .start)
        #expect(
            Set(descriptor.options.map(\.name))
                == SplunkDriverConfiguration.knownOptionNames
        )
        #expect(!String(describing: configuration).contains("protected"))
        #expect(!String(reflecting: configuration).contains("protected"))
    }

    @Test func resolvesTLSFormatsBooleansTagAndMetadataLikeMoby() throws {
        let semanticService = try helper("options")
        let configuration = try SplunkDriverConfiguration.resolve(
            options: [
                "splunk-url": "HTTP://127.0.0.1:8088",
                "splunk-token": "token",
                "splunk-source": "application",
                "splunk-sourcetype": "json",
                "splunk-index": "main",
                "splunk-format": "raw",
                "splunk-gzip": "TRUE",
                "splunk-gzip-level": "9",
                "splunk-index-acknowledgment": "1",
                "splunk-verify-connection": "false",
                "splunk-insecureskipverify": "t",
                "tag": "",
                "labels": "selected",
                "env-regex": "^PUBLIC_",
            ],
            info: splunkInfo(
                environment: ["PUBLIC_KEY=value", "SECRET=hidden"],
                labels: ["selected": "label", "ignored": "value"]
            ),
            semanticService: semanticService
        )
        #expect(configuration.endpoint.baseURL == "http://127.0.0.1:8088")
        #expect(configuration.tls == nil)
        #expect(configuration.source == "application")
        #expect(configuration.sourceType == "json")
        #expect(configuration.index == "main")
        #expect(configuration.format == .raw)
        #expect(configuration.gzipEnabled)
        #expect(configuration.gzipLevel == 9)
        #expect(configuration.indexAcknowledgement)
        #expect(!configuration.verifyConnection)
        #expect(configuration.tag.isEmpty)
        #expect(
            configuration.metadata == [
                "PUBLIC_KEY": "value",
                "selected": "label",
            ])
    }

    @Test func rejectsUnknownMissingMalformedAndDeferredTypedValues() throws {
        let semanticService = try helper("invalid")
        let info = splunkInfo()
        #expect(throws: SplunkProviderError.unknownOption("future")) {
            try SplunkDriverConfiguration.resolve(
                options: ["future": "value"],
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SplunkProviderError.missingURL) {
            try SplunkDriverConfiguration.resolve(
                options: ["splunk-token": "token"],
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SplunkProviderError.missingToken) {
            try SplunkDriverConfiguration.resolve(
                options: ["splunk-url": "https://collector:8088"],
                info: info,
                semanticService: semanticService
            )
        }
        for url in [
            "ftp://collector:8088",
            "https://collector:8088/path",
            "https://user@collector:8088",
            "https://collector:8088?query=yes",
        ] {
            #expect(throws: SplunkProviderError.malformedURL(url)) {
                try SplunkDriverConfiguration.resolve(
                    options: [
                        "splunk-url": url,
                        "splunk-token": "token",
                    ],
                    info: info,
                    semanticService: semanticService
                )
            }
        }
        #expect(
            throws: SplunkProviderError.invalidBoolean(
                option: "splunk-gzip",
                value: "yes"
            )
        ) {
            try SplunkDriverConfiguration.resolve(
                options: validOptions.merging(["splunk-gzip": "yes"]) {
                    _, replacement in replacement
                },
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SplunkProviderError.invalidGzipLevel("10")) {
            try SplunkDriverConfiguration.resolve(
                options: validOptions.merging([
                    "splunk-gzip-level": "10"
                ]) { _, replacement in replacement },
                info: info,
                semanticService: semanticService
            )
        }
        #expect(throws: SplunkProviderError.invalidFormat("JSON")) {
            try SplunkDriverConfiguration.resolve(
                options: validOptions.merging(["splunk-format": "JSON"]) {
                    _, replacement in replacement
                },
                info: info,
                semanticService: semanticService
            )
        }
    }

    private let validOptions = [
        "splunk-url": "https://collector:8088",
        "splunk-token": "token",
    ]

    private func helper(_ name: String) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClient(
            generation: DockerSemanticHelperGeneration(
                providerID: "tests.splunk.\(name)",
                providerGeneration: 1
            ),
            launchConfiguration: .discover()
        )
    }
}

private func splunkInfo(
    environment: [String] = [],
    labels: [String: String] = [:]
) -> SplunkContainerInfo {
    SplunkContainerInfo(
        containerID: "0123456789abcdef0123456789abcdef",
        containerName: "/web",
        containerEntrypoint: "/bin/server",
        containerArguments: ["--listen", ":8080"],
        containerImageID: "sha256:image",
        containerImageName: "example/web:latest",
        containerEnvironment: environment,
        containerLabels: labels,
        hostname: "host"
    )
}
