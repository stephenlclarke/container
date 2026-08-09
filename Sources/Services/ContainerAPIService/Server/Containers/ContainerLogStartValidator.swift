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

import ContainerResource

enum ContainerLogStartValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case legacyConfiguration
    case incompleteV2Configuration
    case invalidLeaseGeneration
    case unknownDriver(String)
    case nonCanonicalDriver(resolved: String, canonical: String)
    case requestedDriverMismatch(requested: String, resolved: String)
    case providerIdentityMismatch(
        expected: LogDriverProviderIdentity,
        actual: LogDriverProviderIdentity
    )
    case providerGenerationMismatch(expected: UInt64, actual: UInt64)
    case contractDigestMismatch(expected: String, actual: String)
    case safeOptionClassificationMismatch(driver: String, name: String)
    case protectedOptionNamesMismatch(expected: [String], actual: [String])
    case protectedOptionClassificationMismatch(driver: String, name: String)
    case capabilitiesMismatch(driver: String, reason: String)
    case deliveryConfigurationMismatch(driver: String)
    case readPolicyMismatch(driver: String)

    var description: String {
        switch self {
        case .legacyConfiguration:
            "legacy logging configuration does not use logging-v2 start validation"
        case .incompleteV2Configuration:
            "logging-v2 configuration is incomplete"
        case .invalidLeaseGeneration:
            "logging-v2 lease generation must be positive"
        case .unknownDriver(let driver):
            "resolved logging driver \(String(reflecting: driver)) is not registered"
        case .nonCanonicalDriver(let resolved, let canonical):
            "resolved logging driver \(String(reflecting: resolved)) is not canonical; expected \(String(reflecting: canonical))"
        case .requestedDriverMismatch(let requested, let resolved):
            "requested logging driver \(String(reflecting: requested)) no longer resolves to \(String(reflecting: resolved))"
        case .providerIdentityMismatch(let expected, let actual):
            "resolved logging provider identity \(String(reflecting: actual)) does not match \(String(reflecting: expected))"
        case .providerGenerationMismatch(let expected, let actual):
            "resolved logging provider generation \(actual) does not match loaded generation \(expected)"
        case .contractDigestMismatch(let expected, let actual):
            "resolved logging contract digest \(String(reflecting: actual)) does not match \(String(reflecting: expected))"
        case .safeOptionClassificationMismatch(let driver, let name):
            "safe log option \(String(reflecting: name)) does not match the contract for driver \(String(reflecting: driver))"
        case .protectedOptionNamesMismatch(let expected, let actual):
            "authenticated protected log option names \(actual) do not match resolved names \(expected)"
        case .protectedOptionClassificationMismatch(let driver, let name):
            "protected log option \(String(reflecting: name)) does not match the contract for driver \(String(reflecting: driver))"
        case .capabilitiesMismatch(let driver, let reason):
            "resolved logging behavior is incompatible with driver \(String(reflecting: driver)): \(reason)"
        case .deliveryConfigurationMismatch(let driver):
            "resolved delivery configuration does not match options for driver \(String(reflecting: driver))"
        case .readPolicyMismatch(let driver):
            "resolved read policy does not match options for driver \(String(reflecting: driver))"
        }
    }
}

/// Pure start-phase fence for an authority-persisted logging-v2 contract.
/// Protected values have already been authenticated by the caller; this type
/// checks their exact names and contract classification without performing I/O.
struct ContainerLogStartValidator: Sendable {
    let catalog: LogDriverCatalog

