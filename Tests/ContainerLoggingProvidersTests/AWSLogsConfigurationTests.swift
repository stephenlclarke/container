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

struct AWSLogsConfigurationTests {
    @Test func resolvesMobyDefaultsRegionPrecedenceAndDescriptor() throws {
        let helper = try semanticHelper("defaults")
        let info = containerInfo()
        let configuration = try AWSLogsDriverConfiguration.resolve(
            options: ["awslogs-group": "application"],
            info: info,
            semanticService: helper,
            environment: ["AWS_REGION": "eu-west-1"]
        )
        #expect(configuration.region == "eu-west-1")
        #expect(configuration.logGroup == "application")
        #expect(configuration.logStream == info.containerID)
        #expect(!configuration.createGroup)
        #expect(configuration.createStream)
        #expect(configuration.policy.forceFlushInterval == .seconds(5))
        #expect(configuration.policy.maximumBufferedEvents == 4_096)

        let overridden = try AWSLogsDriverConfiguration.resolve(
            options: [
                "awslogs-group": "application",
                "awslogs-region": "us-east-2",
                "awslogs-stream": "explicit",
                "awslogs-create-group": "true",
                "awslogs-create-stream": "false",
                "awslogs-force-flush-interval-seconds": "9",
                "awslogs-max-buffered-events": "99",
                "mode": "non-blocking",
            ],
            info: info,
            semanticService: helper,
            environment: ["AWS_REGION": "eu-west-1"]
        )
        #expect(overridden.region == "us-east-2")
        #expect(overridden.logStream == "explicit")
        #expect(overridden.createGroup)
        #expect(!overridden.createStream)
        #expect(overridden.nonBlocking)
        #expect(overridden.policy.forceFlushInterval == .seconds(9))
        #expect(overridden.policy.maximumBufferedEvents == 99)

        let descriptor = AWSLogsLogDriverContract.descriptor(
            providerGeneration: 7
        )
        #expect(descriptor.providerGeneration == 7)
        #expect(descriptor.driver == "awslogs")
        #expect(descriptor.capabilities.supportsDualCache)
        #expect(
            Set(descriptor.options.map(\.name))
                == AWSLogsDriverConfiguration.knownOptionNames
        )
    }

    @Test func validatesPresenceSensitiveMultilineAndJSONEMF() throws {
        let helper = try semanticHelper("multiline")
        let info = containerInfo()
        #expect(throws: AWSLogsProviderError.conflictingMultilineOptions) {
            try AWSLogsDriverConfiguration.resolve(
                options: [
                    "awslogs-group": "group",
                    "awslogs-datetime-format": "",
                    "awslogs-multiline-pattern": "",
                ],
                info: info,
                semanticService: helper
            )
        }
        #expect(throws: AWSLogsProviderError.logFormatConflictsWithMultiline) {
            try AWSLogsDriverConfiguration.resolve(
                options: [
                    "awslogs-group": "group",
                    "awslogs-format": "json/emf",
                    "awslogs-multiline-pattern": "",
                ],
                info: info,
                semanticService: helper
            )
        }
        #expect(throws: AWSLogsProviderError.invalidLogFormat("json")) {
            try AWSLogsDriverConfiguration.resolve(
                options: [
                    "awslogs-group": "group",
                    "awslogs-format": "json",
                ],
                info: info,
                semanticService: helper
            )
        }
        let datetime = try AWSLogsDriverConfiguration.resolve(
            options: [
                "awslogs-group": "group",
                "awslogs-datetime-format": "%Y-%m-%d %H:%M:%S%L",
            ],
            info: info,
            semanticService: helper
        )
        let pattern = try #require(datetime.multilinePattern)
        #expect(
            try helper.matchRegularExpression(
                pattern: Data(pattern.utf8),
                candidates: [Data("2026-08-03 12:31:42.123 message".utf8)],
                timeout: .seconds(2)
            ) == [true]
        )
    }

    @Test func rejectsRequiredUnknownTypedAndInvalidRE2Values() throws {
        let helper = try semanticHelper("invalid")
        let info = containerInfo()
        #expect(throws: AWSLogsProviderError.missingLogGroup) {
            try AWSLogsDriverConfiguration.resolve(
                options: [:],
                info: info,
                semanticService: helper
            )
        }
        #expect(throws: AWSLogsProviderError.unknownOption("future")) {
            try AWSLogsDriverConfiguration.resolve(
                options: ["awslogs-group": "g", "future": "x"],
                info: info,
                semanticService: helper
            )
        }
        #expect(
            throws: AWSLogsProviderError.invalidPositiveInteger(
                option: "awslogs-max-buffered-events",
                value: "0"
            )
        ) {
            try AWSLogsDriverConfiguration.resolve(
                options: [
                    "awslogs-group": "g",
                    "awslogs-max-buffered-events": "0",
                ],
                info: info,
                semanticService: helper
            )
        }
        #expect(
            throws: AWSLogsProviderError.invalidMultilinePattern("n{1001}")
        ) {
            try AWSLogsDriverConfiguration.resolve(
                options: [
                    "awslogs-group": "g",
                    "awslogs-multiline-pattern": "n{1001}",
                ],
                info: info,
                semanticService: helper
            )
        }
    }

    private func semanticHelper(
        _ name: String
    ) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClient(
            generation: DockerSemanticHelperGeneration(
                providerID: "tests.awslogs.\(name)",
                providerGeneration: 1
            ),
            launchConfiguration: .discover()
        )
    }

    private func containerInfo() -> AWSLogsContainerInfo {
        AWSLogsContainerInfo(
            containerID: "0123456789abcdef0123456789abcdef",
            containerName: "/web",
            containerEntrypoint: "/bin/server",
            containerArguments: ["--listen", ":8080"],
            containerImageID: "sha256:image",
            containerImageName: "example/web:latest",
            hostname: "host"
        )
    }
}
