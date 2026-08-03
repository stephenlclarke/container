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

public enum SplunkProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case missingURL
    case missingToken
    case malformedURL(String)
    case invalidBoolean(option: String, value: String)
    case invalidFormat(String)
    case invalidGzipLevel(String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case invalidMetadataRegularExpression(option: String, value: String)
    case invalidConnectionPolicy
    case certificateReadFailed
    case certificateInvalid
    case requestTimedOut
    case connectionFailed
    case verificationFailed(statusCode: Int)
    case deliveryFailed(statusCode: Int)
    case responseBodyTooLarge(maximumBytes: Int)
    case recordPayloadTooLarge(maximumBytes: Int)
    case gzipFailed
    case transportClosed
    case closeTimedOut
    case flushTimedOut
    case invalidProviderIdentity
    case idempotencyConflict
    case invalidEffectToken
    case invalidSessionFence
    case readUnsupported
}

public struct SplunkEndpoint: Equatable, Sendable {
    public let baseURL: String
    public let eventURL: String
    public let usesTLS: Bool

    public init(_ requestedURL: String) throws {
        guard !requestedURL.isEmpty else {
            throw SplunkProviderError.missingURL
        }
        guard
            let components = URLComponents(string: requestedURL),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else {
            throw SplunkProviderError.malformedURL(requestedURL)
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.path = ""
        guard let baseURL = normalized.url?.absoluteString else {
            throw SplunkProviderError.malformedURL(requestedURL)
        }
        self.baseURL =
            baseURL.hasSuffix("/")
            ? String(baseURL.dropLast()) : baseURL
        self.eventURL = self.baseURL + "/services/collector/event/1.0"
        self.usesTLS = scheme == "https"
    }
}

public enum SplunkEventFormat: String, CaseIterable, Equatable, Sendable {
    case inline
    case json
    case raw
}

public struct SplunkTLSConfiguration: Equatable, Sendable {
    public let caCertificatePath: String?
    public let serverName: String?
    public let insecureSkipVerify: Bool