    func validate(
        _ configuration: ContainerLogConfiguration,
        authenticatedProtectedOptions: [String: String]
    ) throws {
        guard !configuration.isLegacy else {
            throw ContainerLogStartValidationError.legacyConfiguration
        }
        guard let requested = configuration.requested, let resolved = configuration.resolved else {
            throw ContainerLogStartValidationError.incompleteV2Configuration
        }
        guard resolved.leaseGeneration > 0 else {
            throw ContainerLogStartValidationError.invalidLeaseGeneration
        }
        guard let descriptor = catalog.descriptor(named: resolved.driver) else {
            throw ContainerLogStartValidationError.unknownDriver(resolved.driver)
        }
        guard resolved.driver == descriptor.driver else {
            throw ContainerLogStartValidationError.nonCanonicalDriver(
                resolved: resolved.driver,
                canonical: descriptor.driver
            )
        }
        if let requestedDriver = requested.driver, !requestedDriver.isEmpty {
            guard catalog.descriptor(named: requestedDriver)?.driver == descriptor.driver else {
                throw ContainerLogStartValidationError.requestedDriverMismatch(
                    requested: requestedDriver,
                    resolved: resolved.driver
                )
            }
        }
        guard resolved.providerIdentity == descriptor.providerIdentity else {
            throw ContainerLogStartValidationError.providerIdentityMismatch(
                expected: descriptor.providerIdentity,
                actual: resolved.providerIdentity
            )
        }
        guard resolved.providerGenerationAtResolution == descriptor.providerGeneration else {
            throw ContainerLogStartValidationError.providerGenerationMismatch(
                expected: descriptor.providerGeneration,
                actual: resolved.providerGenerationAtResolution
            )
        }
        // The descriptor digest includes every capability, placement, trust,
        // option, constraint, and alias field but deliberately excludes the
        // separately fenced loaded-provider generation.
        guard resolved.contractDigest == descriptor.optionContractDigest else {
            throw ContainerLogStartValidationError.contractDigestMismatch(
                expected: descriptor.optionContractDigest,
                actual: resolved.contractDigest
            )
        }

        let expectedProtectedNames = resolved.protectedOptionNames.sorted()
        let actualProtectedNames = authenticatedProtectedOptions.keys.sorted()
        guard actualProtectedNames == expectedProtectedNames else {
            throw ContainerLogStartValidationError.protectedOptionNamesMismatch(
                expected: expectedProtectedNames,
                actual: actualProtectedNames
            )
        }

        let options = try validateOptions(
            safeOptions: resolved.safeOptions,
            protectedOptions: authenticatedProtectedOptions,
            descriptor: descriptor
        )
        try ContainerLogDriverCreateProfileValidator.validate(
            descriptor.createValidationProfile,
            options: options,
            driver: descriptor.driver
        )
        try ContainerLogOptionContractValidator.validateCrossOptionConstraints(
            descriptor.crossOptionConstraints,
            options: options,
            driver: descriptor.driver
        )
        try validateFileDriverConstraints(options: options, descriptor: descriptor)
        try validateCapabilities(resolved: resolved, descriptor: descriptor)

        let expectedDelivery = try ContainerLogRequestResolver.deliveryConfiguration(
            options: options,
            descriptor: descriptor
        )
        guard resolved.delivery == expectedDelivery else {
            throw ContainerLogStartValidationError.deliveryConfigurationMismatch(driver: descriptor.driver)
        }

        let expectedReadPolicy = try ContainerLogRequestResolver.readPolicy(
            options: options,
            descriptor: descriptor
        )
        guard resolved.readPolicy == expectedReadPolicy else {
            throw ContainerLogStartValidationError.readPolicyMismatch(driver: descriptor.driver)
        }
    }

