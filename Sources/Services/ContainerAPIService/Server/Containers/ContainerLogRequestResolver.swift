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

enum ContainerLogResolutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidRequest(String)
    case unknownDriver(String)
    case unknownOption(driver: String, name: String)
    case invalidOption(driver: String, name: String, reason: String)
    case unsupportedDeliveryMode(driver: String, mode: LogDeliveryConfiguration.Mode)
    case protectedReferenceMismatch

    var description: String {
        switch self {
        case .invalidRequest(let reason):
            "invalid logging request: \(reason)"
        case .unknownDriver(let driver):
            "unknown logging driver \(String(reflecting: driver))"
        case .unknownOption(let driver, let name):
            "unknown log option \(String(reflecting: name)) for driver \(String(reflecting: driver))"
        case .invalidOption(let driver, let name, let reason):
            "invalid log option \(String(reflecting: name)) for driver \(String(reflecting: driver)): \(reason)"
        case .unsupportedDeliveryMode(let driver, let mode):
            "logging driver \(String(reflecting: driver)) does not support mode \(String(reflecting: mode.rawValue))"
        case .protectedReferenceMismatch:
            "protected logging option reference does not match the prepared request"
        }
    }
}

/// A raw-value wrapper whose textual projections deliberately disclose only
/// option names. Authority code can borrow the values only for protected-store
/// sealing or an authenticated provider call.
struct ProtectedLoggingOptionValues: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: [String: String]

    init(_ storage: [String: String]) {
        self.storage = storage
    }

    var names: [String] {
        storage.keys.sorted()
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var description: String {
        "ProtectedLoggingOptionValues(names: \(names), count: \(storage.count))"
    }

    var debugDescription: String {
        description
    }

    func withValues<Result>(_ body: ([String: String]) throws -> Result) rethrows -> Result {
        try body(storage)
    }

    func withValues<Result>(
        _ body: ([String: String]) async throws -> Result
    ) async rethrows -> Result {
        try await body(storage)
    }
}

/// Pure, side-effect-free create-phase result. Raw protected values have not
/// yet been sealed and this value must never be persisted or logged.
struct PreparedContainerLogResolution: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let requestedDriver: String?
    let requestedSafeOptions: [String: String]
    let requestedProtectedOptionNames: [String]
    let descriptor: LogDriverDescriptor
    let safeOptions: [String: String]
    let protectedOptions: ProtectedLoggingOptionValues
    let delivery: LogDeliveryConfiguration
    let readPolicy: LogReadPolicy

    var description: String {
        "PreparedContainerLogResolution(driver: \(String(reflecting: requestedDriver)), "
            + "safeOptionNames: \(safeOptions.keys.sorted()), "
            + "protectedOptionNames: \(protectedOptions.names))"
    }

    var debugDescription: String {
        description
    }

    func finalizedConfiguration(
        protectedReference: LoggingProtectedOptionsReference?,
        leaseGeneration: UInt64 = 1
    ) throws -> ContainerLogConfiguration {
        guard leaseGeneration > 0 else {
            throw ContainerLogResolutionError.invalidRequest("logging lease generation must be positive")
        }
        guard protectedOptions.isEmpty == (protectedReference == nil) else {
            throw ContainerLogResolutionError.protectedReferenceMismatch
        }

        var exactRequestedOptions = requestedSafeOptions
        try protectedOptions.withValues { protectedValues in
            for name in requestedProtectedOptionNames {
                guard let value = protectedValues[name] else {
                    throw ContainerLogResolutionError.protectedReferenceMismatch
                }
                exactRequestedOptions[name] = value
            }
        }
        let exactRequest = ContainerLogRequest(
            driver: requestedDriver,
            options: exactRequestedOptions
        )
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: leaseGeneration,
            driver: descriptor.driver,
            safeOptions: safeOptions,
            protectedOptionNames: protectedOptions.names,
            protectedOptionReference: protectedReference,
            delivery: delivery,
            readPolicy: readPolicy,
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: descriptor.providerGeneration,
            contractDigest: descriptor.optionContractDigest
        )
        return try ContainerLogConfiguration(requested: exactRequest, resolved: resolved)
    }
}

/// Resolves immutable logging intent at the Container authority boundary.
/// Compose and other clients provide only ``ContainerLogRequest``.
struct ContainerLogRequestResolver: Sendable {
    static let maximumEncodedRequestBytes = ContainerLogRequest.maximumEncodedTransportBytes
    static let defaultCacheMaxSizeInBytes: UInt64 = 20 * 1024 * 1024
    static let defaultCacheMaxFileCount = 5
    static let defaultCacheCompress = true

