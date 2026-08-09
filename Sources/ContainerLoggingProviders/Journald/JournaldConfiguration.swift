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
import Darwin
import DockerSemanticHelper
import Foundation

public enum JournaldProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case invalidMetadataRegularExpression(option: String, value: String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case invalidContainerIdentity
    case invalidProviderIdentity
    case idempotencyConflict
    case unknownSession
    case invalidEffectToken
    case invalidSessionFence
    case invalidJournalEntry
    case unsupportedJournalPriority(Int)
    case transportClosed
    case deadlineExceeded
}

public enum JournaldPriority: Int, Equatable, Sendable {
    case error = 3
    case informational = 6

    public init(stream: ContainerLogStream) {
        self = stream == .stderr ? .error : .informational
    }

    public var stream: ContainerLogStream {
        self == .error ? .stderr : .stdout
    }
}

public enum JournaldField {
    public static let message = "MESSAGE"
    public static let priority = "PRIORITY"
    public static let syslogIdentifier = "SYSLOG_IDENTIFIER"
    public static let syslogTimestamp = "SYSLOG_TIMESTAMP"
    public static let containerID = "CONTAINER_ID"
    public static let containerIDFull = "CONTAINER_ID_FULL"
    public static let containerName = "CONTAINER_NAME"
    public static let containerTag = "CONTAINER_TAG"
    public static let imageName = "IMAGE_NAME"
    public static let partialID = "CONTAINER_PARTIAL_ID"
    public static let partialOrdinal = "CONTAINER_PARTIAL_ORDINAL"
    public static let partialLast = "CONTAINER_PARTIAL_LAST"
    public static let partialMessage = "CONTAINER_PARTIAL_MESSAGE"
    public static let logEpoch = "CONTAINER_LOG_EPOCH"
    public static let logOrdinal = "CONTAINER_LOG_ORDINAL"

    public static let wellKnown: Set<String> = [
        message,
        "MESSAGE_ID",
        priority,
        "CODE_FILE",
        "CODE_LINE",
        "CODE_FUNC",
        "ERRNO",
        "SYSLOG_FACILITY",
        syslogIdentifier,
        "SYSLOG_PID",
        syslogTimestamp,
        containerName,
        containerID,
        containerIDFull,
        containerTag,
        imageName,
        partialID,
        partialOrdinal,
        partialLast,
        partialMessage,
        logEpoch,
        logOrdinal,
    ]
}

/// Immutable Docker metadata and selected attributes for one journald writer.
/// The Linux service owns journal persistence and receipt timestamps; this
/// value contains only the fields Moby supplies with every record.
public struct JournaldDriverConfiguration: Equatable, Sendable {
    public static let maximumTagUTF8Bytes = ContainerLogRequest.maximumEncodedTransportBytes
    public static let knownOptionNames: Set<String> = [
        "env",
        "env-regex",
        "labels",
        "labels-regex",
        "max-buffer-size",
        "mode",
        "tag",
    ]

    public let containerID: String
    public let fields: [String: String]

    public init(containerID: String, fields: [String: String]) throws {
        guard
            !containerID.isEmpty,
            fields[JournaldField.containerIDFull] == containerID,
            fields[JournaldField.containerID] == String(containerID.prefix(12)),
            fields[JournaldField.containerTag] != nil,
            fields[JournaldField.syslogIdentifier] != nil
        else {
            throw JournaldProviderError.invalidContainerIdentity
        }
        self.containerID = containerID
        self.fields = fields
    }

    public static func resolve(
        options: [String: String],
        info: SyslogContainerInfo,
        semanticService: any DockerSemanticServicing
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: { !knownOptionNames.contains($0) }) {
            throw JournaldProviderError.unknownOption(unknown)
        }
        guard !info.containerID.isEmpty else {
            throw JournaldProviderError.invalidContainerIdentity
        }

