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

struct GELFCreateValidationTests {
    @Test func realResolverRequiresAddressWithoutDisclosingOptions() throws {
        let resolver = try makeGELFResolver()

        #expect(
            throws: ContainerLogResolutionError.invalidOption(
                driver: "gelf",
                name: "gelf-address",
                reason: "is required"
            )
        ) {
            try resolver.prepare(ContainerLogRequest(driver: "gelf"))
        }
    }

    @Test func realResolverAcceptsDockerAtoiAndDefersTagAndRE2Grammar() throws {
        let options = [
            "env-regex": #"(?U)^\QAPP_\E\141+\b$"#,
            "gelf-address": "UDP://collector:12201",
            "gelf-compression-level": "+1",
            "labels-regex": #"("#,
            "tag": "{{.UnsupportedField}}",
        ]
        let resolver = try makeGELFResolver()

        let prepared = try resolver.prepare(
            ContainerLogRequest(driver: "gelf", options: options)
        )

        #expect(prepared.safeOptions == options)
        let configuration = try prepared.finalizedConfiguration(protectedReference: nil)
        try ContainerLogStartValidator(catalog: resolver.catalog).validate(
            configuration,
            authenticatedProtectedOptions: [:]
        )
    }

    @Test func realResolverEnforcesSchemeSpecificCompressionAndTCPOptions() throws {
        let cases: [(address: String, name: String, value: String, reason: String)] = [
            ("tcp://collector:12201", "gelf-compression-level", "1", "compression is only supported on UDP"),
            ("tcp://collector:12201", "gelf-compression-type", "gzip", "compression is only supported on UDP"),
            ("udp://collector:12201", "gelf-tcp-max-reconnect", "1", "is only valid for TCP"),
            ("udp://collector:12201", "gelf-tcp-reconnect-delay", "1", "is only valid for TCP"),
        ]

        for item in cases {
            #expect(
                throws: ContainerLogResolutionError.invalidOption(
                    driver: "gelf",
                    name: item.name,
                    reason: item.reason
                )
            ) {
                try makeGELFResolver().prepare(
                    ContainerLogRequest(
                        driver: "gelf",
                        options: [
                            "gelf-address": item.address,
                            item.name: item.value,
                        ]
                    )
                )
            }
        }
    }

    @Test func realResolverRejectsNonDecimalPortGrammarsAtCreate() throws {
        for address in [
            "udp://collector:syslog",
            "udp://collector:+12201",
            "udp://collector:-1",
            "udp://collector:%31%32%32%30%31",
        ] {
            do {
                _ = try makeGELFResolver().prepare(
                    ContainerLogRequest(
                        driver: "gelf",
                        options: ["gelf-address": address]
                    )
                )
                Issue.record("non-decimal GELF port was accepted")
            } catch {
                #expect(
                    error as? ContainerLogResolutionError
                        == .invalidOption(
                            driver: "gelf",
                            name: "gelf-address",
                            reason: "expected proto://host:port with a decimal port"
                        )
                )
                #expect(!String(describing: error).contains(address))
            }
        }
    }

    @Test func realResolverPreservesMobyCreateBoundaryForDecimalPorts() throws {
        let resolver = try makeGELFResolver()
        for address in ["udp://collector:", "udp://collector:0", "udp://collector:99999"] {
            let prepared = try resolver.prepare(
                ContainerLogRequest(
                    driver: "gelf",
                    options: ["gelf-address": address]
                )
            )
            #expect(prepared.safeOptions["gelf-address"] == address)
        }
    }

    @Test func realResolverUsesDockerIntegerSpellingsAndBounds() throws {
        let resolver = try makeGELFResolver()
        for value in ["0", "+0", "+7"] {
            _ = try resolver.prepare(
                ContainerLogRequest(
                    driver: "gelf",
                    options: [
                        "gelf-address": "tcp://collector:12201",
                        "gelf-tcp-max-reconnect": value,
                        "gelf-tcp-reconnect-delay": value,
                    ]
                )
            )
        }
        for value in ["-1", " 1", "1 ", "", "one"] {
            #expect(throws: ContainerLogResolutionError.self) {
                try resolver.prepare(
                    ContainerLogRequest(
                        driver: "gelf",
                        options: [
                            "gelf-address": "tcp://collector:12201",
                            "gelf-tcp-max-reconnect": value,
                        ]
                    )
                )
            }
        }
    }

    @Test func realResolverPreservesPinnedLocalCachePassThroughGrammar() throws {
        let resolver = try makeGELFResolver()
        let options = [
            "cache-compress": "perhaps",
            "cache-max-file": "0",
            "cache-max-size": "0",
            "gelf-address": "udp://collector:12201",
        ]

        let prepared = try resolver.prepare(
            ContainerLogRequest(driver: "gelf", options: options)
        )
        #expect(prepared.safeOptions == options)

        #expect(throws: ContainerLogResolutionError.self) {
            try resolver.prepare(
                ContainerLogRequest(
                    driver: "gelf",
                    options: [
                        "cache-disabled": "perhaps",
                        "gelf-address": "udp://collector:12201",
                    ]
                )
            )
        }
    }
}

private func makeGELFResolver() throws -> ContainerLogRequestResolver {
    let descriptor = try LogDriverDescriptor(
        driver: "gelf",
        providerIdentity: LogDriverProviderIdentity(
            id: "com.apple.container.logging.providers.gelf",
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
            LogDriverOptionDescriptor(name: "gelf-address", valueKind: .string),
            LogDriverOptionDescriptor(name: "gelf-compression-level", valueKind: .string),
            LogDriverOptionDescriptor(
                name: "gelf-compression-type",
                valueKind: .string,
                allowedValues: ["gzip", "none", "zlib"]
            ),
            LogDriverOptionDescriptor(name: "gelf-tcp-max-reconnect", valueKind: .string),
            LogDriverOptionDescriptor(name: "gelf-tcp-reconnect-delay", valueKind: .string),
            LogDriverOptionDescriptor(name: "labels-regex", valueKind: .providerRegularExpression, validationPhase: .start),
            LogDriverOptionDescriptor(name: "tag", valueKind: .tagTemplate, validationPhase: .start),
        ],
        createValidationProfile: .dockerGELF29_2_1,
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
        defaults: LoggingConfig(driver: "gelf"),
        catalog: try LogDriverCatalog(descriptors: [descriptor])
    )
}
