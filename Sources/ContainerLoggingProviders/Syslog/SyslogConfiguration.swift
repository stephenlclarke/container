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

public enum SyslogProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case unsupportedAddressScheme(String)
    case malformedAddress(String)
    case unixSocketDoesNotExist(String)
    case invalidFacility(String)
    case invalidFormat(String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case invalidConnectionPolicy
    case recordPayloadTooLarge(maximumBytes: Int)
    case encodedMessageTooLarge(maximumBytes: Int)
    case connectionTimedOut
    case writeTimedOut
    case closeTimedOut
    case transportClosed
    case invalidProviderIdentity
    case idempotencyConflict
    case unknownSession
    case invalidEffectToken
    case invalidSessionFence
    case readUnsupported
    case invalidTLSConfiguration(String)
    case tlsIdentityVerificationFailed
}

public struct SyslogNetworkAddress: Equatable, Sendable {
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

public enum SyslogEndpoint: Equatable, Sendable {
    case system
    case udp(SyslogNetworkAddress)
    case tcp(SyslogNetworkAddress)
    case tcpTLS(SyslogNetworkAddress)
    case unixStream(path: Data)
    case unixDatagram(path: Data)

    public var usesTLS: Bool {
        if case .tcpTLS = self {
            return true
        }
        return false
    }

    public var scheme: String {
        switch self {
        case .system: ""
        case .udp: "udp"
        case .tcp: "tcp"
        case .tcpTLS: "tcp+tls"
        case .unixStream: "unix"
        case .unixDatagram: "unixgram"
        }
    }

    public static func parse(
        _ address: String,
        semanticService: any DockerSemanticServicing
    ) throws -> Self {
        let resolved: DockerSyslogAddress
        do {
            resolved = try semanticService.parseSyslogAddress(
                Data(address.utf8),
                timeout: .seconds(2)
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .parse || error.category == .execute
        {
            throw SyslogProviderError.malformedAddress(address)
        }

        guard
            let networkProtocol = String(
                data: resolved.networkProtocol,
                encoding: .utf8
            )
        else {
            throw DockerSemanticHelperError.protocolViolation
        }
        let networkAddress = SyslogNetworkAddress(
            host: resolved.host,
            port: resolved.port
        )
        switch networkProtocol {
        case "":
            guard
                address.isEmpty,
                resolved.address.isEmpty,
                resolved.host.isEmpty,
                resolved.port == 0
            else {
                throw DockerSemanticHelperError.protocolViolation
            }
            return .system
        case "udp": return .udp(networkAddress)
        case "tcp": return .tcp(networkAddress)
        case "tcp+tls": return .tcpTLS(networkAddress)
        case "unix": return .unixStream(path: resolved.address)
        case "unixgram": return .unixDatagram(path: resolved.address)
        default: throw DockerSemanticHelperError.protocolViolation
        }
    }
}

public struct SyslogFacility: Equatable, Sendable {
    public let number: UInt8

    public init(number: UInt8) throws {
        guard number <= 23 else {
            throw SyslogProviderError.invalidFacility(String(number))
        }
        self.number = number
    }

    public static func parse(_ value: String) throws -> Self {
        if value.isEmpty {
            return try Self(number: 3)
        }
        if let named = names[value] {
            return try Self(number: named)
        }
        if let numeric = Int(value), (0...23).contains(numeric) {
            return try Self(number: UInt8(numeric))
        }
        throw SyslogProviderError.invalidFacility(value)
    }

    public func priority(for stream: ContainerLogStream) -> Int {
        let severity = stream == .stderr ? 3 : 6
        return Int(number) << 3 | severity
    }

    private static let names: [String: UInt8] = [
        "kern": 0,
        "user": 1,
        "mail": 2,
        "daemon": 3,
        "auth": 4,
        "syslog": 5,
        "lpr": 6,
        "news": 7,
        "uucp": 8,
        "cron": 9,
        "authpriv": 10,
        "ftp": 11,
        "local0": 16,
        "local1": 17,
        "local2": 18,
        "local3": 19,
        "local4": 20,
        "local5": 21,
        "local6": 22,
        "local7": 23,
    ]
}

public enum SyslogMessageFormat: String, CaseIterable, Equatable, Sendable {
    /// Moby's empty format selects srslog's Unix formatter even for remote transports.
    case unix = ""
    case rfc3164
    case rfc5424
    case rfc5424Micro = "rfc5424micro"

    public static func parse(_ value: String) throws -> Self {
        guard let format = Self(rawValue: value) else {
            throw SyslogProviderError.invalidFormat(value)
        }
        return format
    }
}

public struct SyslogTLSConfiguration: Equatable, Sendable {
    public let caCertificatePath: String
    public let clientCertificatePath: String
    public let clientPrivateKeyPath: String
    /// Docker enables this from option presence; the option's text is ignored.
    public let skipServerVerification: Bool

    public init(
        caCertificatePath: String,
        clientCertificatePath: String,
        clientPrivateKeyPath: String,
        skipServerVerification: Bool
    ) {
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientPrivateKeyPath = clientPrivateKeyPath
        self.skipServerVerification = skipServerVerification
    }
}

public struct SyslogConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                connectTimeout: .seconds(30),
                writeTimeout: .seconds(30),
                closeTimeout: .seconds(5)
            )
        } catch {
            preconditionFailure("invalid built-in syslog connection policy: \(error)")
        }
    }()

    public let connectTimeout: Duration
    public let writeTimeout: Duration
    public let closeTimeout: Duration

    public init(
        connectTimeout: Duration,
        writeTimeout: Duration,
        closeTimeout: Duration
    ) throws {
        guard connectTimeout > .zero, writeTimeout > .zero, closeTimeout > .zero else {
            throw SyslogProviderError.invalidConnectionPolicy
        }
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
        self.closeTimeout = closeTimeout
    }
}