    private enum Limit {
        static let driverBytes = 256
        static let optionCount = 256
        static let optionNameBytes = 256
        static let optionValueBytes = 64 * 1024
        static let totalOptionBytes = 1024 * 1024
    }

    private static let cacheOptionNames: Set<String> = [
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
    ]

    let defaults: LoggingConfig
    let catalog: LogDriverCatalog

    func prepare(_ request: ContainerLogRequest) throws -> PreparedContainerLogResolution {
        try Self.validateRequestBounds(request)
        try Self.validateDefaultsBounds(defaults)

        let selectedName = request.driver.flatMap { $0.isEmpty ? nil : $0 } ?? defaults.driver
        guard !selectedName.isEmpty else {
            throw ContainerLogResolutionError.invalidRequest("the system default driver is empty")
        }
        guard let descriptor = catalog.descriptor(named: selectedName) else {
            throw ContainerLogResolutionError.unknownDriver(selectedName)
        }
        guard let defaultDescriptor = catalog.descriptor(named: defaults.driver) else {
            throw ContainerLogResolutionError.unknownDriver(defaults.driver)
        }

        var effectiveOptions = request.options
        if descriptor.driver == defaultDescriptor.driver {
            Self.mergeMissing(defaults.options, into: &effectiveOptions)
        } else {
            Self.mergeMissing(
                defaults.options.filter { Self.cacheOptionNames.contains($0.key) },
                into: &effectiveOptions
            )
        }
        try Self.validateOptionBounds(effectiveOptions)

        let optionDescriptors = Dictionary(uniqueKeysWithValues: descriptor.options.map { ($0.name, $0) })
        var safeOptions: [String: String] = [:]
        var protectedOptions: [String: String] = [:]
        for (name, value) in effectiveOptions {
            if let option = optionDescriptors[name] {
                if option.validationPhase == .create {
                    try Self.validate(value, for: option, driver: descriptor.driver)
                }
                if option.isSecret {
                    protectedOptions[name] = value
                } else {
                    safeOptions[name] = value
                }
            } else if Self.cacheOptionNames.contains(name) {
                try Self.validateCacheOption(name: name, value: value, driver: descriptor.driver)
                safeOptions[name] = value
            } else if descriptor.acceptsUnknownOptions {
                // Unknown values are protected by default. A future provider
                // must explicitly classify a name before routine diagnostics
                // may expose its value.
                protectedOptions[name] = value
            } else {
                throw ContainerLogResolutionError.unknownOption(driver: descriptor.driver, name: name)
            }
        }

        try Self.validateCrossOptionConstraints(
            descriptor.crossOptionConstraints,
            options: effectiveOptions,
            driver: descriptor.driver
        )
        let delivery = try Self.deliveryConfiguration(
            options: effectiveOptions,
            descriptor: descriptor
        )
        let readPolicy = try Self.readPolicy(
            options: effectiveOptions,
            descriptor: descriptor
        )
        let requestedNames = Set(request.options.keys)
        let requestedSafeOptions = safeOptions.filter { requestedNames.contains($0.key) }
        let requestedProtectedOptionNames = protectedOptions.keys
            .filter { requestedNames.contains($0) }
            .sorted()

        return PreparedContainerLogResolution(
            requestedDriver: request.driver,
            requestedSafeOptions: requestedSafeOptions,
            requestedProtectedOptionNames: requestedProtectedOptionNames,
            descriptor: descriptor,
            safeOptions: safeOptions,
            protectedOptions: ProtectedLoggingOptionValues(protectedOptions),
            delivery: delivery,
            readPolicy: readPolicy
        )
    }

    private static func mergeMissing(
        _ defaults: [String: String],
        into options: inout [String: String]
    ) {
        for (name, value) in defaults where options[name] == nil {
            options[name] = value
        }
    }

    private static func validateRequestBounds(_ request: ContainerLogRequest) throws {
        if let driver = request.driver, driver.utf8.count > Limit.driverBytes {
            throw ContainerLogResolutionError.invalidRequest("driver identity exceeds the byte limit")
        }
        try validateOptionBounds(request.options)
    }

    private static func validateDefaultsBounds(_ defaults: LoggingConfig) throws {
        guard defaults.driver.utf8.count <= Limit.driverBytes else {
            throw ContainerLogResolutionError.invalidRequest("system default driver exceeds the byte limit")
        }
        try validateOptionBounds(defaults.options)
    }

