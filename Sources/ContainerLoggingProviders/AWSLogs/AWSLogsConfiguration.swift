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
import DockerSemanticHelper
import Foundation

public enum AWSLogsProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case missingLogGroup
    case invalidBoolean(option: String, value: String)
    case invalidPositiveInteger(option: String, value: String)
    case conflictingMultilineOptions
    case invalidLogFormat(String)
    case logFormatConflictsWithMultiline
    case invalidMultilinePattern(String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case cannotDetermineRegion
    case credentialsEndpointFailed
    case invalidConnectionPolicy
    case createLogGroupFailed
    case createLogStreamFailed
    case transportClosed
    case closeTimedOut
    case flushTimedOut
    case invalidProviderIdentity
    case idempotencyConflict
    case invalidEffectToken
    case invalidSessionFence
    case readUnsupported
}

public struct AWSLogsConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                forceFlushInterval: .seconds(5),
                maximumBufferedEvents: 4_096,
                maximumCreationBackoff: .seconds(32),
                closeTimeout: .seconds(30)
            )
        } catch {
            preconditionFailure("invalid built-in awslogs policy: \(error)")
        }
    }()

    public let forceFlushInterval: Duration
    public let maximumBufferedEvents: Int
    public let maximumCreationBackoff: Duration
    public let closeTimeout: Duration

    public init(
        forceFlushInterval: Duration,
        maximumBufferedEvents: Int,
        maximumCreationBackoff: Duration,
        closeTimeout: Duration
    ) throws {
        guard
            forceFlushInterval > .zero,
            maximumBufferedEvents > 0,
            maximumCreationBackoff >= .seconds(1),
            closeTimeout > .zero
        else {
            throw AWSLogsProviderError.invalidConnectionPolicy
        }
        self.forceFlushInterval = forceFlushInterval
        self.maximumBufferedEvents = maximumBufferedEvents
        self.maximumCreationBackoff = maximumCreationBackoff
        self.closeTimeout = closeTimeout
    }
}

public typealias AWSLogsContainerInfo = SyslogContainerInfo

public struct AWSLogsDriverConfiguration: Equatable, Sendable {
    public static let maximumTagUTF8Bytes =
        ContainerLogRequest.maximumEncodedTransportBytes

    public let region: String?
    public let endpoint: String?
    public let logGroup: String
    public let logStream: String
    public let createGroup: Bool
    public let createStream: Bool
    public let multilinePattern: String?
    public let credentialsEndpointURI: String?
    public let logFormat: String?
    public let nonBlocking: Bool
    public let policy: AWSLogsConnectionPolicy

    public init(
        region: String?,
        endpoint: String?,
        logGroup: String,
        logStream: String,
        createGroup: Bool,
        createStream: Bool,
        multilinePattern: String?,
        credentialsEndpointURI: String?,
        logFormat: String?,
        nonBlocking: Bool,
        policy: AWSLogsConnectionPolicy
    ) throws {
        guard !logGroup.isEmpty else {
            throw AWSLogsProviderError.missingLogGroup
        }
        guard logStream.utf8.count <= Self.maximumTagUTF8Bytes else {
            throw AWSLogsProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        }
        self.region = region
        self.endpoint = endpoint
        self.logGroup = logGroup
        self.logStream = logStream
        self.createGroup = createGroup
        self.createStream = createStream
        self.multilinePattern = multilinePattern
        self.credentialsEndpointURI = credentialsEndpointURI
        self.logFormat = logFormat
        self.nonBlocking = nonBlocking
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: AWSLogsContainerInfo,
        semanticService: any DockerSemanticServicing,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        basePolicy: AWSLogsConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: {
            !knownOptionNames.contains($0)
        }) {
            throw AWSLogsProviderError.unknownOption(unknown)
        }
        guard let group = options["awslogs-group"], !group.isEmpty else {
            throw AWSLogsProviderError.missingLogGroup
        }

        let hasDateTime = options["awslogs-datetime-format"] != nil
        let hasPattern = options["awslogs-multiline-pattern"] != nil
        guard !(hasDateTime && hasPattern) else {
            throw AWSLogsProviderError.conflictingMultilineOptions
        }

        let format = options["awslogs-format"].flatMap { $0.isEmpty ? nil : $0 }
        if let format, format != "json/emf" {
            throw AWSLogsProviderError.invalidLogFormat(format)
        }
        if format != nil && (hasDateTime || hasPattern) {
            throw AWSLogsProviderError.logFormatConflictsWithMultiline
        }

        let pattern: String?
        if let dateTime = options["awslogs-datetime-format"], !dateTime.isEmpty {
            pattern = strftimeRegularExpression(dateTime)
        } else if let requested = options["awslogs-multiline-pattern"], !requested.isEmpty {
            pattern = requested
        } else {
            pattern = nil
        }
        if let pattern {
            do {
                _ = try semanticService.matchRegularExpression(
                    pattern: Data(pattern.utf8),
                    candidates: [],
                    timeout: .seconds(2)
                )
            } catch let error as DockerSemanticHelperRemoteError
                where error.category == .parse
            {
                throw AWSLogsProviderError.invalidMultilinePattern(pattern)
            }
        }

