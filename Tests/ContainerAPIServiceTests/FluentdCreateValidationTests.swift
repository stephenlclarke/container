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

import ContainerPersistence
import ContainerResource
import Testing

@testable import ContainerAPIService

struct FluentdCreateValidationTests {
    @Test func acceptsPinnedDockerCreateGrammarAndCachePassThrough() throws {
        let options = [
            "cache-compress": "perhaps",
            "cache-max-file": "0",
            "cache-max-size": "0",
            "env-regex": "(",
            "fluentd-address": "TLS://collector:0?ignored=yes",
            "fluentd-async": "",
            "fluentd-async-reconnect-interval": "100ms",
            "fluentd-buffer-limit": "0",
            "fluentd-max-retries": "0",
            "fluentd-read-timeout": "0",
            "fluentd-request-ack": "TRUE",
            "fluentd-retry-wait": "-1s",
            "fluentd-sub-second-precision": "false",
            "fluentd-write-timeout": "1.5s",
            "labels-regex": "(?i-)invalid-at-provider-start",
            "tag": "{{.UnsupportedField}}",
        ]
        let resolver = try makeFluentdResolver()

        let prepared = try resolver.prepare(
            ContainerLogRequest(driver: "fluentd", options: options)
        )

        #expect(prepared.safeOptions == options)
        let configuration = try prepared.finalizedConfiguration(protectedReference: nil)
        try ContainerLogStartValidator(catalog: resolver.catalog).validate(
            configuration,
            authenticatedProtectedOptions: [:]
        )
    }

    @Test func rejectsMalformedDockerScalarOptionsAtCreate() throws {
        let cases: [(String, String)] = [
            ("fluentd-async", "yes"),
            ("fluentd-async-reconnect-interval", "99ms"),
            ("fluentd-async-reconnect-interval", "11s"),
            ("fluentd-buffer-limit", "-1"),
            ("fluentd-buffer-limit", "nonsense"),
            ("fluentd-max-retries", "+1"),
            ("fluentd-max-retries", "2147483648"),
            ("fluentd-read-timeout", "-1ns"),
            ("fluentd-request-ack", "yes"),
            ("fluentd-retry-wait", "1"),
            ("fluentd-sub-second-precision", "yes"),
            ("fluentd-write-timeout", "-1s"),
        ]

        for (name, value) in cases {
            #expect(throws: ContainerLogResolutionError.self) {
                try makeFluentdResolver().prepare(
                    ContainerLogRequest(
                        driver: "fluentd",
                        options: [name: value]
                    )
                )
            }
        }
    }

    @Test func enforcesDockerAddressSchemesPathsAndPortBoundsAtCreate() throws {
        let resolver = try makeFluentdResolver()
        for address in [
            "collector:24224",
            "tcp://collector:",
            "tcp://collector:0",
            "tls://[::1]:65535",
            "unix:///var/run/fluent.sock",
        ] {
            _ = try resolver.prepare(
                ContainerLogRequest(
                    driver: "fluentd",
                    options: ["fluentd-address": address]
                )
            )
        }

        for address in [
            "udp://collector:24224",
            "tcp://collector/path",
            "tcp://collector:+1",
            "tcp://collector:65536",
            "unix://",
            "unix:////",
        ] {
            #expect(throws: ContainerLogResolutionError.self) {
                try resolver.prepare(
                    ContainerLogRequest(
                        driver: "fluentd",
                        options: ["fluentd-address": address]
                    )
                )
            }
        }
    }
}

private func makeFluentdResolver() throws -> ContainerLogRequestResolver {
    let descriptor = try LogDriverDescriptor(
        driver: "fluentd",
        providerIdentity: LogDriverProviderIdentity(
            id: "com.apple.container.logging.providers.fluentd",
            version: "1",
            kind: .native
        ),
        providerGeneration: 1,
        placement: .macOSHost,
        trust: .signed,
        options: [
            LogDriverOptionDescriptor(name: "cache-compress", valueKind: .string),
            LogDriverOptionDescriptor(name: "cache-disabled", valueKind: .boolean),
            LogDriverOptionDescriptor(name: "cache-max-file", valueKind: .string),
            LogDriverOptionDescriptor(name: "cache-max-size", valueKind: .string),
            LogDriverOptionDescriptor(name: "env-regex", valueKind: .providerRegularExpression, validationPhase: .start),
            LogDriverOptionDescriptor(name: "fluentd-address", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-async", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-async-reconnect-interval", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-buffer-limit", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-max-retries", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-read-timeout", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-request-ack", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-retry-wait", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-sub-second-precision", valueKind: .string),
            LogDriverOptionDescriptor(name: "fluentd-write-timeout", valueKind: .string),
            LogDriverOptionDescriptor(name: "labels-regex", valueKind: .providerRegularExpression, validationPhase: .start),
            LogDriverOptionDescriptor(name: "tag", valueKind: .tagTemplate, validationPhase: .start),
        ],
        createValidationProfile: .dockerFluentd29_2_1,
        capabilities: LogDriverCapabilities(
            deliveryModes: [.blocking, .nonBlocking],
            nativeRead: false,
            readFilters: [],
            supportsDualCache: true,
            supportsDockerPluginProtocol: false,
            requiresDeliverySession: true,
            logPathVisibility: .none,
            fileDefaults: nil
        )
    )
    return ContainerLogRequestResolver(
        defaults: LoggingConfig(driver: "fluentd"),
        catalog: try LogDriverCatalog(descriptors: [descriptor])
    )
}