public struct SyslogContainerInfo: Equatable, Sendable {
    public let containerID: String
    public let containerName: String
    public let containerEntrypoint: String
    public let containerArguments: [String]
    public let containerImageID: String
    public let containerImageName: String
    public let containerCreated: Date
    public let containerEnvironment: [String]
    public let containerLabels: [String: String]
    public let logPath: String
    public let daemonName: String
    public let hostname: String

    public init(
        containerID: String,
        containerName: String,
        containerEntrypoint: String = "",
        containerArguments: [String] = [],
        containerImageID: String = "",
        containerImageName: String = "",
        containerCreated: Date = .distantPast,
        containerEnvironment: [String] = [],
        containerLabels: [String: String] = [:],
        logPath: String = "",
        daemonName: String = "container",
        hostname: String = ProcessInfo.processInfo.hostName
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.containerEntrypoint = containerEntrypoint
        self.containerArguments = containerArguments
        self.containerImageID = containerImageID
        self.containerImageName = containerImageName
        self.containerCreated = containerCreated
        self.containerEnvironment = containerEnvironment
        self.containerLabels = containerLabels
        self.logPath = logPath
        self.daemonName = daemonName
        self.hostname = hostname
    }

    public var shortContainerID: String { Self.truncatedID(containerID) }
    public var shortImageID: String { Self.truncatedID(containerImageID) }
    public var name: String { containerName.first == "/" ? String(containerName.dropFirst()) : containerName }
    public var command: String { ([containerEntrypoint] + containerArguments).joined(separator: " ") }

    private static func truncatedID(_ identifier: String) -> String {
        String(identifier.prefix(12))
    }

    var dockerTemplateInfo: DockerLogTemplateInfo {
        DockerLogTemplateInfo(
            containerID: containerID,
            containerName: containerName,
            containerEntrypoint: containerEntrypoint,
            containerArguments: containerArguments,
            containerImageID: containerImageID,
            containerImageName: containerImageName,
            containerCreated: containerCreated,
            containerEnvironment: containerEnvironment,
            containerLabels: containerLabels,
            logPath: logPath,
            daemonName: daemonName,
            hostname: hostname
        )
    }
}

public struct SyslogDriverConfiguration: Equatable, Sendable {
    public static let maximumTagUTF8Bytes = ContainerLogRequest.maximumEncodedTransportBytes

    public let endpoint: SyslogEndpoint
    public let facility: SyslogFacility
    public let format: SyslogMessageFormat
    public let tag: Data
    public let hostname: String
    public let processID: Int32
    public let tls: SyslogTLSConfiguration?
    public let policy: SyslogConnectionPolicy

    public init(
        endpoint: SyslogEndpoint,
        facility: SyslogFacility,
        format: SyslogMessageFormat,
        tag: Data,
        hostname: String,
        processID: Int32,
        tls: SyslogTLSConfiguration?,
        policy: SyslogConnectionPolicy
    ) throws {
        guard tag.count <= Self.maximumTagUTF8Bytes else {
            throw SyslogProviderError.tagExceedsUTF8Limit(maximumBytes: Self.maximumTagUTF8Bytes)
        }
        guard endpoint.usesTLS == (tls != nil) else {
            throw SyslogProviderError.invalidTLSConfiguration("TLS configuration does not match the endpoint")
        }
        self.endpoint = endpoint
        self.facility = facility
        self.format = format
        self.tag = tag
        self.hostname = hostname
        self.processID = processID
        self.tls = tls
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: SyslogContainerInfo,
        semanticService: any DockerSemanticServicing,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        policy: SyslogConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: { !knownOptionNames.contains($0) }) {
            throw SyslogProviderError.unknownOption(unknown)
        }

        let endpoint = try SyslogEndpoint.parse(
            options["syslog-address"] ?? "",
            semanticService: semanticService
        )
        let facility = try SyslogFacility.parse(options["syslog-facility"] ?? "")
        let format = try SyslogMessageFormat.parse(options["syslog-format"] ?? "")
        let requestedTag = options["tag"] ?? ""
        guard requestedTag.utf8.count <= Self.maximumTagUTF8Bytes else {
            throw SyslogProviderError.tagExceedsUTF8Limit(
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
            where error.category == .parse
        {
            throw SyslogProviderError.invalidTagTemplate(requestedTag)
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .outputLimit
        {
            throw SyslogProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        } catch let error as DockerSemanticHelperRemoteError
            where error.category == .execute
        {
            throw SyslogProviderError.invalidTagTemplate(requestedTag)
        }
        let tls =
            endpoint.usesTLS
            ? SyslogTLSConfiguration(
                caCertificatePath: options["syslog-tls-ca-cert"] ?? "",
                clientCertificatePath: options["syslog-tls-cert"] ?? "",
                clientPrivateKeyPath: options["syslog-tls-key"] ?? "",
                skipServerVerification: options.keys.contains("syslog-tls-skip-verify")
            )
            : nil
        return try Self(
            endpoint: endpoint,
            facility: facility,
            format: format,
            tag: tag,
            hostname: info.hostname,
            processID: processID,
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
        "syslog-address",
        "syslog-facility",
        "syslog-format",
        "syslog-tls-ca-cert",
        "syslog-tls-cert",
        "syslog-tls-key",
        "syslog-tls-skip-verify",
        "tag",
    ]
}
