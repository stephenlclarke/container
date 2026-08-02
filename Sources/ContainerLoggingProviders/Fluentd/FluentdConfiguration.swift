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

public enum FluentdProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case unsupportedAddressScheme(String)
    case malformedAddress(String)
    case invalidBoolean(option: String, value: String)
    case invalidSize(option: String, value: String)
    case invalidDuration(option: String, value: String)
    case valueOutOfRange(option: String, value: String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case invalidMetadataRegularExpression(option: String, value: String)
    case invalidConnectionPolicy
    case recordPayloadTooLarge(maximumBytes: Int)
    case bufferFull(limit: Int)
    case connectionTimedOut
    case writeTimedOut
    case readTimedOut
    case closeTimedOut
    case flushTimedOut
    case transportClosed
    case tlsIdentityVerificationFailed
    case acknowledgementTooLarge(maximumBytes: Int)
    case invalidAcknowledgement
    case acknowledgementMismatch(expected: String, actual: String)
    case connectionRetriesExhausted(attempts: Int)
    case writeRetriesExhausted(attempts: Int)
    case invalidProviderIdentity
    case idempotencyConflict
    case unknownSession
    case invalidEffectToken
    case invalidSessionFence
    case readUnsupported
}

public struct FluentdNetworkAddress: Equatable, Sendable {
    public let host: Data
    public let port: UInt16

    public init(host: Data, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init(host: String, port: UInt16) {
        self.init(host: Data(host.utf8), port: port)
    }
}

public enum FluentdEndpoint: Equatable, Sendable {
    case tcp(FluentdNetworkAddress)
    case tls(FluentdNetworkAddress)
    case unix(path: Data)

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 24_224

    public var usesTLS: Bool {
        if case .tls = self {
            return true
        }
        return false
    }

    public static func parse(
        _ requestedAddress: String,
        semanticService: any DockerSemanticServicing
    ) throws -> Self {
        let resolved: DockerFluentdAddress
        do {
            resolved = try semanticService.parseFluentdAddress(
                Data(requestedAddress.utf8),
                timeout: .seconds(2)
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw FluentdProviderError.malformedAddress(requestedAddress)
        }
        guard
            let networkProtocol = String(
                data: resolved.networkProtocol,
                encoding: .utf8
            )
        else {
            throw DockerSemanticHelperError.protocolViolation
        }
        let network = FluentdNetworkAddress(
            host: resolved.host,
            port: resolved.port
        )
        switch networkProtocol {
        case "tcp": return .tcp(network)
        case "tls": return .tls(network)
        case "unix": return .unix(path: resolved.path)
        default: throw DockerSemanticHelperError.protocolViolation
        }
    }

    fileprivate func defaultingFluentLoggerPort() throws -> Self {
        // Engine 29.2.1 (6bc6209) passes port zero to its vendored
        // fluent.New, which replaces it with the default Fluentd port.
        switch self {
        case .tcp(let address) where address.port == 0:
            return .tcp(
                FluentdNetworkAddress(
                    host: address.host,
                    port: Self.defaultPort
                )
            )
        case .tls(let address) where address.port == 0:
            return .tls(
                FluentdNetworkAddress(
                    host: address.host,
                    port: Self.defaultPort
                )
            )
        default:
            return self
        }
    }
}

public struct FluentdConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                connectTimeout: .seconds(3),
                closeTimeout: .seconds(5),
                maximumAcknowledgementBytes: 64 * 1024
            )
        } catch {
            preconditionFailure("invalid built-in fluentd connection policy: \(error)")
        }
    }()

    public let connectTimeout: Duration
    public let closeTimeout: Duration
    public let maximumAcknowledgementBytes: Int

    public init(
        connectTimeout: Duration,
        closeTimeout: Duration,
        maximumAcknowledgementBytes: Int
    ) throws {
        guard
            connectTimeout > .zero,
            closeTimeout > .zero,
            maximumAcknowledgementBytes > 0
        else {
            throw FluentdProviderError.invalidConnectionPolicy
        }
        self.connectTimeout = connectTimeout
        self.closeTimeout = closeTimeout
        self.maximumAcknowledgementBytes = maximumAcknowledgementBytes
    }
}

/// Fluentd uses the common Docker logger-template surface already maintained
/// for syslog. Keeping one evaluator prevents the same tag from resolving
/// differently between two built-in Docker drivers.
public typealias FluentdContainerInfo = SyslogContainerInfo

public struct FluentdDriverConfiguration: Equatable, Sendable {
    public static let defaultBufferLimit = 1024 * 1024
    public static let fluentLoggerZeroBufferLimit = 8 * 1024
    public static let defaultMaximumRetries = Int(Int32.max)
    public static let fluentLoggerZeroMaximumRetries = 13
    public static let defaultRetryWait: Duration = .seconds(1)
    public static let fluentLoggerZeroRetryWait: Duration = .milliseconds(500)
    public static let maximumReconnectWait: Duration = .seconds(60)
    public static let minimumAsyncReconnectInterval: Duration = .milliseconds(100)
    public static let maximumAsyncReconnectInterval: Duration = .seconds(10)
    public static let maximumTagUTF8Bytes = ContainerLogRequest.maximumEncodedTransportBytes