    public init(
        caCertificatePath: String?,
        serverName: String?,
        insecureSkipVerify: Bool
    ) {
        self.caCertificatePath = caCertificatePath
        self.serverName = serverName
        self.insecureSkipVerify = insecureSkipVerify
    }
}

public struct SplunkConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                postFrequency: .seconds(5),
                postBatchSize: 1_000,
                bufferMaximum: 10_000,
                streamCapacity: 4_000,
                requestTimeout: .seconds(30),
                closeTimeout: .seconds(30),
                maximumResponseBytes: 1_024
            )
        } catch {
            preconditionFailure("invalid built-in Splunk policy: \(error)")
        }
    }()

    public let postFrequency: Duration
    public let postBatchSize: Int
    public let bufferMaximum: Int
    public let streamCapacity: Int
    public let requestTimeout: Duration
    public let closeTimeout: Duration
    public let maximumResponseBytes: Int

    public init(
        postFrequency: Duration,
        postBatchSize: Int,
        bufferMaximum: Int,
        streamCapacity: Int,
        requestTimeout: Duration,
        closeTimeout: Duration,
        maximumResponseBytes: Int
    ) throws {
        guard
            postFrequency > .zero,
            postBatchSize > 0,
            bufferMaximum >= postBatchSize,
            streamCapacity >= 0,
            requestTimeout > .zero,
            closeTimeout > .zero,
            maximumResponseBytes > 0
        else {
            throw SplunkProviderError.invalidConnectionPolicy
        }
        self.postFrequency = postFrequency
        self.postBatchSize = postBatchSize
        self.bufferMaximum = bufferMaximum
        self.streamCapacity = streamCapacity
        self.requestTimeout = requestTimeout
        self.closeTimeout = closeTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public typealias SplunkContainerInfo = SyslogContainerInfo

public struct SplunkDriverConfiguration: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public static let maximumTagUTF8Bytes =
        ContainerLogRequest.maximumEncodedTransportBytes

    public let endpoint: SplunkEndpoint
    public let token: String
    public let source: String
    public let sourceType: String
    public let index: String
    public let format: SplunkEventFormat
    public let gzipEnabled: Bool
    public let gzipLevel: Int32
    public let indexAcknowledgement: Bool
    public let verifyConnection: Bool
    public let tag: String
    public let hostname: String
    public let metadata: [String: String]
    public let tls: SplunkTLSConfiguration?
    public let policy: SplunkConnectionPolicy

    public var description: String {
        "SplunkDriverConfiguration(format: \(format.rawValue), token: <redacted>, metadataCount: \(metadata.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "format": format.rawValue,
                "token": "<redacted>",
                "metadataCount": String(metadata.count),
            ],
            displayStyle: .struct
        )
    }

    public init(
        endpoint: SplunkEndpoint,
        token: String,
        source: String,
        sourceType: String,
        index: String,
        format: SplunkEventFormat,
        gzipEnabled: Bool,
        gzipLevel: Int32,
        indexAcknowledgement: Bool,
        verifyConnection: Bool,
        tag: String,
        hostname: String,
        metadata: [String: String],
        tls: SplunkTLSConfiguration?,
        policy: SplunkConnectionPolicy
    ) throws {
        guard !token.isEmpty else {
            throw SplunkProviderError.missingToken
        }
        guard (-1...9).contains(gzipLevel) else {
            throw SplunkProviderError.invalidGzipLevel(String(gzipLevel))
        }
        guard tag.utf8.count <= Self.maximumTagUTF8Bytes else {
            throw SplunkProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        }
        guard endpoint.usesTLS == (tls != nil) else {
            throw SplunkProviderError.invalidConnectionPolicy
        }
        self.endpoint = endpoint
        self.token = token
        self.source = source
        self.sourceType = sourceType
        self.index = index
        self.format = format
        self.gzipEnabled = gzipEnabled
        self.gzipLevel = gzipLevel
        self.indexAcknowledgement = indexAcknowledgement
        self.verifyConnection = verifyConnection
        self.tag = tag
        self.hostname = hostname
        self.metadata = metadata
        self.tls = tls
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: SplunkContainerInfo,
        semanticService: any DockerSemanticServicing,
        policy: SplunkConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: {
            !knownOptionNames.contains($0)
        }) {
            throw SplunkProviderError.unknownOption(unknown)
        }
        let endpoint = try SplunkEndpoint(options["splunk-url"] ?? "")
        guard let token = options["splunk-token"] else {
            throw SplunkProviderError.missingToken
        }
        let formatValue = options["splunk-format"] ?? "inline"
        guard let format = SplunkEventFormat(rawValue: formatValue) else {
            throw SplunkProviderError.invalidFormat(formatValue)
        }
        let gzipEnabled = try boolean(
            options["splunk-gzip"],
            option: "splunk-gzip",
            defaultValue: false
        )
        let gzipLevel = try gzipLevel(options["splunk-gzip-level"])
        let verifyConnection = try boolean(
            options["splunk-verify-connection"],
            option: "splunk-verify-connection",
            defaultValue: true
        )
        let indexAcknowledgement = try boolean(
            options["splunk-index-acknowledgment"],
            option: "splunk-index-acknowledgment",
            defaultValue: false
        )
        let insecureSkipVerify = try boolean(
            options["splunk-insecureskipverify"],
            option: "splunk-insecureskipverify",
            defaultValue: false
        )
        let tag = try resolveTag(
            options: options,
            info: info,
            semanticService: semanticService
        )
        let metadata = try SplunkMetadata.resolve(
            options: options,
            info: info,
            semanticService: semanticService
        )
        let tls =
            endpoint.usesTLS
            ? SplunkTLSConfiguration(
                caCertificatePath: nonEmpty(options["splunk-capath"]),
                serverName: nonEmpty(options["splunk-caname"]),
                insecureSkipVerify: insecureSkipVerify
            )
            : nil
        return try Self(
            endpoint: endpoint,
            token: token,
            source: options["splunk-source"] ?? "",
            sourceType: options["splunk-sourcetype"] ?? "",
            index: options["splunk-index"] ?? "",
            format: format,
            gzipEnabled: gzipEnabled,
            gzipLevel: gzipLevel,
            indexAcknowledgement: indexAcknowledgement,
            verifyConnection: verifyConnection,
            tag: tag,
            hostname: info.hostname,
            metadata: metadata,
            tls: tls,
            policy: policy
        )
    }

    public static let knownOptionNames: Set<String> = [
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
        "env",
        "env-regex",
        "labels",
        "labels-regex",
        "max-buffer-size",
        "mode",
        "splunk-caname",
        "splunk-capath",
        "splunk-format",
        "splunk-gzip",
        "splunk-gzip-level",
        "splunk-index",
        "splunk-index-acknowledgment",
        "splunk-insecureskipverify",
        "splunk-source",
        "splunk-sourcetype",
        "splunk-token",
        "splunk-url",
        "splunk-verify-connection",
        "tag",
    ]

    private static func boolean(
        _ value: String?,
        option: String,
        defaultValue: Bool
    ) throws -> Bool {
        guard let value else {
            return defaultValue
        }
        guard let parsed = ContainerLogOptionValueParser.boolean(value) else {
            throw SplunkProviderError.invalidBoolean(
                option: option,
                value: value
            )
        }
        return parsed
    }

    private static func gzipLevel(_ value: String?) throws -> Int32 {
        guard let value else {
            return -1
        }
        guard
            !value.hasPrefix("+"),
            let level = Int32(value),
            (-1...9).contains(level)
        else {
            throw SplunkProviderError.invalidGzipLevel(value)
        }
        return level
    }

    private static func resolveTag(
        options: [String: String],
        info: SplunkContainerInfo,
        semanticService: any DockerSemanticServicing
    ) throws -> String {
        if options["tag"] == "" {
            return ""
        }
        let requested = options["tag"] ?? "{{.ID}}"
        guard requested.utf8.count <= maximumTagUTF8Bytes else {
            throw SplunkProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        }
        do {
            let rendered = try semanticService.renderLogTemplate(
                template: Data(requested.utf8),
                info: info.dockerTemplateInfo,
                configuration: options.map {
                    DockerSemanticBytePair(key: $0.key, value: $0.value)
                },
                timeout: .seconds(2)
            )
            guard let tag = String(data: rendered, encoding: .utf8) else {
                throw SplunkProviderError.invalidTagTemplate(requested)
            }
            return tag
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .outputLimit
        {
            throw SplunkProviderError.tagExceedsUTF8Limit(
                maximumBytes: maximumTagUTF8Bytes
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw SplunkProviderError.invalidTagTemplate(requested)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}

private enum SplunkMetadata {
    static func resolve(
        options: [String: String],
        info: SplunkContainerInfo,
        semanticService: any DockerSemanticServicing
    ) throws -> [String: String] {
        var result = [String: String]()
        addNamed(
            options["labels"] ?? "",
            values: info.containerLabels,
            to: &result
        )
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
        for name in names.split(separator: ",", omittingEmptySubsequences: false) {
            if let value = values[String(name)] {
                result[String(name)] = value
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
            throw SplunkProviderError.invalidMetadataRegularExpression(
                option: option,
                value: pattern
            )
        }
        guard matches.count == entries.count else {
            throw DockerSemanticHelperError.protocolViolation
        }
        for (entry, matches) in zip(entries, matches) where matches {
            result[entry.key] = entry.value
        }
    }
}
