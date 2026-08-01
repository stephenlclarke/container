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
import ContainerRuntimeClient
import Containerization
import Foundation

package enum ContainerLogRuntimePlanError: Error, Equatable, Sendable {
    case incompleteConfiguration
    case invalidContract
    case invalidOption(String)
    case unsupportedDriver(String)
}

/// A pure, start-time-validated plan for the core logging implementations.
///
/// Construction performs no filesystem, network, or VM mutation. Activation is
/// deliberately separate so the lower runtime repeats the authority contract
/// fence before allocating a process generation or opening a canonical store.
package enum ContainerLogRuntimePlan: Sendable {
    case legacy(maximumFileSize: UInt64?, maximumFileCount: Int?)
    case none
    case jsonFile(
        configuration: DockerJSONFileLogConfiguration,
        delivery: LogDeliveryConfiguration,
        attributes: [String: String]
    )
    case local(
        configuration: NativeLocalLogConfiguration,
        delivery: LogDeliveryConfiguration,
        attributes: [String: String]
    )

    private static let cacheOptionNames: Set<String> = [
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
    ]

    package init(configuration: ContainerConfiguration) throws {
        let logging = configuration.logging
        if logging.isLegacy {
            switch logging.storage {
            case .local:
                self = .legacy(
                    maximumFileSize: logging.maxSizeInBytes,
                    maximumFileCount: logging.maxFileCount
                )
            case .none:
                self = .none
            }
            return
        }

        guard
            let requested = logging.requested,
            let resolved = logging.resolved,
            resolved.leaseGeneration > 0,
            let descriptor = BuiltinLogDriverDescriptors.current.descriptor(named: resolved.driver),
            descriptor.driver == resolved.driver,
            descriptor.providerIdentity == resolved.providerIdentity,
            descriptor.providerGeneration == resolved.providerGenerationAtResolution,
            descriptor.optionContractDigest == resolved.contractDigest
        else {
            throw ContainerLogRuntimePlanError.incompleteConfiguration
        }
        if let requestedDriver = requested.driver, !requestedDriver.isEmpty {
            guard
                BuiltinLogDriverDescriptors.current.descriptor(named: requestedDriver)?.driver
                    == resolved.driver
            else {
                throw ContainerLogRuntimePlanError.invalidContract
            }
        }

        switch resolved.driver {
        case "none":
            guard
                resolved.delivery == (try LogDeliveryConfiguration()),
                resolved.readPolicy == (try LogReadPolicy(source: .unavailable))
            else {
                throw ContainerLogRuntimePlanError.invalidContract
            }
            self = .none

        case "json-file", "local":
            guard
                resolved.protectedOptionNames.isEmpty,
                resolved.protectedOptionReference == nil,
                resolved.readPolicy == (try LogReadPolicy(source: .direct))
            else {
                throw ContainerLogRuntimePlanError.invalidContract
            }
            let options = resolved.safeOptions
            try Self.validateFileOptions(options, descriptor: descriptor)
            guard
                resolved.delivery
                    == (try Self.deliveryConfiguration(options: options))
            else {
                throw ContainerLogRuntimePlanError.invalidContract
            }
            let attributes = try Self.selectedAttributes(
                options: options,
                labels: configuration.labels,
                environment: configuration.initProcess.environment
            )
            let maximumFileCount = try Self.maximumFileCount(
                options: options,
                descriptor: descriptor
            )
            let compress = try Self.compress(options: options, descriptor: descriptor)

            if resolved.driver == "json-file" {
                let maximumFileSize = try Self.maximumFileSize(
                    options: options,
                    descriptor: descriptor
                )
                self = .jsonFile(
                    configuration: try DockerJSONFileLogConfiguration(
                        maximumFileSize: maximumFileSize,
                        maximumFileCount: maximumFileCount,
                        compress: compress
                    ),
                    delivery: resolved.delivery,
                    attributes: attributes
                )
            } else {
                guard
                    let maximumFileSize = try Self.maximumFileSize(
                        options: options,
                        descriptor: descriptor
                    )
                else {
                    throw ContainerLogRuntimePlanError.invalidContract
                }
                self = .local(
                    configuration: try NativeLocalLogConfiguration(
                        maximumFileSize: maximumFileSize,
                        maximumFileCount: maximumFileCount,
                        compress: compress
                    ),
                    delivery: resolved.delivery,
                    attributes: attributes
                )
            }

        default:
            // Provider-backed drivers are activated by the provider controller,
            // never silently collapsed onto a core file writer.
            throw ContainerLogRuntimePlanError.unsupportedDriver(resolved.driver)
        }
    }

    package func activate(
        bundle: ContainerResource.Bundle,
        terminal: Bool
    ) throws -> ContainerLogRuntimeCapture {
        switch self {
        case .legacy(let maximumFileSize, let maximumFileCount):
            try bundle.createLegacyLogFiles()
            let writer = try ContainerLogFileWriter(
                rawLogURL: bundle.containerLog,
                recordLogURL: bundle.containerLogRecords,
                maxSizeInBytes: maximumFileSize,
                maxFileCount: maximumFileCount
            )
            return ContainerLogRuntimeCapture(
                stdout: writer.writer(for: .stdout),
                stderr: terminal ? nil : writer.writer(for: .stderr),
                session: nil,
                publicLogPath: bundle.containerLog
            )

        case .none:
            return ContainerLogRuntimeCapture(
                stdout: nil,
                stderr: nil,
                session: nil,
                publicLogPath: nil
            )

        case .jsonFile(let configuration, let delivery, let attributes):
            let generation = try Self.allocateProcessGeneration(bundle: bundle)
            let store = try DockerJSONFileLogStore(
                directoryURL: bundle.containerJSONFileLogDirectory,
                activeFileName: ContainerResource.Bundle.jsonFileLogName,
                configuration: configuration
            )
            return try Self.capture(
                destination: store,
                delivery: delivery,
                terminal: terminal,
                processGeneration: generation,
                attributes: attributes,
                publicLogPath: store.logURL
            )

        case .local(let configuration, let delivery, let attributes):
            let generation = try Self.allocateProcessGeneration(bundle: bundle)
            let store = try NativeLocalLogStore(
                directoryURL: bundle.containerNativeLocalLogDirectory,
                activeFileName: ContainerResource.Bundle.nativeLocalLogName,
                configuration: configuration
            )
            return try Self.capture(
                destination: store,
                delivery: delivery,
                terminal: terminal,
                processGeneration: generation,
                attributes: attributes,
                publicLogPath: nil
            )
        }
    }

    private static func capture(
        destination: any ContainerLogRecordDestination,
        delivery: LogDeliveryConfiguration,
        terminal: Bool,
        processGeneration: UInt64,
        attributes: [String: String],
        publicLogPath: URL?
    ) throws -> ContainerLogRuntimeCapture {
        let streams: Set<ContainerLogStream> = terminal ? [.stdout] : [.stdout, .stderr]
        let session = try ContainerLogRecordSession(
            destination: destination,
            deliveryConfiguration: delivery,
            streams: streams,
            processGeneration: processGeneration,
            attributes: attributes
        )
        return ContainerLogRuntimeCapture(
            stdout: session.writer(for: .stdout),
            stderr: terminal ? nil : session.writer(for: .stderr),
            session: session,
            publicLogPath: publicLogPath
        )
    }

    private static func allocateProcessGeneration(
        bundle: ContainerResource.Bundle
    ) throws -> UInt64 {
        try ContainerLogProcessGenerationStore(directoryURL: bundle.containerLoggingV2).next()
    }

    private static func validateFileOptions(
        _ options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws {
        let declared = Dictionary(uniqueKeysWithValues: descriptor.options.map { ($0.name, $0) })
        for (name, value) in options {
            guard let option = declared[name] else {
                guard cacheOptionNames.contains(name) else {
                    throw ContainerLogRuntimePlanError.invalidOption(name)
                }
                continue
            }
            if !option.allowedValues.isEmpty, !option.allowedValues.contains(value) {
                throw ContainerLogRuntimePlanError.invalidOption(name)
            }
            switch option.valueKind {
            case .string, .commaSeparatedNames, .tagTemplate:
                break
            case .boolean:
                guard ContainerLogOptionValueParser.boolean(value) != nil else {
                    throw ContainerLogRuntimePlanError.invalidOption(name)
                }
            case .positiveInteger:
                guard let parsed = Int(value), parsed > 0 else {
                    throw ContainerLogRuntimePlanError.invalidOption(name)
                }
            case .size:
                let parsed =
                    if name == "max-size" {
                        ContainerLogOptionValueParser.humanSizeInBytes(
                            value,
                            allowingZero: false
                        )
                    } else {
                        ContainerLogOptionValueParser.ramSizeInBytes(
                            value,
                            allowingZero: name == "max-buffer-size"
                        )
                    }
                guard
                    parsed != nil
                else {
                    throw ContainerLogRuntimePlanError.invalidOption(name)
                }
            case .regularExpression:
                do {
                    _ = try Regex(value)
                } catch {
                    throw ContainerLogRuntimePlanError.invalidOption(name)
                }
            }
        }

        if options["max-buffer-size"] != nil, options["mode"] != "non-blocking" {
            throw ContainerLogRuntimePlanError.invalidOption("max-buffer-size")
        }
    }

    private static func deliveryConfiguration(
        options: [String: String]
    ) throws -> LogDeliveryConfiguration {
        let mode: LogDeliveryConfiguration.Mode?
        if let value = options["mode"], !value.isEmpty {
            guard let parsed = LogDeliveryConfiguration.Mode(rawValue: value) else {
                throw ContainerLogRuntimePlanError.invalidOption("mode")
            }
            mode = parsed
        } else {
            mode = nil
        }
        let maximumBufferSize: UInt64?
        if let value = options["max-buffer-size"] {
            guard let parsed = ContainerLogOptionValueParser.ramSizeInBytes(value, allowingZero: true) else {
                throw ContainerLogRuntimePlanError.invalidOption("max-buffer-size")
            }
            maximumBufferSize = parsed
        } else {
            maximumBufferSize = nil
        }
        return try LogDeliveryConfiguration(
            requestedMode: mode,
            maxBufferSizeInBytes: maximumBufferSize
        )
    }

    private static func maximumFileSize(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> UInt64? {
        if let value = options["max-size"] {
            guard let parsed = ContainerLogOptionValueParser.humanSizeInBytes(value, allowingZero: false) else {
                throw ContainerLogRuntimePlanError.invalidOption("max-size")
            }
            return parsed
        }
        return descriptor.capabilities.fileDefaults?.maxSizeInBytes
    }

    private static func maximumFileCount(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> Int {
        if let value = options["max-file"] {
            guard let parsed = Int(value), parsed > 0 else {
                throw ContainerLogRuntimePlanError.invalidOption("max-file")
            }
            return parsed
        }
        guard let value = descriptor.capabilities.fileDefaults?.maxFileCount else {
            throw ContainerLogRuntimePlanError.invalidContract
        }
        return value
    }

    private static func compress(
        options: [String: String],
        descriptor: LogDriverDescriptor
    ) throws -> Bool {
        if let value = options["compress"] {
            guard let parsed = ContainerLogOptionValueParser.boolean(value) else {
                throw ContainerLogRuntimePlanError.invalidOption("compress")
            }
            return parsed
        }
        return descriptor.capabilities.fileDefaults?.compress ?? false
    }

    private static func selectedAttributes(
        options: [String: String],
        labels: [String: String],
        environment: [String]
    ) throws -> [String: String] {
        var selected: [String: String] = [:]
        selectExact(options["labels"], from: labels, into: &selected)
        try selectRegex(options["labels-regex"], from: labels, into: &selected)

        var environmentValues: [String: String] = [:]
        for entry in environment {
            if let separator = entry.firstIndex(of: "=") {
                environmentValues[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
            } else {
                environmentValues[entry] = ""
            }
        }
        // Docker gives selected environment values precedence over labels with
        // the same key.
        selectExact(options["env"], from: environmentValues, into: &selected)
        try selectRegex(options["env-regex"], from: environmentValues, into: &selected)

        guard selected.count <= ContainerLogRecordV2.maximumAttributeCount else {
            throw ContainerLogRuntimePlanError.invalidOption("attributes")
        }
        var byteCount = 0
        for (key, value) in selected {
            let (entry, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
            let (total, totalOverflow) = byteCount.addingReportingOverflow(entry)
            guard
                !entryOverflow,
                !totalOverflow,
                total <= ContainerLogRecordV2.maximumAttributeUTF8Bytes
            else {
                throw ContainerLogRuntimePlanError.invalidOption("attributes")
            }
            byteCount = total
        }
        return selected
    }

    private static func selectExact(
        _ names: String?,
        from source: [String: String],
        into selected: inout [String: String]
    ) {
        guard let names else {
            return
        }
        for name in names.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            if let value = source[name] {
                selected[name] = value
            }
        }
    }

    private static func selectRegex(
        _ pattern: String?,
        from source: [String: String],
        into selected: inout [String: String]
    ) throws {
        guard let pattern else {
            return
        }
        let regex: Regex<AnyRegexOutput>
        do {
            regex = try Regex(pattern)
        } catch {
            throw ContainerLogRuntimePlanError.invalidOption("metadata-regex")
        }
        for (name, value) in source where name.firstMatch(of: regex) != nil {
            selected[name] = value
        }
    }
}

package struct ContainerLogRuntimeCapture: @unchecked Sendable {
    package let stdout: (any Writer)?
    package let stderr: (any Writer)?
    package let session: ContainerLogRecordSession?
    package let publicLogPath: URL?

    package func close() {
        try? stdout?.close()
        try? stderr?.close()
    }
}
