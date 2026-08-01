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

struct ContainerLogStartValidatorTests {
    @Test func rejectsLegacyConfigurationAtTheV2Fence() throws {
        #expect(throws: ContainerLogStartValidationError.legacyConfiguration) {
            try ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current).validate(
                .default,
                authenticatedProtectedOptions: [:]
            )
        }
    }

    @Test func acceptsAValidFrozenBuiltinContract() throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: BuiltinLogDriverDescriptors.current
        )
        let prepared = try resolver.prepare(
            ContainerLogRequest(
                driver: "json-file",
                options: [
                    "compress": "true",
                    "env-regex": "^APP_",
                    "labels-regex": "^com[.]example[.]",
                    "max-buffer-size": "1m",
                    "max-file": "3",
                    "max-size": "10m",
                    "mode": "non-blocking",
                    "tag": "{{.Name}}",
                ]
            )
        )
        let configuration = try prepared.finalizedConfiguration(protectedReference: nil)

        try ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current).validate(
            configuration,
            authenticatedProtectedOptions: [:]
        )
    }

    @Test func validatesEveryDeferredValueWithTheCreatePhaseGrammar() throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: BuiltinLogDriverDescriptors.current
        )
        let validator = ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current)
        let cases: [(name: String, value: String, reason: String)] = [
            ("compress", "not-a-boolean", "expected a boolean"),
            ("env-regex", "(", "expected a regular expression"),
            ("labels-regex", "[", "expected a regular expression"),
            ("max-file", "zero", "expected a positive integer"),
            ("max-size", "0", "expected a valid byte size"),
        ]

        for item in cases {
            let prepared = try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: [item.name: item.value]
                )
            )
            let configuration = try prepared.finalizedConfiguration(protectedReference: nil)
            #expect(
                throws: ContainerLogResolutionError.invalidOption(
                    driver: "json-file",
                    name: item.name,
                    reason: item.reason
                )
            ) {
                try validator.validate(configuration, authenticatedProtectedOptions: [:])
            }
        }
    }

    @Test func requiresExactAuthenticatedNamesAndValidatesProtectedStartValues() throws {
        let descriptor = try secretStartDescriptor()
        let catalog = try LogDriverCatalog(descriptors: [descriptor])
        let secretValue = "do-not-disclose-("
        let configuration = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            protectedOptions: ["secret-regex": secretValue]
        )
        let validator = ContainerLogStartValidator(catalog: catalog)

        #expect(
            throws: ContainerLogStartValidationError.protectedOptionNamesMismatch(
                expected: ["secret-regex"],
                actual: []
            )
        ) {
            try validator.validate(configuration, authenticatedProtectedOptions: [:])
        }
        #expect(
            throws: ContainerLogStartValidationError.protectedOptionNamesMismatch(
                expected: ["secret-regex"],
                actual: ["extra", "secret-regex"]
            )
        ) {
            try validator.validate(
                configuration,
                authenticatedProtectedOptions: [
                    "extra": "value",
                    "secret-regex": secretValue,
                ]
            )
        }

        do {
            try validator.validate(
                configuration,
                authenticatedProtectedOptions: ["secret-regex": secretValue]
            )
            Issue.record("invalid protected start value was accepted")
        } catch {
            #expect(
                error as? ContainerLogResolutionError
                    == .invalidOption(
                        driver: descriptor.driver,
                        name: "secret-regex",
                        reason: "expected a regular expression"
                    )
            )
            #expect(!String(describing: error).contains(secretValue))
        }

        let validConfiguration = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            protectedOptions: ["secret-regex": "^valid$"]
        )
        try validator.validate(
            validConfiguration,
            authenticatedProtectedOptions: ["secret-regex": "^valid$"]
        )
    }

    @Test func fencesCanonicalDriverAndProviderLease() throws {
        let descriptor = BuiltinLogDriverDescriptors.jsonFile
        let validator = ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current)

        let removed = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            resolvedDriver: "removed-driver"
        )
        #expect(throws: ContainerLogStartValidationError.unknownDriver("removed-driver")) {
            try validator.validate(removed, authenticatedProtectedOptions: [:])
        }

        let requestedMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: "local"
        )
        #expect(
            throws: ContainerLogStartValidationError.requestedDriverMismatch(
                requested: "local",
                resolved: "json-file"
            )
        ) {
            try validator.validate(requestedMismatch, authenticatedProtectedOptions: [:])
        }

        let aliasDescriptor = try copyDescriptor(descriptor, aliases: ["json-alias"])
        let aliasCatalog = try LogDriverCatalog(descriptors: [aliasDescriptor])
        let nonCanonical = try makeConfiguration(
            descriptor: aliasDescriptor,
            requestedDriver: "json-alias",
            resolvedDriver: "json-alias"
        )
        #expect(
            throws: ContainerLogStartValidationError.nonCanonicalDriver(
                resolved: "json-alias",
                canonical: "json-file"
            )
        ) {
            try ContainerLogStartValidator(catalog: aliasCatalog).validate(
                nonCanonical,
                authenticatedProtectedOptions: [:]
            )
        }

        let otherProvider = LogDriverProviderIdentity(
            id: "example.other",
            version: "1",
            kind: .native
        )
        let identityMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            providerIdentity: otherProvider
        )
        #expect(
            throws: ContainerLogStartValidationError.providerIdentityMismatch(
                expected: descriptor.providerIdentity,
                actual: otherProvider
            )
        ) {
            try validator.validate(identityMismatch, authenticatedProtectedOptions: [:])
        }

        let generationMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            providerGeneration: descriptor.providerGeneration + 1
        )
        #expect(
            throws: ContainerLogStartValidationError.providerGenerationMismatch(
                expected: descriptor.providerGeneration,
                actual: descriptor.providerGeneration + 1
            )
        ) {
            try validator.validate(generationMismatch, authenticatedProtectedOptions: [:])
        }

        let digestMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            contractDigest: "sha256:not-the-loaded-contract"
        )
        #expect(
            throws: ContainerLogStartValidationError.contractDigestMismatch(
                expected: descriptor.optionContractDigest,
                actual: "sha256:not-the-loaded-contract"
            )
        ) {
            try validator.validate(digestMismatch, authenticatedProtectedOptions: [:])
        }

        let invalidLease = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            leaseGeneration: 0
        )
        #expect(throws: ContainerLogStartValidationError.invalidLeaseGeneration) {
            try validator.validate(invalidLease, authenticatedProtectedOptions: [:])
        }
    }

    @Test func fencesCapabilitiesDeliveryReadPolicyAndCrossOptionConstraints() throws {
        let descriptor = BuiltinLogDriverDescriptors.jsonFile
        let validator = ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current)

        let deliveryMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            safeOptions: [
                "max-buffer-size": "1m",
                "mode": "non-blocking",
            ],
            delivery: LogDeliveryConfiguration()
        )
        #expect(
            throws: ContainerLogStartValidationError.deliveryConfigurationMismatch(driver: descriptor.driver)
        ) {
            try validator.validate(deliveryMismatch, authenticatedProtectedOptions: [:])
        }

        let readMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            readPolicy: LogReadPolicy(source: .unavailable)
        )
        #expect(
            throws: ContainerLogStartValidationError.readPolicyMismatch(driver: descriptor.driver)
        ) {
            try validator.validate(readMismatch, authenticatedProtectedOptions: [:])
        }

        let crossOptionMismatch = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            safeOptions: [
                "max-buffer-size": "1m",
                "mode": "blocking",
            ],
            delivery: LogDeliveryConfiguration()
        )
        #expect(
            throws: ContainerLogResolutionError.invalidOption(
                driver: descriptor.driver,
                name: "max-buffer-size",
                reason: "requires \"mode\" to use an allowed value"
            )
        ) {
            try validator.validate(crossOptionMismatch, authenticatedProtectedOptions: [:])
        }

        let nonBlockingOnly = try nonBlockingOnlyDescriptor()
        let capabilitiesConfiguration = try makeConfiguration(
            descriptor: nonBlockingOnly,
            requestedDriver: nonBlockingOnly.driver
        )
        #expect(
            throws: ContainerLogStartValidationError.capabilitiesMismatch(
                driver: nonBlockingOnly.driver,
                reason: "resolved delivery mode is not supported"
            )
        ) {
            try ContainerLogStartValidator(
                catalog: LogDriverCatalog(descriptors: [nonBlockingOnly])
            ).validate(capabilitiesConfiguration, authenticatedProtectedOptions: [:])
        }

        let changedCapabilities = try LogDriverCapabilities(
            deliveryModes: descriptor.capabilities.deliveryModes,
            nativeRead: descriptor.capabilities.nativeRead,
            readFilters: descriptor.capabilities.readFilters.filter { $0 != .details },
            supportsDualCache: descriptor.capabilities.supportsDualCache,
            supportsDockerPluginProtocol: descriptor.capabilities.supportsDockerPluginProtocol,
            requiresDeliverySession: descriptor.capabilities.requiresDeliverySession,
            logPathVisibility: descriptor.capabilities.logPathVisibility,
            fileDefaults: descriptor.capabilities.fileDefaults
        )
        let changedDescriptor = try copyDescriptor(descriptor, capabilities: changedCapabilities)
        let originalConfiguration = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver
        )
        #expect(
            throws: ContainerLogStartValidationError.contractDigestMismatch(
                expected: changedDescriptor.optionContractDigest,
                actual: descriptor.optionContractDigest
            )
        ) {
            try ContainerLogStartValidator(
                catalog: LogDriverCatalog(descriptors: [changedDescriptor])
            ).validate(originalConfiguration, authenticatedProtectedOptions: [:])
        }
    }

    @Test func rejectsPersistedSafeAndProtectedClassificationChanges() throws {
        let descriptor = try secretStartDescriptor()
        let catalog = try LogDriverCatalog(descriptors: [descriptor])
        let validator = ContainerLogStartValidator(catalog: catalog)

        let secretPersistedAsSafe = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            safeOptions: ["secret-regex": "valid"]
        )
        #expect(
            throws: ContainerLogStartValidationError.safeOptionClassificationMismatch(
                driver: descriptor.driver,
                name: "secret-regex"
            )
        ) {
            try validator.validate(secretPersistedAsSafe, authenticatedProtectedOptions: [:])
        }

        let safePersistedAsProtected = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            protectedOptions: ["endpoint": "value"]
        )
        #expect(
            throws: ContainerLogStartValidationError.protectedOptionClassificationMismatch(
                driver: descriptor.driver,
                name: "endpoint"
            )
        ) {
            try validator.validate(
                safePersistedAsProtected,
                authenticatedProtectedOptions: ["endpoint": "value"]
            )
        }
    }

    @Test func appliesDockerFileCompressionConstraintsAtStart() throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: BuiltinLogDriverDescriptors.current
        )
        let validator = ContainerLogStartValidator(catalog: BuiltinLogDriverDescriptors.current)

        for options in [
            ["compress": "true"],
            ["compress": "true", "max-file": "2"],
            ["compress": "true", "max-size": "1m"],
        ] {
            let prepared = try resolver.prepare(
                ContainerLogRequest(driver: "json-file", options: options)
            )
            let configuration = try prepared.finalizedConfiguration(protectedReference: nil)
            #expect(
                throws: ContainerLogResolutionError.invalidOption(
                    driver: "json-file",
                    name: "compress",
                    reason: "compress cannot be true when max-file is less than 2 or max-size is not set"
                )
            ) {
                try validator.validate(configuration, authenticatedProtectedOptions: [:])
            }
        }

        let validJSON = try resolver.prepare(
            ContainerLogRequest(
                driver: "json-file",
                options: [
                    "compress": "true",
                    "max-file": "2",
                    "max-size": "1m",
                ]
            )
        )
        try validator.validate(
            validJSON.finalizedConfiguration(protectedReference: nil),
            authenticatedProtectedOptions: [:]
        )

        let localWithOneFile = try resolver.prepare(
            ContainerLogRequest(driver: "local", options: ["max-file": "1"])
        )
        #expect(
            throws: ContainerLogResolutionError.invalidOption(
                driver: "local",
                name: "compress",
                reason: "compress cannot be true when max-file is less than 2 or max-size is not set"
            )
        ) {
            try validator.validate(
                localWithOneFile.finalizedConfiguration(protectedReference: nil),
                authenticatedProtectedOptions: [:]
            )
        }

        let localUncompressed = try resolver.prepare(
            ContainerLogRequest(
                driver: "local",
                options: [
                    "compress": "false",
                    "max-file": "1",
                ]
            )
        )
        try validator.validate(
            localUncompressed.finalizedConfiguration(protectedReference: nil),
            authenticatedProtectedOptions: [:]
        )
    }

    @Test func revalidatesCreatePhaseScalarsAgainstPersistedSubstitution() throws {
        let descriptor = try LogDriverDescriptor(
            driver: "create-scalar",
            providerIdentity: LogDriverProviderIdentity(
                id: "example.create-scalar",
                version: "1",
                kind: .native
            ),
            providerGeneration: 1,
            placement: .macOSHost,
            trust: .signed,
            options: [
                LogDriverOptionDescriptor(name: "enabled", valueKind: .boolean)
            ],
            capabilities: LogDriverCapabilities(
                deliveryModes: [],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: false,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: false,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
        let configuration = try makeConfiguration(
            descriptor: descriptor,
            requestedDriver: descriptor.driver,
            safeOptions: ["enabled": "substituted-invalid-value"]
        )

        #expect(
            throws: ContainerLogResolutionError.invalidOption(
                driver: descriptor.driver,
                name: "enabled",
                reason: "expected a boolean"
            )
        ) {
            try ContainerLogStartValidator(
                catalog: LogDriverCatalog(descriptors: [descriptor])
            ).validate(configuration, authenticatedProtectedOptions: [:])
        }
    }

    private func makeConfiguration(
        descriptor: LogDriverDescriptor,
        requestedDriver: String?,
        resolvedDriver: String? = nil,
        safeOptions: [String: String] = [:],
        protectedOptions: [String: String] = [:],
        delivery: LogDeliveryConfiguration? = nil,
        readPolicy: LogReadPolicy? = nil,
        providerIdentity: LogDriverProviderIdentity? = nil,
        providerGeneration: UInt64? = nil,
        contractDigest: String? = nil,
        leaseGeneration: UInt64 = 1
    ) throws -> ContainerLogConfiguration {
        var allOptions = safeOptions
        allOptions.merge(protectedOptions) { _, protected in protected }
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: leaseGeneration,
            driver: resolvedDriver ?? descriptor.driver,
            safeOptions: safeOptions,
            protectedOptionNames: protectedOptions.keys.sorted(),
            protectedOptionReference: protectedOptions.isEmpty ? nil : protectedReference,
            delivery: try delivery
                ?? ContainerLogRequestResolver.deliveryConfiguration(
                    options: allOptions,
                    descriptor: descriptor
                ),
            readPolicy: try readPolicy
                ?? ContainerLogRequestResolver.readPolicy(
                    options: allOptions,
                    descriptor: descriptor
                ),
            providerIdentity: providerIdentity ?? descriptor.providerIdentity,
            providerGenerationAtResolution: providerGeneration ?? descriptor.providerGeneration,
            contractDigest: contractDigest ?? descriptor.optionContractDigest
        )
        return try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: requestedDriver, options: allOptions),
            resolved: resolved
        )
    }

    private var protectedReference: LoggingProtectedOptionsReference {
        LoggingProtectedOptionsReference(
            objectID: "authenticated-object",
            integrityDigest: "hmac-sha256:authenticated"
        )
    }

    private func secretStartDescriptor() throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: "secret-start",
            providerIdentity: LogDriverProviderIdentity(
                id: "example.secret-start",
                version: "1",
                kind: .native
            ),
            providerGeneration: 7,
            placement: .macOSHost,
            trust: .signed,
            options: [
                LogDriverOptionDescriptor(name: "endpoint", valueKind: .string),
                LogDriverOptionDescriptor(
                    name: "secret-regex",
                    valueKind: .regularExpression,
                    validationPhase: .start,
                    isSecret: true
                ),
            ],
            capabilities: LogDriverCapabilities(
                deliveryModes: [],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: false,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: false,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    private func nonBlockingOnlyDescriptor() throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: "nonblocking-only",
            providerIdentity: LogDriverProviderIdentity(
                id: "example.nonblocking-only",
                version: "1",
                kind: .native
            ),
            providerGeneration: 1,
            placement: .macOSHost,
            trust: .signed,
            options: [
                LogDriverOptionDescriptor(
                    name: "mode",
                    valueKind: .string,
                    allowedValues: ["non-blocking"]
                )
            ],
            capabilities: LogDriverCapabilities(
                deliveryModes: [.nonBlocking],
                nativeRead: false,
                readFilters: [],
                supportsDualCache: false,
                supportsDockerPluginProtocol: false,
                requiresDeliverySession: true,
                logPathVisibility: .none,
                fileDefaults: nil
            )
        )
    }

    private func copyDescriptor(
        _ descriptor: LogDriverDescriptor,
        aliases: [String]? = nil,
        capabilities: LogDriverCapabilities? = nil
    ) throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: descriptor.driver,
            aliases: aliases ?? descriptor.aliases,
            providerIdentity: descriptor.providerIdentity,
            providerGeneration: descriptor.providerGeneration,
            placement: descriptor.placement,
            trust: descriptor.trust,
            options: descriptor.options,
            crossOptionConstraints: descriptor.crossOptionConstraints,
            acceptsUnknownOptions: descriptor.acceptsUnknownOptions,
            capabilities: capabilities ?? descriptor.capabilities
        )
    }
}