        let forceFlushSeconds = try positiveInteger(
            options["awslogs-force-flush-interval-seconds"],
            option: "awslogs-force-flush-interval-seconds",
            defaultValue: 5
        )
        let maximumBufferedEvents = try positiveInteger(
            options["awslogs-max-buffered-events"],
            option: "awslogs-max-buffered-events",
            defaultValue: 4_096
        )
        let policy = try AWSLogsConnectionPolicy(
            forceFlushInterval: .seconds(forceFlushSeconds),
            maximumBufferedEvents: maximumBufferedEvents,
            maximumCreationBackoff: basePolicy.maximumCreationBackoff,
            closeTimeout: basePolicy.closeTimeout
        )
        let stream = try resolveStream(
            options: options,
            info: info,
            semanticService: semanticService
        )
        return try Self(
            region: nonEmpty(options["awslogs-region"])
                ?? nonEmpty(environment["AWS_REGION"]),
            endpoint: nonEmpty(options["awslogs-endpoint"]),
            logGroup: group,
            logStream: stream,
            createGroup: try boolean(
                options["awslogs-create-group"],
                option: "awslogs-create-group",
                defaultValue: false
            ),
            createStream: try boolean(
                options["awslogs-create-stream"],
                option: "awslogs-create-stream",
                defaultValue: true
            ),
            multilinePattern: pattern,
            credentialsEndpointURI:
                options.keys.contains("awslogs-credentials-endpoint")
                ? options["awslogs-credentials-endpoint"] : nil,
            logFormat: format,
            nonBlocking: options["mode"] == "non-blocking",
            policy: policy
        )
    }

    public static let knownOptionNames: Set<String> = [
        "awslogs-create-group",
        "awslogs-create-stream",
        "awslogs-credentials-endpoint",
        "awslogs-datetime-format",
        "awslogs-endpoint",
        "awslogs-force-flush-interval-seconds",
        "awslogs-format",
        "awslogs-group",
        "awslogs-max-buffered-events",
        "awslogs-multiline-pattern",
        "awslogs-region",
        "awslogs-stream",
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
        "max-buffer-size",
        "mode",
        "tag",
    ]

    private static func resolveStream(
        options: [String: String],
        info: AWSLogsContainerInfo,
        semanticService: any DockerSemanticServicing
    ) throws -> String {
        if let explicit = options["awslogs-stream"], !explicit.isEmpty {
            return explicit
        }
        let template = options["tag"] ?? "{{.FullID}}"
        guard template.utf8.count <= maximumTagUTF8Bytes else {
            throw AWSLogsProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        }
        do {
            let rendered = try semanticService.renderLogTemplate(
                template: Data(template.utf8),
                info: info.dockerTemplateInfo,
                configuration: options.map {
                    DockerSemanticBytePair(key: $0.key, value: $0.value)
                },
                timeout: .seconds(2)
            )
            guard let stream = String(data: rendered, encoding: .utf8) else {
                throw AWSLogsProviderError.invalidTagTemplate(template)
            }
            return stream
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .outputLimit
        {
            throw AWSLogsProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw AWSLogsProviderError.invalidTagTemplate(template)
        }
    }

    private static func boolean(
        _ value: String?,
        option: String,
        defaultValue: Bool
    ) throws -> Bool {
        guard let value, !value.isEmpty else {
            return defaultValue
        }
        guard let parsed = ContainerLogOptionValueParser.boolean(value) else {
            throw AWSLogsProviderError.invalidBoolean(
                option: option,
                value: value
            )
        }
        return parsed
    }

    private static func positiveInteger(
        _ value: String?,
        option: String,
        defaultValue: Int
    ) throws -> Int {
        guard let value, !value.isEmpty else {
            return defaultValue
        }
        guard
            !value.hasPrefix("+"),
            let parsed = Int(value),
            parsed > 0
        else {
            throw AWSLogsProviderError.invalidPositiveInteger(
                option: option,
                value: value
            )
        }
        return parsed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func strftimeRegularExpression(_ format: String) -> String {
        let table = [
            "%a": "(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)",
            "%A": "(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)",
            "%w": "[0-6]",
            "%d": "(?:0[1-9]|[1,2][0-9]|3[0,1])",
            "%b": "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)",
            "%B": "(?:January|February|March|April|May|June|July|August|September|October|November|December)",
            "%m": "(?:0[1-9]|1[0-2])",
            "%Y": "\\d{4}",
            "%y": "\\d{2}",
            "%H": "(?:[0,1][0-9]|2[0-3])",
            "%I": "(?:0[0-9]|1[0-2])",
            "%p": "[A,P]M",
            "%M": "[0-5][0-9]",
            "%S": "[0-5][0-9]",
            "%f": "\\d{6}",
            "%z": "[+-]\\d{4}",
            "%Z": "[A-Z]{1,4}T",
            "%j": "(?:0[0-9][1-9]|[1,2][0-9][0-9]|3[0-5][0-9]|36[0-6])",
            "%L": "\\.\\d{3}",
        ]
        var result = ""
        var index = format.startIndex
        while index < format.endIndex {
            if format[index] == "%" {
                let next = format.index(after: index)
                if next < format.endIndex {
                    let end = format.index(after: next)
                    result += table[String(format[index..<end])] ?? ""
                    index = end
                    continue
                }
            }
            result.append(format[index])
            index = format.index(after: index)
        }
        return result
    }
}