    public let endpoint: FluentdEndpoint
    public let async: Bool
    public let asyncReconnectInterval: Duration?
    public let bufferLimit: Int
    public let maximumRetries: Int
    public let retryWait: Duration
    public let requestAcknowledgement: Bool
    public let subSecondPrecision: Bool
    public let readTimeout: Duration?
    public let writeTimeout: Duration?
    public let tag: Data
    public let containerID: String
    public let containerName: String
    public let metadata: [String: String]
    public let policy: FluentdConnectionPolicy

    public init(
        endpoint: FluentdEndpoint,
        async: Bool,
        asyncReconnectInterval: Duration?,
        bufferLimit: Int,
        maximumRetries: Int,
        retryWait: Duration,
        requestAcknowledgement: Bool,
        subSecondPrecision: Bool,
        readTimeout: Duration?,
        writeTimeout: Duration?,
        tag: Data,
        containerID: String,
        containerName: String,
        metadata: [String: String],
        policy: FluentdConnectionPolicy
    ) throws {
        guard bufferLimit > 0, maximumRetries > 0 else {
            throw FluentdProviderError.valueOutOfRange(
                option: "fluentd internal policy",
                value: "non-positive"
            )
        }
        guard tag.count <= Self.maximumTagUTF8Bytes else {
            throw FluentdProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        }
        self.endpoint = try endpoint.defaultingFluentLoggerPort()
        self.async = async
        self.asyncReconnectInterval = asyncReconnectInterval
        self.bufferLimit = bufferLimit
        self.maximumRetries = maximumRetries
        self.retryWait = retryWait
        self.requestAcknowledgement = requestAcknowledgement
        self.subSecondPrecision = subSecondPrecision
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.tag = tag
        self.containerID = containerID
        self.containerName = containerName
        self.metadata = metadata
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: FluentdContainerInfo,
        semanticService: any DockerSemanticServicing,
        policy: FluentdConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: { !knownOptionNames.contains($0) }) {
            throw FluentdProviderError.unknownOption(unknown)
        }