    private func validateOptions(
        safeOptions: [String: String],
        protectedOptions: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> [String: String] {
        let declaredOptions = Dictionary(uniqueKeysWithValues: descriptor.options.map { ($0.name, $0) })
        var options = safeOptions

        for (name, value) in safeOptions {
            if let option = declaredOptions[name] {
                guard !option.isSecret else {
                    throw ContainerLogStartValidationError.safeOptionClassificationMismatch(
                        driver: descriptor.driver,
                        name: name
                    )
                }
                // Phase controls when an original client request fails. At
                // start, every persisted scalar is revalidated so on-disk
                // substitution cannot bypass a create-phase contract.
                try ContainerLogOptionContractValidator.validate(
                    value,
                    for: option,
                    driver: descriptor.driver
                )
            } else if !ContainerLogRequestResolver.cacheOptionNames.contains(name) {
                // Provider-accepted unknown values are protected by default at
                // create and therefore can never appear in safe persisted state.
                throw ContainerLogStartValidationError.safeOptionClassificationMismatch(
                    driver: descriptor.driver,
                    name: name
                )
            }
        }

        for (name, value) in protectedOptions {
            if let option = declaredOptions[name] {
                guard option.isSecret else {
                    throw ContainerLogStartValidationError.protectedOptionClassificationMismatch(
                        driver: descriptor.driver,
                        name: name
                    )
                }
                try ContainerLogOptionContractValidator.validate(
                    value,
                    for: option,
                    driver: descriptor.driver
                )
            } else {
                guard
                    descriptor.acceptsUnknownOptions,
                    !ContainerLogRequestResolver.cacheOptionNames.contains(name)
                else {
                    throw ContainerLogStartValidationError.protectedOptionClassificationMismatch(
                        driver: descriptor.driver,
                        name: name
                    )
                }
            }
            options[name] = value
        }
        return options
    }

    private func validateCapabilities(
        resolved: ResolvedContainerLogConfiguration,
        descriptor: LogDriverDescriptor
    ) throws {
        let capabilities = descriptor.capabilities
        if capabilities.requiresDeliverySession {
            guard capabilities.deliveryModes.contains(resolved.delivery.effectiveMode) else {
                throw ContainerLogStartValidationError.capabilitiesMismatch(
                    driver: descriptor.driver,
                    reason: "resolved delivery mode is not supported"
                )
            }
        } else {
            guard resolved.delivery == (try LogDeliveryConfiguration()) else {
                throw ContainerLogStartValidationError.capabilitiesMismatch(
                    driver: descriptor.driver,
                    reason: "sessionless driver has a non-default delivery configuration"
                )
            }
        }

        switch resolved.readPolicy.source {
        case .direct:
            guard capabilities.nativeRead else {
                throw ContainerLogStartValidationError.capabilitiesMismatch(
                    driver: descriptor.driver,
                    reason: "direct reads are not supported"
                )
            }
        case .dualCache:
            guard capabilities.supportsDualCache else {
                throw ContainerLogStartValidationError.capabilitiesMismatch(
                    driver: descriptor.driver,
                    reason: "dual-cache reads are not supported"
                )
            }
        case .unavailable:
            break
        case .legacyLocalV1:
            throw ContainerLogStartValidationError.capabilitiesMismatch(
                driver: descriptor.driver,
                reason: "logging-v2 cannot use the legacy reader"
            )
        }
    }

    /// Moby deliberately defers the file drivers' rotation grammar until
    /// start. The descriptor's generic option contracts cover each scalar;
    /// this fence covers the effective cross-option defaults that cannot be
    /// represented by a simple "option is present" constraint.
    private func validateFileDriverConstraints(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws {
        guard descriptor.driver == "json-file" || descriptor.driver == "local" else {
            return
        }

        let defaultCompress = descriptor.capabilities.fileDefaults?.compress ?? false
        let compress: Bool
        if let value = options["compress"] {
            guard let parsed = ContainerLogOptionValueParser.boolean(value) else {
                // The scalar validation above normally owns this error. Keep
                // the helper total when called with a custom descriptor.
                throw ContainerLogResolutionError.invalidOption(
                    driver: descriptor.driver,
                    name: "compress",
                    reason: "expected a boolean"
                )
            }
            compress = parsed
        } else {
            compress = defaultCompress
        }
        guard compress else {
            return
        }

        let defaultMaxFile = descriptor.capabilities.fileDefaults?.maxFileCount ?? 1
        let maxFile = options["max-file"].flatMap(Int.init) ?? defaultMaxFile
        let hasMaximumSize =
            options["max-size"] != nil
            || descriptor.capabilities.fileDefaults?.maxSizeInBytes != nil
        guard maxFile >= 2, hasMaximumSize else {
            // Moby's local driver has a concrete default max-size, so its
            // start-time diagnostic can identify a one-file rotation policy.
            let reason: String
            if descriptor.driver == "local", maxFile < 2 {
                reason = "compression cannot be enabled when max file count is \(maxFile)"
            } else {
                reason = "compress cannot be true when max-file is less than 2 or max-size is not set"
            }
            throw ContainerLogResolutionError.invalidOption(
                driver: descriptor.driver,
                name: "compress",
                reason: reason
            )
        }
    }
}