        let requestedTag = options["tag"] ?? ""
        guard requestedTag.utf8.count <= maximumTagUTF8Bytes else {
            throw JournaldProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        }
        let renderedTag: Data
        do {
            renderedTag = try semanticService.renderLogTemplate(
                template: Data(requestedTag.utf8),
                info: info.dockerTemplateInfo,
                configuration: options.map {
                    DockerSemanticBytePair(key: $0.key, value: $0.value)
                },
                timeout: .seconds(2)
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw JournaldProviderError.invalidTagTemplate(requestedTag)
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .outputLimit
        {
            throw JournaldProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        }
        guard
            renderedTag.count <= maximumTagUTF8Bytes,
            let tag = String(data: renderedTag, encoding: .utf8)
        else {
            throw JournaldProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        }

        var fields = [
            JournaldField.containerID: String(info.containerID.prefix(12)),
            JournaldField.containerIDFull: info.containerID,
            JournaldField.containerName: info.name,
            JournaldField.containerTag: tag,
            JournaldField.imageName: info.containerImageName,
            JournaldField.syslogIdentifier: tag,
        ]
        let attributes = try selectedAttributes(
            options: options,
            info: info,
            semanticService: semanticService
        )
        for key in attributes.keys.sorted() {
            if let value = attributes[key] {
                fields[sanitizeFieldName(key)] = value
            }
        }
        return try Self(containerID: info.containerID, fields: fields)
    }

    /// Moby's journald key modifier uppercases ASCII lowercase letters,
    /// replaces every other unsupported scalar with `_`, and removes leading
    /// underscores entirely.
    public static func sanitizeFieldName(_ source: String) -> String {
        var result = ""
        for scalar in source.unicodeScalars {
            let value: UnicodeScalar
            switch scalar.value {
            case 97...122:
                value = UnicodeScalar(scalar.value - 32)!
            case 65...90, 48...57, 95:
                value = scalar
            default:
                value = "_"
            }
            if result.isEmpty, value == "_" {
                continue
            }
            result.unicodeScalars.append(value)
        }
        return result
    }

    private static func selectedAttributes(
        options: [String: String],
        info: SyslogContainerInfo,
        semanticService: any DockerSemanticServicing
    ) throws -> [String: String] {
        var result = [String: String]()
        addNamed(options["labels"] ?? "", values: info.containerLabels, to: &result)
        try addMatching(
            options["labels-regex"] ?? "",
            option: "labels-regex",
            values: info.containerLabels,
            semanticService: semanticService,
            to: &result
        )

        var environment = [String: String]()
        for entry in info.containerEnvironment {
            guard let equals = entry.firstIndex(of: "=") else {
                continue
            }
            environment[String(entry[..<equals])] = String(
                entry[entry.index(after: equals)...]
            )
        }
        // Docker applies environment after labels, so it wins a same-name
        // selection before journald field-name sanitization.
        addNamed(options["env"] ?? "", values: environment, to: &result)
        try addMatching(
            options["env-regex"] ?? "",
            option: "env-regex",
            values: environment,
            semanticService: semanticService,
            to: &result
        )
        return result
    }

    private static func addNamed(
        _ names: String,
        values: [String: String],
        to result: inout [String: String]
    ) {
        guard !names.isEmpty else {
            return
        }
        for name in names.split(separator: ",", omittingEmptySubsequences: false) {
            let key = String(name)
            if let value = values[key] {
                result[key] = value
            }
        }
    }

    private static func addMatching(
        _ pattern: String,
        option: String,
        values: [String: String],
        semanticService: any DockerSemanticServicing,
        to result: inout [String: String]
    ) throws {
        guard !pattern.isEmpty else {
            return
        }
        let entries = values.sorted { $0.key < $1.key }
        let matches: [Bool]
        do {
            matches = try semanticService.matchRegularExpression(
                pattern: Data(pattern.utf8),
                candidates: entries.map { Data($0.key.utf8) },
                timeout: .seconds(2)
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse
        {
            throw JournaldProviderError.invalidMetadataRegularExpression(
                option: option,
                value: pattern
            )
        }
        guard matches.count == entries.count else {
            throw DockerSemanticHelperError.protocolViolation
        }
        for (entry, matched) in zip(entries, matches) where matched {
            result[entry.key] = entry.value
        }
    }
}

/// One binary-safe record at the protected Linux journal-service boundary.
public struct JournaldEntry: Equatable, Sendable {
    public let message: Data
    public let priority: JournaldPriority
    public let fields: [String: String]
    public let receivedTimestamp: ContainerLogTimestamp
    public let processGeneration: UInt64

    public init(
        message: Data,
        priority: JournaldPriority,
        fields: [String: String],
        receivedTimestamp: ContainerLogTimestamp,
        processGeneration: UInt64
    ) throws {
        guard
            !fields.keys.contains(where: { $0.isEmpty || $0.first == "_" }),
            fields[JournaldField.containerIDFull] != nil,
            fields[JournaldField.logEpoch] != nil,
            fields[JournaldField.logOrdinal] != nil,
            processGeneration > 0
        else {
            throw JournaldProviderError.invalidJournalEntry
        }
        self.message = message
        self.priority = priority
        self.fields = fields
        self.receivedTimestamp = receivedTimestamp
        self.processGeneration = processGeneration
    }

    public func readRecord(sequence: UInt64) throws -> ContainerLogReadRecordV1 {
        var presentation = message
        if fields[JournaldField.partialMessage] != "true" {
            presentation.append(UInt8(ascii: "\n"))
        }
        var attributes = [String: String]()
        for (key, value) in fields
        where key.first != "_" && !JournaldField.wellKnown.contains(key) {
            attributes[key] = value
        }
        return try ContainerLogReadRecordV1(
            stream: priority.stream,
            timestamp: receivedTimestamp,
            data: presentation,
            attributes: attributes,
            sequence: sequence,
            processGeneration: processGeneration
        )
    }
}

/// Stateful Moby 29.2.1 field projection for one writer generation.
public struct JournaldEntryEncoder: Sendable {
    public let epoch: String
    private let configuration: JournaldDriverConfiguration
    private var ordinal: UInt64 = 0

    public init(configuration: JournaldDriverConfiguration, epoch: String) throws {
        guard !epoch.isEmpty else {
            throw JournaldProviderError.invalidJournalEntry
        }
        self.configuration = configuration
        self.epoch = epoch
    }

    public mutating func encode(_ record: ContainerLogRecordV2) throws -> JournaldEntry {
        let next = ordinal.addingReportingOverflow(1)
        guard !next.overflow else {
            throw JournaldProviderError.invalidJournalEntry
        }
        ordinal = next.partialValue

        var fields = configuration.fields
        fields[JournaldField.logEpoch] = epoch
        fields[JournaldField.logOrdinal] = String(ordinal)
        fields[JournaldField.syslogTimestamp] = Self.rfc3339Nano(
            record.observation.wallClock
        )
        if let partial = record.partial {
            fields[JournaldField.partialID] = partial.id
            fields[JournaldField.partialOrdinal] = String(partial.ordinal)
            fields[JournaldField.partialLast] = String(partial.last)
            if !partial.last {
                fields[JournaldField.partialMessage] = "true"
            }
        }
        return try JournaldEntry(
            message: record.payload,
            priority: JournaldPriority(stream: record.stream),
            fields: fields,
            receivedTimestamp: record.observation.wallClock,
            processGeneration: record.processGeneration
        )
    }

    private static func rfc3339Nano(_ timestamp: ContainerLogTimestamp) -> String {
        var seconds = time_t(timestamp.secondsSinceUnixEpoch)
        var value = tm()
        guard gmtime_r(&seconds, &value) != nil else {
            return "1970-01-01T00:00:00Z"
        }
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            value.tm_year + 1900,
            value.tm_mon + 1,
            value.tm_mday,
            value.tm_hour,
            value.tm_min,
            value.tm_sec
        )
        guard timestamp.nanoseconds != 0 else {
            return base + "Z"
        }
        var fraction = String(format: "%09u", timestamp.nanoseconds)
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return base + "." + fraction + "Z"
    }
}
