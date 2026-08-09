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

import CryptoKit
import Foundation
import Testing

@testable import ContainerResource

struct ContainerLogContractTests {
    @Test(arguments: [nil, "", "json-file", "local", "acme.example/remote"] as [String?])
    func requestedConfigurationIsLossless(driver: String?) throws {
        let request = ContainerLogRequest(
            driver: driver,
            options: ["empty": "", "endpoint": "tcp://host:1234?a=b", "opaque": "01"]
        )

        let decoded = try JSONDecoder().decode(
            ContainerLogRequest.self,
            from: JSONEncoder().encode(request)
        )

        #expect(decoded == request)
        #expect(decoded.driver == driver)
        #expect(decoded.options["empty"] == "")
    }

    @Test func requestRejectsUnknownSchemaVersion() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "options": [:],
        ])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContainerLogRequest.self, from: data)
        }
    }

    @Test func everyVersionedContractRejectsAnUnknownOuterSchema() throws {
        try Self.expectUnknownSchemaRejected(ContainerLogRequest())
        try Self.expectUnknownSchemaRejected(
            PersistedContainerLogRequest(driver: nil)
        )
        try Self.expectUnknownSchemaRejected(
            LoggingProtectedOptionsReference(objectID: "object", integrityDigest: "hmac:value")
        )
        try Self.expectUnknownSchemaRejected(BuiltinLogDriverDescriptors.coreProvider)
        try Self.expectUnknownSchemaRejected(try LogDeliveryConfiguration())
        try Self.expectUnknownSchemaRejected(
            try LogCacheConfiguration(maxSizeInBytes: 1, maxFileCount: 1, compress: false)
        )
        try Self.expectUnknownSchemaRejected(LogReadPolicy(source: .direct))
        let resolved = try Self.makeResolved()
        try Self.expectUnknownSchemaRejected(resolved)
        try Self.expectUnknownSchemaRejected(
            try ContainerLogConfiguration(requested: ContainerLogRequest(), resolved: resolved)
        )
        try Self.expectUnknownSchemaRejected(BuiltinLogDriverDescriptors.jsonFile.capabilities)
        try Self.expectUnknownSchemaRejected(BuiltinLogDriverDescriptors.jsonFile)
        try Self.expectUnknownSchemaRejected(BuiltinLogDriverDescriptors.current)
    }

    @Test func deliveryPreservesOmittedAndExplicitBlocking() throws {
        let omitted = try LogDeliveryConfiguration()
        let explicit = try LogDeliveryConfiguration(requestedMode: .blocking)
        let defaultNonBlocking = try LogDeliveryConfiguration(requestedMode: .nonBlocking)
        let zeroNonBlocking = try LogDeliveryConfiguration(
            requestedMode: .nonBlocking,
            maxBufferSizeInBytes: 0
        )

        #expect(omitted.effectiveMode == .blocking)
        #expect(omitted.requestedMode == nil)
        #expect(explicit.effectiveMode == .blocking)
        #expect(explicit.requestedMode == .blocking)
        #expect(omitted != explicit)
        #expect(defaultNonBlocking.maxBufferSizeInBytes == nil)
        #expect(
            defaultNonBlocking.effectiveMaxBufferSizeInBytes
                == LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes
        )
        #expect(zeroNonBlocking.maxBufferSizeInBytes == 0)
        #expect(zeroNonBlocking.effectiveMaxBufferSizeInBytes == 0)

        for value in [omitted, explicit, defaultNonBlocking, zeroNonBlocking] {
            #expect(
                try JSONDecoder().decode(
                    LogDeliveryConfiguration.self,
                    from: JSONEncoder().encode(value)
                ) == value
            )
        }

        #expect(throws: LogDriverContractError.invalidDeliveryMode) {
            try LogDeliveryConfiguration(maxBufferSizeInBytes: 1)
        }
        #expect(throws: LogDriverContractError.invalidDeliveryMode) {
            try LogDeliveryConfiguration(requestedMode: .blocking, maxBufferSizeInBytes: 1)
        }

        var encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultNonBlocking)) as? [String: Any]
        )
        encoded["effectiveMaxBufferSizeInBytes"] = 999_999
        #expect(throws: LogDriverContractError.invalidDeliveryMode) {
            try JSONDecoder().decode(
                LogDeliveryConfiguration.self,
                from: JSONSerialization.data(withJSONObject: encoded)
            )
        }
    }

    @Test func cacheRejectsZeroAndNegativeBoundariesDuringConstructionAndRestart() throws {
        #expect(throws: LogDriverContractError.invalidCacheConfiguration) {
            try LogCacheConfiguration(maxSizeInBytes: 0, maxFileCount: 1, compress: false)
        }
        #expect(throws: LogDriverContractError.invalidCacheConfiguration) {
            try LogCacheConfiguration(maxSizeInBytes: 1, maxFileCount: 0, compress: false)
        }
        #expect(throws: LogDriverContractError.invalidCacheConfiguration) {
            try LogCacheConfiguration(maxSizeInBytes: 1, maxFileCount: -1, compress: false)
        }

        let valid = try LogCacheConfiguration(maxSizeInBytes: 1, maxFileCount: 1, compress: true)
        let encoded = try JSONEncoder().encode(valid)
        #expect(try JSONDecoder().decode(LogCacheConfiguration.self, from: encoded) == valid)

        for (field, value) in [("maxSizeInBytes", 0), ("maxFileCount", 0), ("maxFileCount", -1)] {
            var object = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object[field] = value
            #expect(throws: LogDriverContractError.invalidCacheConfiguration) {
                try JSONDecoder().decode(
                    LogCacheConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: object)
                )
            }
        }
    }

    @Test func readPolicyRejectsImpossibleCacheCombinations() throws {
        #expect(throws: LogDriverContractError.invalidReadPolicy) {
            try LogReadPolicy(source: .dualCache)
        }
        #expect(throws: LogDriverContractError.invalidReadPolicy) {
            try LogReadPolicy(
                source: .direct,
                cache: try LogCacheConfiguration(maxSizeInBytes: 1, maxFileCount: 1, compress: false)
            )
        }
    }

    @Test func capabilitiesRejectInvalidFileDefaultBounds() throws {
        let base = BuiltinLogDriverDescriptors.jsonFile.capabilities
        for defaults in [
            LogDriverFileDefaults(maxSizeInBytes: 0, maxFileCount: 1, compress: false),
            LogDriverFileDefaults(maxSizeInBytes: 1, maxFileCount: 0, compress: false),
            LogDriverFileDefaults(maxSizeInBytes: nil, maxFileCount: -1, compress: false),
        ] {
            #expect(
                throws: LogDriverContractError.invalidCapabilities(
                    "file defaults require positive retention bounds"
                )
            ) {
                try LogDriverCapabilities(
                    deliveryModes: base.deliveryModes,
                    nativeRead: base.nativeRead,
                    readFilters: base.readFilters,
                    supportsDualCache: base.supportsDualCache,
                    supportsDockerPluginProtocol: base.supportsDockerPluginProtocol,
                    requiresDeliverySession: base.requiresDeliverySession,
                    logPathVisibility: base.logPathVisibility,
                    fileDefaults: defaults
                )
            }
        }
    }

    @Test func resolvedConfigurationRoundTripsAndNestedVersionsAreChecked() throws {
        let resolved = try Self.makeResolved()
        let data = try JSONEncoder().encode(resolved)
        #expect(try JSONDecoder().decode(ResolvedContainerLogConfiguration.self, from: data) == resolved)

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var provider = try #require(object["providerIdentity"] as? [String: Any])
        provider["schemaVersion"] = 99
        object["providerIdentity"] = provider
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ResolvedContainerLogConfiguration.self, from: invalid)
        }
    }

    @Test func resolvedConfigurationRejectsProtectedStateMismatch() throws {
        #expect(throws: (any Error).self) {
            try Self.makeResolved(protectedOptionNames: ["token"], protectedOptionReference: nil)
        }
        #expect(throws: (any Error).self) {
            try Self.makeResolved(
                safeOptions: ["token": "unsafe"],
                protectedOptionNames: ["token"],
                protectedOptionReference: LoggingProtectedOptionsReference(
                    objectID: "object",
                    integrityDigest: "hmac:value"
                )
            )
        }
    }

    @Test func legacyLocalAndNoneDecodeWithoutReinterpretation() throws {
        for (storage, expectedDriver) in [("local", "legacy-local-v1"), ("none", "none")] {
            let data = try JSONSerialization.data(withJSONObject: [
                "storage": storage,
                "maxSizeInBytes": 10,
                "maxFileCount": 2,
            ])
            let decoded = try JSONDecoder().decode(ContainerLogConfiguration.self, from: data)

            #expect(decoded.isLegacy)
            #expect(decoded.effectiveDriver == expectedDriver)
            let encoded = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
            )
            #expect(encoded["schemaVersion"] == nil)
            #expect(encoded["requested"] == nil)
            #expect(encoded["storage"] as? String == storage)
        }
    }

    @Test func v2PersistenceRequiresResolvedStateAndRejectsHybridShapes() throws {
        let request = ContainerLogRequest(driver: "local")
        let resolved = try Self.makeResolved(driver: "local")
        let configuration = try ContainerLogConfiguration(requested: request, resolved: resolved)
        #expect(
            try JSONDecoder().decode(
                ContainerLogConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ) == configuration
        )

        var unresolved = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        unresolved.removeValue(forKey: "resolved")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ContainerLogConfiguration.self,
                from: JSONSerialization.data(withJSONObject: unresolved)
            )
        }

        unresolved["resolved"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved))
        unresolved["storage"] = "local"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ContainerLogConfiguration.self,
                from: JSONSerialization.data(withJSONObject: unresolved)
            )
        }
    }

    @Test func v2PersistenceRejectsEveryUnclassifiedRequestedValue() throws {
        let resolved = try Self.makeResolved(safeOptions: ["tag": "resolved-value"])

        #expect(throws: LogDriverContractError.unprotectedRequestedOption("tag")) {
            try ContainerLogConfiguration(
                requested: ContainerLogRequest(
                    driver: "json-file",
                    options: ["tag": "exact-request-value"]
                ),
                resolved: resolved
            )
        }
        #expect(throws: LogDriverContractError.unprotectedRequestedOption("future-token")) {
            try ContainerLogConfiguration(
                requested: ContainerLogRequest(
                    driver: "json-file",
                    options: ["future-token": "secret"]
                ),
                resolved: resolved
            )
        }
    }

    @Test func v2PersistenceRejectsHostileCrossObjectState() throws {
        let configuration = try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: "splunk",
                options: ["tag": "{{.Name}}", "splunk-token": "secret"]
            ),
            resolved: try Self.makeResolved(
                driver: "splunk",
                safeOptions: ["tag": "{{.Name}}"],
                protectedOptionNames: ["splunk-token"],
                protectedOptionReference: LoggingProtectedOptionsReference(
                    objectID: "protected-object-id",
                    integrityDigest: "hmac:protected-reference-digest"
                )
            )
        )
        let encoded = try JSONEncoder().encode(configuration)

        var mismatchedSafeValue = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var requested = try #require(mismatchedSafeValue["requested"] as? [String: Any])
        requested["safeOptions"] = ["tag": "hostile-value"]
        mismatchedSafeValue["requested"] = requested
        #expect(
            throws: LogDriverContractError.invalidResolvedConfiguration(
                "requested safe option 'tag' does not match resolved state"
            )
        ) {
            try JSONDecoder().decode(
                ContainerLogConfiguration.self,
                from: JSONSerialization.data(withJSONObject: mismatchedSafeValue)
            )
        }

        var unboundProtectedName = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        requested = try #require(unboundProtectedName["requested"] as? [String: Any])
        requested["protectedOptionNames"] = ["splunk-token", "injected-secret"]
        unboundProtectedName["requested"] = requested
        #expect(
            throws: LogDriverContractError.invalidResolvedConfiguration(
                "requested protected option names are not contained in resolved state"
            )
        ) {
            try JSONDecoder().decode(
                ContainerLogConfiguration.self,
                from: JSONSerialization.data(withJSONObject: unboundProtectedName)
            )
        }
    }

    @Test func routineProjectionDoesNotLeakRequestSecretsOrProtectedReference() throws {
        let secret = "splunk-secret-value"
        let objectID = "protected-object-id"
        let digest = "hmac:protected-reference-digest"
        let request = ContainerLogRequest(
            driver: "splunk",
            options: ["splunk-token": secret, "tag": "{{.Name}}", "unknown": "hide-me"]
        )
        let resolved = try Self.makeResolved(
            driver: "splunk",
            safeOptions: ["tag": "{{.Name}}"],
            protectedOptionNames: ["splunk-token", "unknown"],
            protectedOptionReference: LoggingProtectedOptionsReference(
                objectID: objectID,
                integrityDigest: digest
            )
        )
        let configuration = try ContainerLogConfiguration(requested: request, resolved: resolved)

        let bytes = try JSONEncoder().encode(configuration.routineInspection)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("hide-me"))
        #expect(!text.contains(objectID))
        #expect(!text.contains(digest))
        #expect(text.contains("{{.Name}}"))
        #expect(!text.contains("<redacted>"))
        #expect(text.contains("protectedOptionNames"))
        #expect(text.contains("protectedOptionCount"))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContainerLogConfiguration.self, from: bytes)
        }

        let resolvedInspection = try JSONEncoder().encode(resolved.routineInspection)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ResolvedContainerLogConfiguration.self, from: resolvedInspection)
        }

        let legacyInspection = try JSONEncoder().encode(ContainerLogConfiguration(storage: .none).routineInspection)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContainerLogConfiguration.self, from: legacyInspection)
        }

        let rawText = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        #expect(!rawText.contains(secret))
        #expect(!rawText.contains("hide-me"))
        #expect(rawText.contains(objectID))
    }

    @Test func builtInCatalogIsDistinctValidatedAndDigestBound() throws {
        let catalog = BuiltinLogDriverDescriptors.current
        #expect(catalog.registeredNames == ["json-file", "local", "none"])
        #expect(catalog.descriptor(named: "missing") == nil)

        let none = try #require(catalog.descriptor(named: "none"))
        let json = try #require(catalog.descriptor(named: "json-file"))
        let local = try #require(catalog.descriptor(named: "local"))
        #expect(none.acceptsUnknownOptions)
        #expect(!none.capabilities.nativeRead)
        #expect(!none.capabilities.requiresDeliverySession)
        #expect(none.capabilities.logPathVisibility == .none)
        #expect(json.capabilities.logPathVisibility == .publicActiveFile)
        #expect(json.capabilities.fileDefaults == LogDriverFileDefaults(maxSizeInBytes: nil, maxFileCount: 1, compress: false))
        #expect(local.capabilities.logPathVisibility == .privateStore)
        #expect(local.capabilities.fileDefaults == LogDriverFileDefaults(maxSizeInBytes: 20 * 1024 * 1024, maxFileCount: 5, compress: true))
        #expect(json.optionContractDigest != local.optionContractDigest)
        let mode = try #require(json.options.first { $0.name == "mode" })
        #expect(mode.allowedValues == ["", "blocking", "non-blocking"])
        #expect(json.options.first { $0.name == "compress" }?.validationPhase == .start)
        #expect(json.options.first { $0.name == "max-size" }?.validationPhase == .start)
        #expect(
            json.crossOptionConstraints == [
                LogDriverCrossOptionConstraint(
                    whenOptionPresent: "max-buffer-size",
                    requiredOption: "mode",
                    requiredAllowedValues: ["non-blocking"]
                )
            ]
        )

        for descriptor in catalog.descriptors {
            let digest = SHA256.hash(data: Data(descriptor.optionContractCanonicalForm.utf8))
            let actual = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
            #expect(actual == descriptor.optionContractDigest)
        }
    }

    @Test func descriptorDigestBindsBehaviorAndRejectsStaleValues() throws {
        let base = BuiltinLogDriverDescriptors.jsonFile
        var mutations: [LogDriverDescriptor] = []
        mutations.append(try Self.copyDescriptor(base, driver: "json-file-v2"))
        mutations.append(try Self.copyDescriptor(base, aliases: ["json"]))
        mutations.append(
            try Self.copyDescriptor(
                base,
                providerIdentity: LogDriverProviderIdentity(
                    id: "com.apple.container.logging.alternate",
                    version: base.providerIdentity.version,
                    kind: base.providerIdentity.kind
                )
            )
        )
        mutations.append(
            try Self.copyDescriptor(
                base,
                providerIdentity: LogDriverProviderIdentity(
                    id: base.providerIdentity.id,
                    version: "2",
                    kind: base.providerIdentity.kind
                )
            )
        )
        mutations.append(
            try Self.copyDescriptor(
                base,
                providerIdentity: LogDriverProviderIdentity(
                    id: base.providerIdentity.id,
                    version: base.providerIdentity.version,
                    kind: .native
                )
            )
        )
        mutations.append(try Self.copyDescriptor(base, placement: .engineLinuxSandbox))
        mutations.append(try Self.copyDescriptor(base, trust: .approved))
        mutations.append(
            try Self.copyDescriptor(
                base,
                createValidationProfile: .dockerGELF29_2_1
            )
        )
        mutations.append(try Self.copyDescriptor(base, acceptsUnknownOptions: true))

        let changedOptionKinds = base.options.map { option in
            option.name == "tag"
                ? LogDriverOptionDescriptor(
                    name: option.name,
                    valueKind: .string,
                    validationPhase: option.validationPhase,
                    isSecret: option.isSecret,
                    allowedValues: option.allowedValues
                )
                : option
        }
        mutations.append(try Self.copyDescriptor(base, options: changedOptionKinds))
        let changedOptionPhases = base.options.map { option in
            option.name == "tag"
                ? LogDriverOptionDescriptor(
                    name: option.name,
                    valueKind: option.valueKind,
                    validationPhase: .create,
                    isSecret: option.isSecret,
                    allowedValues: option.allowedValues
                )
                : option
        }
        mutations.append(try Self.copyDescriptor(base, options: changedOptionPhases))
        let changedOptionSecrecy = base.options.map { option in
            option.name == "tag"
                ? LogDriverOptionDescriptor(
                    name: option.name,
                    valueKind: option.valueKind,
                    validationPhase: option.validationPhase,
                    isSecret: true,
                    allowedValues: option.allowedValues
                )
                : option
        }
        mutations.append(try Self.copyDescriptor(base, options: changedOptionSecrecy))
        let changedAllowedValues = base.options.map { option in
            option.name == "mode"
                ? LogDriverOptionDescriptor(
                    name: option.name,
                    valueKind: option.valueKind,
                    validationPhase: option.validationPhase,
                    isSecret: option.isSecret,
                    allowedValues: ["non-blocking"]
                )
                : option
        }
        mutations.append(try Self.copyDescriptor(base, options: changedAllowedValues))
        mutations.append(
            try Self.copyDescriptor(
                base,
                crossOptionConstraints: [
                    LogDriverCrossOptionConstraint(
                        whenOptionPresent: "max-buffer-size",
                        requiredOption: "mode",
                        requiredAllowedValues: ["blocking"]
                    )
                ]
            )
        )

        let changedReadFilters = try LogDriverCapabilities(
            deliveryModes: base.capabilities.deliveryModes,
            nativeRead: base.capabilities.nativeRead,
            readFilters: base.capabilities.readFilters.filter { $0 != .details },
            supportsDualCache: base.capabilities.supportsDualCache,
            supportsDockerPluginProtocol: base.capabilities.supportsDockerPluginProtocol,
            requiresDeliverySession: base.capabilities.requiresDeliverySession,
            logPathVisibility: base.capabilities.logPathVisibility,
            fileDefaults: base.capabilities.fileDefaults
        )
        mutations.append(try Self.copyDescriptor(base, capabilities: changedReadFilters))
        let changedCapabilities = try LogDriverCapabilities(
            deliveryModes: [.nonBlocking],
            nativeRead: base.capabilities.nativeRead,
            readFilters: base.capabilities.readFilters,
            supportsDualCache: true,
            supportsDockerPluginProtocol: true,
            requiresDeliverySession: true,
            logPathVisibility: .privateStore,
            fileDefaults: LogDriverFileDefaults(maxSizeInBytes: 1, maxFileCount: 2, compress: true)
        )
        mutations.append(try Self.copyDescriptor(base, capabilities: changedCapabilities))

        let digests = Set(([base] + mutations).map(\.optionContractDigest))
        #expect(digests.count == mutations.count + 1)

        let reloaded = try Self.copyDescriptor(base, providerGeneration: base.providerGeneration + 1)
        #expect(reloaded.optionContractDigest == base.optionContractDigest)

        #expect(throws: LogDriverContractError.self) {
            try Self.copyDescriptor(base, aliases: ["json"], suppliedDigest: base.optionContractDigest)
        }

        var encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any]
        )
        encoded.removeValue(forKey: "createValidationProfile")
        let legacyDecoded = try JSONDecoder().decode(
            LogDriverDescriptor.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        #expect(legacyDecoded.createValidationProfile == .standard)
        #expect(legacyDecoded.optionContractDigest == base.optionContractDigest)

        encoded["trust"] = LogDriverTrust.approved.rawValue
        #expect(throws: LogDriverContractError.self) {
            try JSONDecoder().decode(
                LogDriverDescriptor.self,
                from: JSONSerialization.data(withJSONObject: encoded)
            )
        }
    }

    @Test func dockerProjectionUsesExactEngineShape() throws {
        let projection = DockerLogConfigurationInspection(
            driver: "splunk",
            options: ["splunk-token": "full-authority-value"]
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]
        )
        #expect(object["Type"] as? String == "splunk")
        #expect((object["Config"] as? [String: Any])?["splunk-token"] as? String == "full-authority-value")
        #expect(object["driver"] == nil)
        #expect(object["options"] == nil)
    }

    @Test func catalogRejectsNameAndOptionCollisions() throws {
        let base = BuiltinLogDriverDescriptors.jsonFile
        #expect(throws: LogDriverContractError.duplicateAlias("json-file")) {
            try LogDriverDescriptor(
                driver: "json-file",
                aliases: ["json-file"],
                providerIdentity: base.providerIdentity,
                providerGeneration: 1,
                placement: base.placement,
                trust: base.trust,
                optionContractDigest: base.optionContractDigest,
                options: base.options,
                capabilities: base.capabilities
            )
        }
        #expect(throws: LogDriverContractError.duplicateOption("x")) {
            try LogDriverDescriptor(
                driver: "custom",
                providerIdentity: base.providerIdentity,
                providerGeneration: 1,
                placement: base.placement,
                trust: base.trust,
                optionContractDigest: "sha256:test",
                options: [
                    LogDriverOptionDescriptor(name: "x", valueKind: .string),
                    LogDriverOptionDescriptor(name: "x", valueKind: .boolean),
                ],
                capabilities: base.capabilities
            )
        }
        #expect(throws: LogDriverContractError.duplicateRegisteredName("local")) {
            try LogDriverCatalog(descriptors: [
                BuiltinLogDriverDescriptors.local,
                LogDriverDescriptor(
                    driver: "custom",
                    aliases: ["local"],
                    providerIdentity: base.providerIdentity,
                    providerGeneration: 1,
                    placement: base.placement,
                    trust: base.trust,
                    options: [],
                    capabilities: base.capabilities
                ),
            ])
        }
    }

    @Test func managedContainerRoutineProjectionIsRedactionSafeAndAudienceSpecific() throws {
        var config = makeTestConfiguration(id: "logging-inspect")
        config.logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: "splunk", options: ["splunk-token": "secret-value"]),
            resolved: try Self.makeResolved(
                driver: "splunk",
                safeOptions: [:],
                protectedOptionNames: ["splunk-token"],
                protectedOptionReference: LoggingProtectedOptionsReference(
                    objectID: "secret-object-id",
                    integrityDigest: "hmac:secret-object"
                )
            )
        )
        let container = ManagedContainer(
            configuration: config,
            status: ContainerStatus(state: .stopped, networks: [], startedDate: nil)
        )

        let routine = String(
            decoding: try JSONEncoder().encode(container.routineInspection),
            as: UTF8.self
        )
        #expect(!routine.contains("secret-value"))
        #expect(!routine.contains("secret-object-id"))
        #expect(!routine.contains("<redacted>"))
        #expect(routine.contains("protectedOptionNames"))

        let authoritative = String(decoding: try JSONEncoder().encode(container), as: UTF8.self)
        #expect(!authoritative.contains("secret-value"))
        #expect(authoritative.contains("secret-object-id"))
    }

    private static func makeResolved(
        driver: String = "json-file",
        safeOptions: [String: String] = ["tag": "{{.Name}}"],
        protectedOptionNames: [String] = [],
        protectedOptionReference: LoggingProtectedOptionsReference? = nil
    ) throws -> ResolvedContainerLogConfiguration {
        try ResolvedContainerLogConfiguration(
            leaseGeneration: 3,
            driver: driver,
            safeOptions: safeOptions,
            protectedOptionNames: protectedOptionNames,
            protectedOptionReference: protectedOptionReference,
            delivery: try LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: BuiltinLogDriverDescriptors.coreProvider,
            providerGenerationAtResolution: 7,
            contractDigest: "sha256:contract"
        )
    }

    private static func copyDescriptor(
        _ descriptor: LogDriverDescriptor,
        driver: String? = nil,
        aliases: [String]? = nil,
        providerIdentity: LogDriverProviderIdentity? = nil,
        providerGeneration: UInt64? = nil,
        placement: LogDriverPlacement? = nil,
        trust: LogDriverTrust? = nil,
        suppliedDigest: String? = nil,
        options: [LogDriverOptionDescriptor]? = nil,
        crossOptionConstraints: [LogDriverCrossOptionConstraint]? = nil,
        createValidationProfile: LogDriverCreateValidationProfile? = nil,
        acceptsUnknownOptions: Bool? = nil,
        capabilities: LogDriverCapabilities? = nil
    ) throws -> LogDriverDescriptor {
        try LogDriverDescriptor(
            driver: driver ?? descriptor.driver,
            aliases: aliases ?? descriptor.aliases,
            providerIdentity: providerIdentity ?? descriptor.providerIdentity,
            providerGeneration: providerGeneration ?? descriptor.providerGeneration,
            placement: placement ?? descriptor.placement,
            trust: trust ?? descriptor.trust,
            optionContractDigest: suppliedDigest,
            options: options ?? descriptor.options,
            crossOptionConstraints: crossOptionConstraints ?? descriptor.crossOptionConstraints,
            createValidationProfile: createValidationProfile ?? descriptor.createValidationProfile,
            acceptsUnknownOptions: acceptsUnknownOptions ?? descriptor.acceptsUnknownOptions,
            capabilities: capabilities ?? descriptor.capabilities
        )
    }

    private static func expectUnknownSchemaRejected<Value: Codable>(_ value: Value) throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Value.self, from: data)
        }
    }
}