        let endpoint = try FluentdEndpoint.parse(
            options["fluentd-address"] ?? "",
            semanticService: semanticService
        )
        let async = try boolean(
            options["fluentd-async"] ?? "",
            option: "fluentd-async",
            defaultValue: false
        )
        let reconnectInterval = try reconnectInterval(
            options["fluentd-async-reconnect-interval"] ?? ""
        )
        let bufferLimit = try bufferLimit(options["fluentd-buffer-limit"] ?? "")
        let maximumRetries = try maximumRetries(
            options["fluentd-max-retries"] ?? ""
        )
        let retryWait = try retryWait(options["fluentd-retry-wait"] ?? "")
        let requestAcknowledgement = try boolean(
            options["fluentd-request-ack"] ?? "",
            option: "fluentd-request-ack",
            defaultValue: false
        )
        let subSecondPrecision = try boolean(
            options["fluentd-sub-second-precision"] ?? "",
            option: "fluentd-sub-second-precision",
            defaultValue: false
        )
        let readTimeout = try optionalNonNegativeDuration(
            options["fluentd-read-timeout"] ?? "",
            option: "fluentd-read-timeout"
        )
        let writeTimeout = try optionalNonNegativeDuration(
            options["fluentd-write-timeout"] ?? "",
            option: "fluentd-write-timeout"
        )
        let requestedTag = options["tag"] ?? ""
        guard requestedTag.utf8.count <= Self.maximumTagUTF8Bytes else {
            throw FluentdProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        }
        let tag: Data
        do {
            tag = try semanticService.renderLogTemplate(
                template: Data(requestedTag.utf8),
                info: info.dockerTemplateInfo,
                configuration: options.map {
                    DockerSemanticBytePair(key: $0.key, value: $0.value)
                },
                timeout: .seconds(2)
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .outputLimit
        {
            throw FluentdProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw FluentdProviderError.invalidTagTemplate(requestedTag)
        }
        let metadata = try FluentdMetadata.resolve(
            options: options,
            info: info,
            semanticService: semanticService
        )

        return try Self(
            endpoint: endpoint,
            async: async,
            asyncReconnectInterval: reconnectInterval,
            bufferLimit: bufferLimit,
            maximumRetries: maximumRetries,
            retryWait: retryWait,
            requestAcknowledgement: requestAcknowledgement,
            subSecondPrecision: subSecondPrecision,
            readTimeout: readTimeout,
            writeTimeout: writeTimeout,
            tag: tag,
            containerID: info.containerID,
            containerName: info.containerName,
            metadata: metadata,
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
        "fluentd-address",
        "fluentd-async",
        "fluentd-async-reconnect-interval",
        "fluentd-buffer-limit",
        "fluentd-max-retries",
        "fluentd-read-timeout",
        "fluentd-request-ack",
        "fluentd-retry-wait",
        "fluentd-sub-second-precision",
        "fluentd-write-timeout",
        "labels",
        "labels-regex",
        "max-buffer-size",
        "mode",
        "tag",
    ]

    private static func boolean(
        _ value: String,
        option: String,
        defaultValue: Bool
    ) throws -> Bool {
        guard !value.isEmpty else {
            return defaultValue
        }
        guard let parsed = ContainerLogOptionValueParser.boolean(value) else {
            throw FluentdProviderError.invalidBoolean(option: option, value: value)
        }
        return parsed
    }

    private static func reconnectInterval(_ value: String) throws -> Duration? {
        guard !value.isEmpty else {
            return nil
        }
        let parsed = try FluentdGoDuration.parse(
            value,
            option: "fluentd-async-reconnect-interval"
        )
        guard parsed >= .zero else {
            throw FluentdProviderError.valueOutOfRange(
                option: "fluentd-async-reconnect-interval",
                value: value
            )
        }
        guard parsed != .zero else {
            return nil
        }
        guard
            parsed >= minimumAsyncReconnectInterval,
            parsed <= maximumAsyncReconnectInterval
        else {
            throw FluentdProviderError.valueOutOfRange(
                option: "fluentd-async-reconnect-interval",
                value: value
            )
        }
        return .milliseconds(parsed.wholeMillisecondsTowardZero)
    }

    private static func bufferLimit(_ value: String) throws -> Int {
        guard !value.isEmpty else {
            return defaultBufferLimit
        }
        guard
            let bytes = ContainerLogOptionValueParser.ramSizeInBytes(
                value,
                allowingZero: true
            )
        else {
            throw FluentdProviderError.invalidSize(
                option: "fluentd-buffer-limit",
                value: value
            )
        }
        guard bytes <= UInt64(Int.max) else {
            throw FluentdProviderError.valueOutOfRange(
                option: "fluentd-buffer-limit",
                value: value
            )
        }
        let parsed = Int(bytes)
        return parsed == 0 ? fluentLoggerZeroBufferLimit : parsed
    }

    private static func maximumRetries(_ value: String) throws -> Int {
        guard !value.isEmpty else {
            return defaultMaximumRetries
        }
        guard
            !value.hasPrefix("+"),
            value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let parsed = UInt64(value),
            parsed <= UInt64(Int32.max)
        else {
            throw FluentdProviderError.valueOutOfRange(
                option: "fluentd-max-retries",
                value: value
            )
        }
        return parsed == 0 ? fluentLoggerZeroMaximumRetries : Int(parsed)
    }

    private static func retryWait(_ value: String) throws -> Duration {
        guard !value.isEmpty else {
            return defaultRetryWait
        }
        let parsed = try FluentdGoDuration.parse(
            value,
            option: "fluentd-retry-wait"
        )
        let milliseconds = parsed.wholeMillisecondsTowardZero
        return milliseconds == 0
            ? fluentLoggerZeroRetryWait
            : .milliseconds(milliseconds)
    }

    private static func optionalNonNegativeDuration(
        _ value: String,
        option: String
    ) throws -> Duration? {
        guard !value.isEmpty else {
            return nil
        }
        let parsed = try FluentdGoDuration.parse(value, option: option)
        guard parsed >= .zero else {
            throw FluentdProviderError.valueOutOfRange(option: option, value: value)
        }
        return parsed == .zero ? nil : parsed
    }

}

private enum FluentdMetadata {
    static func resolve(
        options: [String: String],
        info: FluentdContainerInfo,
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
            throw FluentdProviderError.invalidMetadataRegularExpression(
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

enum FluentdGoDuration {
    static func parse(_ value: String, option: String) throws -> Duration {
        do {
            return .nanoseconds(
                try DockerGoDurationParser.nanoseconds(value)
            )
        } catch DockerGoDurationParseError.invalidSyntax {
            throw FluentdProviderError.invalidDuration(
                option: option,
                value: value
            )
        } catch DockerGoDurationParseError.valueOutOfRange {
            throw FluentdProviderError.valueOutOfRange(
                option: option,
                value: value
            )
        }
    }
}
extension Duration {
    fileprivate var wholeMillisecondsTowardZero: Int64 {
        clampedNanoseconds / 1_000_000
    }

    package var fluentdClampedNanoseconds: Int64 {
        clampedNanoseconds
    }

    private var clampedNanoseconds: Int64 {
        let components = self.components
        let (secondsNanoseconds, overflow) = components.seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        if overflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        let attosecondNanoseconds = components.attoseconds / 1_000_000_000
        let (total, additionOverflow) = secondsNanoseconds.addingReportingOverflow(
            attosecondNanoseconds
        )
        if additionOverflow {
            return components.seconds < 0 ? Int64.min : Int64.max
        }
        return total
    }
}
