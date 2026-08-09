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
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerLogRequestResolverTests {
    @Test(arguments: [nil, ""] as [String?])
    func omittedAndEmptyDriverResolveSystemDefaultLosslessly(driver: String?) throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(
                driver: "json-file",
                options: ["max-file": "3", "max-size": "10m"]
            ),
            catalog: BuiltinLogDriverDescriptors.current
        )
        let request = ContainerLogRequest(driver: driver)

        let prepared = try resolver.prepare(request)

        #expect(prepared.requestedDriver == driver)
        #expect(prepared.descriptor.driver == "json-file")
        #expect(prepared.safeOptions == ["max-file": "3", "max-size": "10m"])
        #expect(prepared.delivery.requestedMode == nil)
        #expect(prepared.readPolicy.source == .direct)
        let finalized = try prepared.finalizedConfiguration(protectedReference: nil)
        #expect(finalized.requested?.driver == driver)
        #expect(finalized.resolved?.driver == "json-file")
    }

    @Test func explicitDefaultInheritsMissingOptionsAndContainerValuesWin() throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(
                driver: "json-file",
                options: ["max-file": "3", "max-size": "10m"]
            ),
            catalog: BuiltinLogDriverDescriptors.current
        )

        let prepared = try resolver.prepare(
            ContainerLogRequest(
                driver: "json-file",
                options: ["max-size": "20m"]
            )
        )

        #expect(prepared.safeOptions == ["max-file": "3", "max-size": "20m"])
    }

    @Test func nondefaultDriverInheritsOnlyCacheDefaults() throws {
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(
                driver: "json-file",
                options: [
                    "cache-max-file": "7",
                    "max-file": "3",
                    "tag": "default-tag",
                ]
            ),
            catalog: BuiltinLogDriverDescriptors.current
        )

        let prepared = try resolver.prepare(ContainerLogRequest(driver: "local"))

        #expect(prepared.safeOptions == ["cache-max-file": "7"])
        #expect(prepared.readPolicy.source == .direct)
    }

    @Test func unknownDriversAndStrictOptionsFailWithoutEchoingValues() throws {
        let resolver = makeResolver()
        #expect(throws: ContainerLogResolutionError.unknownDriver("missing")) {
            try resolver.prepare(ContainerLogRequest(driver: "missing"))
        }

        let secret = "do-not-echo-this-value"
        do {
            _ = try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: ["unknown": secret]
                )
            )
            Issue.record("strict driver accepted an unknown option")
        } catch {
            #expect(!String(describing: error).contains(secret))
            #expect(
                error as? ContainerLogResolutionError
                    == .unknownOption(driver: "json-file", name: "unknown")
            )
        }
    }

    @Test func nonePreservesArbitraryOptionsAsProtectedAndNeedsNoSession() throws {
        let request = ContainerLogRequest(
            driver: "none",
            options: ["": "empty-name", "opaque": "secret-value"]
        )
        let prepared = try makeResolver().prepare(request)

        #expect(prepared.safeOptions.isEmpty)
        #expect(prepared.protectedOptions.names == ["", "opaque"])
        #expect(prepared.delivery.effectiveMode == .blocking)
        #expect(prepared.readPolicy.source == .unavailable)
        #expect(!String(describing: prepared).contains("secret-value"))

        #expect(throws: ContainerLogResolutionError.protectedReferenceMismatch) {
            try prepared.finalizedConfiguration(protectedReference: nil)
        }
        let reference = LoggingProtectedOptionsReference(
            objectID: "object",
            integrityDigest: "hmac-sha256:digest"
        )
        let finalized = try prepared.finalizedConfiguration(protectedReference: reference)
        #expect(finalized.resolved?.protectedOptionNames == ["", "opaque"])
    }

    @Test func deliveryPreservesOmissionExplicitBlockingAndEffectiveCapacity() throws {
        let resolver = makeResolver()
        let omitted = try resolver.prepare(ContainerLogRequest(driver: "json-file"))
        let blocking = try resolver.prepare(
            ContainerLogRequest(driver: "json-file", options: ["mode": "blocking"])
        )
        let nonBlocking = try resolver.prepare(
            ContainerLogRequest(
                driver: "json-file",
                options: ["max-buffer-size": "0", "mode": "non-blocking"]
            )
        )
        let explicitEmpty = try resolver.prepare(
            ContainerLogRequest(driver: "json-file", options: ["mode": ""])
        )

        #expect(omitted.delivery.requestedMode == nil)
        #expect(blocking.delivery.requestedMode == .blocking)
        #expect(nonBlocking.delivery.requestedMode == .nonBlocking)
        #expect(nonBlocking.delivery.maxBufferSizeInBytes == 0)
        #expect(nonBlocking.delivery.effectiveMaxBufferSizeInBytes == 0)
        #expect(explicitEmpty.delivery.requestedMode == nil)
        #expect(explicitEmpty.safeOptions["mode"] == "")

        #expect(throws: ContainerLogResolutionError.self) {
            try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: ["max-buffer-size": "1m"]
                )
            )
        }
    }

    @Test func startPhaseValuesRemainFrozenButCreatePhaseValuesFailEarly() throws {
        let resolver = makeResolver()
        let deferred = try resolver.prepare(
            ContainerLogRequest(
                driver: "json-file",
                options: [
                    "compress": "not-a-boolean",
                    "max-file": "not-an-integer",
                    "max-size": "not-a-size",
                ]
            )
        )
        #expect(deferred.safeOptions["max-file"] == "not-an-integer")
        #expect(deferred.safeOptions["max-size"] == "not-a-size")
        #expect(deferred.safeOptions["compress"] == "not-a-boolean")

        #expect(throws: ContainerLogResolutionError.self) {
            try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: ["cache-disabled": "not-a-boolean"]
                )
            )
        }
    }

    @Test func remoteReaderPolicyUsesPinnedCacheDefaultsAndDisable() throws {
        let remote = try remoteDescriptor(secretOption: nil)
        let catalog = try LogDriverCatalog(
            descriptors: BuiltinLogDriverDescriptors.current.descriptors + [remote]
        )
        let resolver = ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: catalog
        )

        let defaults = try resolver.prepare(ContainerLogRequest(driver: remote.driver))
        #expect(defaults.readPolicy.source == .dualCache)
        #expect(defaults.readPolicy.cache?.maxSizeInBytes == 20 * 1024 * 1024)
        #expect(defaults.readPolicy.cache?.maxFileCount == 5)
        #expect(defaults.readPolicy.cache?.compress == true)

        let overridden = try resolver.prepare(
            ContainerLogRequest(
                driver: remote.driver,
                options: [
                    "cache-compress": "false",
                    "cache-max-file": "2",
                    "cache-max-size": "1m",
                ]
            )
        )
        #expect(overridden.readPolicy.cache?.maxSizeInBytes == 20 * 1024 * 1024)
        #expect(overridden.readPolicy.cache?.maxFileCount == 5)
        #expect(overridden.readPolicy.cache?.compress == true)
        #expect(overridden.safeOptions["cache-max-size"] == "1m")
        #expect(overridden.safeOptions["cache-max-file"] == "2")
        #expect(overridden.safeOptions["cache-compress"] == "false")

        let disabled = try resolver.prepare(
            ContainerLogRequest(
                driver: remote.driver,
                options: ["cache-disabled": "true"]
            )
        )
        #expect(disabled.readPolicy.source == .unavailable)
    }

    @Test func cacheOptionsMatchDockerBooleanAndIgnoredPrefixSemantics() throws {
        let remote = try remoteDescriptor(secretOption: nil)
        let catalog = try LogDriverCatalog(
            descriptors: BuiltinLogDriverDescriptors.current.descriptors + [remote]
        )
        let resolver = ContainerLogRequestResolver(defaults: LoggingConfig(), catalog: catalog)

        for value in ["true", "True", "TRUE", "1", "t", "T"] {
            let prepared = try resolver.prepare(
                ContainerLogRequest(driver: remote.driver, options: ["cache-disabled": value])
            )
            #expect(prepared.readPolicy.source == .unavailable)
        }
        for value in ["", "false", "False", "FALSE", "0", "f", "F"] {
            let prepared = try resolver.prepare(
                ContainerLogRequest(driver: remote.driver, options: ["cache-disabled": value])
            )
            #expect(prepared.readPolicy.source == .dualCache)
        }
        #expect(throws: ContainerLogResolutionError.self) {
            try resolver.prepare(
                ContainerLogRequest(driver: remote.driver, options: ["cache-disabled": "yes"])
            )
        }

        let arbitrary = try resolver.prepare(
            ContainerLogRequest(
                driver: remote.driver,
                options: [
                    "cache-compress": "not-a-boolean",
                    "cache-max-file": "not-an-integer",
                    "cache-max-size": "not-a-size",
                ]
            )
        )
        #expect(arbitrary.readPolicy.source == .dualCache)
        #expect(arbitrary.safeOptions["cache-compress"] == "not-a-boolean")
        #expect(arbitrary.safeOptions["cache-max-file"] == "not-an-integer")
        #expect(arbitrary.safeOptions["cache-max-size"] == "not-a-size")
    }

    @Test func maxBufferSizeMatchesDockerGoUnitsGrammar() throws {
        let resolver = makeResolver()
        let accepted = ["0", "1", "+1", "01", "1.5k", "1KB", "1KiB", "1 k", "+1m", ".5m", "1e3", "1_0"]
        for value in accepted {
            let prepared = try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: ["max-buffer-size": value, "mode": "non-blocking"]
                )
            )
            #expect(prepared.delivery.maxBufferSizeInBytes != nil)
        }

        for value in ["", "-1", " 1k ", "nonsense", "1xb", "1__0"] {
            #expect(throws: ContainerLogResolutionError.self) {
                try resolver.prepare(
                    ContainerLogRequest(
                        driver: "json-file",
                        options: ["max-buffer-size": value, "mode": "non-blocking"]
                    )
                )
            }
        }
    }

    @Test func providerDeclaredSecretsAreSealedAndSafeValuesRemainVisible() throws {
        let secret = "provider-secret-value"
        let remote = try remoteDescriptor(secretOption: "token")
        let catalog = try LogDriverCatalog(
            descriptors: BuiltinLogDriverDescriptors.current.descriptors + [remote]
        )
        let resolver = ContainerLogRequestResolver(defaults: LoggingConfig(), catalog: catalog)

        let prepared = try resolver.prepare(
            ContainerLogRequest(
                driver: remote.driver,
                options: ["endpoint": "tcp://host:1", "token": secret]
            )
        )

        #expect(prepared.safeOptions == ["endpoint": "tcp://host:1"])
        #expect(prepared.protectedOptions.names == ["token"])
        #expect(!prepared.protectedOptions.description.contains(secret))
        #expect(prepared.protectedOptions.withValues { $0["token"] } == secret)
    }

    @Test func requestAndDefaultBoundsFailClosed() throws {
        let resolver = makeResolver()
        #expect(throws: ContainerLogResolutionError.self) {
            try resolver.prepare(
                ContainerLogRequest(
                    driver: "json-file",
                    options: ["tag": String(repeating: "x", count: 65 * 1024)]
                )
            )
        }
        #expect(throws: ContainerLogResolutionError.self) {
            try ContainerLogRequestResolver(
                defaults: LoggingConfig(driver: String(repeating: "x", count: 257)),
                catalog: BuiltinLogDriverDescriptors.current
            ).prepare(ContainerLogRequest())
        }
    }

    private func makeResolver() -> ContainerLogRequestResolver {
        ContainerLogRequestResolver(
            defaults: LoggingConfig(),
            catalog: BuiltinLogDriverDescriptors.current
        )
    }

    private func remoteDescriptor(secretOption: String?) throws -> LogDriverDescriptor {
        var options = [
            LogDriverOptionDescriptor(name: "endpoint", valueKind: .string),
            LogDriverOptionDescriptor(
                name: "max-buffer-size",
                valueKind: .size
            ),
            LogDriverOptionDescriptor(
                name: "mode",
                valueKind: .string,
                allowedValues: ["blocking", "non-blocking"]
            ),
        ]
        if let secretOption {
            options.append(
                LogDriverOptionDescriptor(
                    name: secretOption,
                    valueKind: .string,
                    isSecret: true
                )
            )
        }
        return try LogDriverDescriptor(
            driver: "acme-remote",
            providerIdentity: LogDriverProviderIdentity(
                id: "example.acme.logging",
                version: "1",
                kind: .native
            ),
            providerGeneration: 1,
            placement: .macOSHost,
            trust: .signed,
            options: options,
            crossOptionConstraints: [
                LogDriverCrossOptionConstraint(
                    whenOptionPresent: "max-buffer-size",
                    requiredOption: "mode",
                    requiredAllowedValues: ["non-blocking"]
                )
            ],
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
    }
}