    private static func validateOptionBounds(_ options: [String: String]) throws {
        guard options.count <= Limit.optionCount else {
            throw ContainerLogResolutionError.invalidRequest("logging option count exceeds the limit")
        }
        var total = 0
        for (name, value) in options {
            let nameBytes = name.utf8.count
            let valueBytes = value.utf8.count
            guard nameBytes <= Limit.optionNameBytes else {
                throw ContainerLogResolutionError.invalidRequest("a logging option name exceeds the byte limit")
            }
            guard valueBytes <= Limit.optionValueBytes else {
                throw ContainerLogResolutionError.invalidRequest(
                    "logging option \(String(reflecting: name)) exceeds the value byte limit"
                )
            }
            let (entryBytes, entryOverflow) = nameBytes.addingReportingOverflow(valueBytes)
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(entryBytes)
            guard !entryOverflow, !totalOverflow, nextTotal <= Limit.totalOptionBytes else {
                throw ContainerLogResolutionError.invalidRequest("logging option bytes exceed the total limit")
            }
            total = nextTotal
        }
    }

    private static func validate(
        _ value: String,
        for option: LogDriverOptionDescriptor,
        driver: String
    ) throws {
        if !option.allowedValues.isEmpty, !option.allowedValues.contains(value) {
            throw invalidOption(driver: driver, name: option.name, reason: "value is not allowed")
        }
        switch option.valueKind {
        case .string, .commaSeparatedNames, .tagTemplate:
            return
        case .boolean:
            guard parseBoolean(value) != nil else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a boolean")
            }
        case .positiveInteger:
            guard let value = Int(value), value > 0 else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a positive integer")
            }
        case .size:
            guard parseSize(value, allowingZero: option.name == "max-buffer-size") != nil else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a valid byte size")
            }
        case .regularExpression:
            do {
                _ = try Regex(value)
            } catch {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a regular expression")
            }
        }
    }

    private static func validateCrossOptionConstraints(
        _ constraints: [LogDriverCrossOptionConstraint],
        options: [String: String],
        driver: String
    ) throws {
        for constraint in constraints where options[constraint.whenOptionPresent] != nil {
            guard
                let required = options[constraint.requiredOption],
                constraint.requiredAllowedValues.contains(required)
            else {
                throw invalidOption(
                    driver: driver,
                    name: constraint.whenOptionPresent,
                    reason:
                        "requires \(String(reflecting: constraint.requiredOption)) to use an allowed value"
                )
            }
        }
    }

    private static func deliveryConfiguration(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> LogDeliveryConfiguration {
        guard descriptor.capabilities.requiresDeliverySession else {
            return try LogDeliveryConfiguration()
        }

        let requestedMode: LogDeliveryConfiguration.Mode?
        if let value = options["mode"], !value.isEmpty {
            guard let mode = LogDeliveryConfiguration.Mode(rawValue: value) else {
                throw invalidOption(driver: descriptor.driver, name: "mode", reason: "value is not allowed")
            }
            guard descriptor.capabilities.deliveryModes.contains(mode) else {
                throw ContainerLogResolutionError.unsupportedDeliveryMode(driver: descriptor.driver, mode: mode)
            }
            requestedMode = mode
        } else {
            requestedMode = nil
        }

        let maxBufferSize: UInt64?
        if let value = options["max-buffer-size"] {
            guard let parsed = parseSize(value, allowingZero: true) else {
                throw invalidOption(
                    driver: descriptor.driver,
                    name: "max-buffer-size",
                    reason: "expected a valid byte size"
                )
            }
            maxBufferSize = parsed
        } else {
            maxBufferSize = nil
        }
        return try LogDeliveryConfiguration(
            requestedMode: requestedMode,
            maxBufferSizeInBytes: maxBufferSize
        )
    }

    private static func readPolicy(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> LogReadPolicy {
        if descriptor.capabilities.nativeRead {
            return try LogReadPolicy(source: .direct)
        }
        guard descriptor.capabilities.supportsDualCache else {
            return try LogReadPolicy(source: .unavailable)
        }

        let disabled = try cacheBoolean(
            name: "cache-disabled",
            options: options,
            defaultValue: false,
            driver: descriptor.driver
        )
        guard !disabled else {
            return try LogReadPolicy(source: .unavailable)
        }
        // Docker Engine 29.2.1 retains these three cache-prefixed values but
        // does not pass them to the local cache parser. Preserve the exact
        // request in safeOptions while applying the engine's fixed defaults.
        return try LogReadPolicy(
            source: .dualCache,
            cache: LogCacheConfiguration(
                maxSizeInBytes: defaultCacheMaxSizeInBytes,
                maxFileCount: defaultCacheMaxFileCount,
                compress: defaultCacheCompress
            )
        )
    }

    private static func validateCacheOption(name: String, value: String, driver: String) throws {
        switch name {
        case "cache-disabled":
            guard value.isEmpty || parseBoolean(value) != nil else {
                throw invalidOption(driver: driver, name: name, reason: "expected a boolean")
            }
        case "cache-compress", "cache-max-file", "cache-max-size":
            return
        default:
            preconditionFailure("unhandled cache option contract")
        }
    }

    private static func cacheBoolean(
        name: String,
        options: [String: String],
        defaultValue: Bool,
        driver: String
    ) throws -> Bool {
        guard let value = options[name] else {
            return defaultValue
        }
        if value.isEmpty {
            return false
        }
        guard let parsed = parseBoolean(value) else {
            throw invalidOption(driver: driver, name: name, reason: "expected a boolean")
        }
        return parsed
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "1", "t", "T", "TRUE", "true", "True": true
        case "0", "f", "F", "FALSE", "false", "False": false
        default: nil
        }
    }

    private static func parseSize(_ input: String, allowingZero: Bool) -> UInt64? {
        guard let separator = input.lastIndex(where: isDockerSizeSeparator) else {
            return nil
        }

        let numberText: Substring
        let suffixText: Substring
        if input[separator] == " " {
            numberText = input[..<separator]
            suffixText = input[input.index(after: separator)...]
        } else {
            numberText = input[...separator]
            suffixText = input[input.index(after: separator)...]
        }
        guard
            let number = parseGoFloat(String(numberText)),
            number.isFinite,
            allowingZero ? number >= 0 : number > 0
        else {
            return nil
        }

        let suffix = suffixText.lowercased()
        guard suffix.utf8.count <= 3 else {
            return nil
        }

        let multiplier: Double
        switch suffix {
        case "", "b":
            multiplier = 1
        case "k", "kb", "kib":
            multiplier = 1024
        case "m", "mb", "mib":
            multiplier = 1024 * 1024
        case "g", "gb", "gib":
            multiplier = 1024 * 1024 * 1024
        case "t", "tb", "tib":
            multiplier = 1024 * 1024 * 1024 * 1024
        case "p", "pb", "pib":
            multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default:
            return nil
        }
        let bytes = number * multiplier
        // go-units returns int64. Keep the conversion below 2^63 because
        // Double(Int64.max) rounds up to that boundary.
        guard bytes.isFinite, bytes < 9_223_372_036_854_775_808 else {
            return nil
        }
        let result = UInt64(Int64(bytes))
        guard allowingZero || result > 0 else {
            return nil
        }
        return result
    }

    private static func isDockerSizeSeparator(_ character: Character) -> Bool {
        character == "." || character == " " || character.wholeNumberValue != nil
    }

    private static func parseGoFloat(_ input: String) -> Double? {
        guard input.contains("_") else {
            return Double(input)
        }

        let characters = Array(input)
        guard characters.first != "_", characters.last != "_" else {
            return nil
        }
        let isHex = input.drop(while: { $0 == "+" || $0 == "-" }).lowercased().hasPrefix("0x")
        for index in characters.indices where characters[index] == "_" {
            guard index > characters.startIndex, index < characters.index(before: characters.endIndex) else {
                return nil
            }
            let previous = characters[characters.index(before: index)]
            let next = characters[characters.index(after: index)]
            let validPrevious = isASCIIDigit(previous) || (isHex && (isASCIIHexDigit(previous) || previous.lowercased() == "x"))
            let validNext = isASCIIDigit(next) || (isHex && isASCIIHexDigit(next))
            guard validPrevious, validNext else {
                return nil
            }
        }
        return Double(input.replacingOccurrences(of: "_", with: ""))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        isASCIIDigit(character)
            || (character.lowercased() >= "a" && character.lowercased() <= "f")
    }

    private static func invalidOption(
        driver: String,
        name: String,
        reason: String
    ) -> ContainerLogResolutionError {
        .invalidOption(driver: driver, name: name, reason: reason)
    }
}
