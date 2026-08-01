//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import Foundation

/// The only RPC methods a Docker logging-plugin transport may address.
///
/// Keeping the endpoint closed prevents configuration or user input from being
/// interpreted as an arbitrary HTTP path inside the protected provider plane.
public enum DockerPluginEndpoint: String, CaseIterable, Equatable, Sendable {
    case capabilities = "LogDriver.Capabilities"
    case startLogging = "LogDriver.StartLogging"
    case stopLogging = "LogDriver.StopLogging"
    case readLogs = "LogDriver.ReadLogs"
}

/// Redacted failures produced at the Docker logging-plugin trust boundary.
///
/// Plugin response bodies and transport errors may contain configuration,
/// environment, labels, credentials, or log payload. They are deliberately not
/// retained as associated values or interpolated into diagnostics.
public enum DockerPluginProtocolError: Error, Equatable, Sendable, CustomStringConvertible {
    case requestTooLarge(endpoint: DockerPluginEndpoint, maximumBytes: Int)
    case responseTooLarge(endpoint: DockerPluginEndpoint, maximumBytes: Int)
    case malformedResponse(endpoint: DockerPluginEndpoint)
    case endpointRejected(endpoint: DockerPluginEndpoint)
    case transportFailure(endpoint: DockerPluginEndpoint)
    case invalidFIFOReference
    case providerGenerationMismatch
    case lineTooLarge(maximumBytes: Int)
    case frameTooLarge(maximumBytes: Int)
    case malformedFrame
    case invalidStream
    case timestampOutOfRange
    case partialOrdinalOutOfRange
    case fifoFailure
    case operationQueueFull(maximumWaiters: Int)
    case writerUnavailable
    case stopOutcomeUncertain
    case deadlineExceeded

    public var description: String {
        switch self {
        case .requestTooLarge(let endpoint, let maximumBytes):
            "Docker logging-plugin request for \(endpoint.rawValue) exceeds \(maximumBytes) bytes"
        case .responseTooLarge(let endpoint, let maximumBytes):
            "Docker logging-plugin response for \(endpoint.rawValue) exceeds \(maximumBytes) bytes"
        case .malformedResponse(let endpoint):
            "Docker logging-plugin returned a malformed \(endpoint.rawValue) response"
        case .endpointRejected(let endpoint):
            "Docker logging-plugin rejected \(endpoint.rawValue)"
        case .transportFailure(let endpoint):
            "Docker logging-plugin transport failed for \(endpoint.rawValue)"
        case .invalidFIFOReference:
            "Docker logging-plugin FIFO reference is invalid"
        case .providerGenerationMismatch:
            "Docker logging-plugin provider generation does not match the acquired lease"
        case .lineTooLarge(let maximumBytes):
            "Docker logging-plugin line exceeds \(maximumBytes) bytes"
        case .frameTooLarge(let maximumBytes):
            "Docker logging-plugin frame exceeds \(maximumBytes) bytes"
        case .malformedFrame:
            "Docker logging-plugin frame is malformed"
        case .invalidStream:
            "Docker logging-plugin returned an unknown log stream"
        case .timestampOutOfRange:
            "Docker logging-plugin timestamp is outside the supported range"
        case .partialOrdinalOutOfRange:
            "Docker logging-plugin partial ordinal is outside the supported range"
        case .fifoFailure:
            "Docker logging-plugin FIFO operation failed"
        case .operationQueueFull(let maximumWaiters):
            "Docker logging-plugin writer already has \(maximumWaiters) queued operations"
        case .writerUnavailable:
            "Docker logging-plugin writer is unavailable"
        case .stopOutcomeUncertain:
            "Docker logging-plugin stop outcome is uncertain"
        case .deadlineExceeded:
            "Docker logging-plugin operation deadline was exceeded"
        }
    }
}

/// A bounded response stream returned by `LogDriver.ReadLogs`.
public protocol DockerPluginResponseStream: Sendable {
    /// Returns the next non-owning transport chunk or `nil` at EOF.
    func nextChunk(maximumBytes: Int) async throws -> Data?

    /// Cancels and closes the underlying response exactly once.
    func close() async
}

/// Authenticated transport to one already-resolved plugin generation.
///
/// Implementations own HTTP framing, status validation, authentication, and
/// enforcement of the supplied response limit and deadline. The protocol does
/// not accept a URL, socket path, plugin name, or arbitrary method string.
public protocol DockerPluginRPCTransport: Sendable {
    func call(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant?
    ) async throws -> Data

    func openStream(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumChunkBytes: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> any DockerPluginResponseStream
}

/// Docker-shaped metadata supplied to `StartLogging` and `ReadLogs`.
///
/// This value intentionally has no `Codable` conformance. Encoding is confined
/// to the protocol client, while textual and reflective representations redact
/// the sensitive maps, environment, labels, and command arguments.
public struct DockerPluginInfo: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public static let maximumEncodedBytes = 256 * 1024

    public let config: [String: String]
    public let containerID: String
    public let containerName: String
    public let containerEntrypoint: String
    public let containerArgs: [String]
    public let containerImageID: String
    public let containerImageName: String
    public let containerCreated: Date
    public let containerEnv: [String]
    public let containerLabels: [String: String]
    public let logPath: String
    public let daemonName: String

    public init(
        config: [String: String],
        containerID: String,
        containerName: String,
        containerEntrypoint: String,
        containerArgs: [String],
        containerImageID: String,
        containerImageName: String,
        containerCreated: Date,
        containerEnv: [String],
        containerLabels: [String: String],
        logPath: String,
        daemonName: String
    ) throws {
        guard !containerID.isEmpty, containerID.utf8.count <= 4 * 1024 else {
            throw DockerPluginProtocolError.malformedResponse(endpoint: .startLogging)
        }
        try DockerPluginTimestampCodec.validate(containerCreated)
        self.config = config
        self.containerID = containerID
        self.containerName = containerName
        self.containerEntrypoint = containerEntrypoint
        self.containerArgs = containerArgs
        self.containerImageID = containerImageID
        self.containerImageName = containerImageName
        self.containerCreated = containerCreated
        self.containerEnv = containerEnv
        self.containerLabels = containerLabels
        self.logPath = logPath
        self.daemonName = daemonName

        let encoded = try JSONEncoder.dockerPlugin.encode(WireInfo(self))
        guard encoded.count <= Self.maximumEncodedBytes else {
            throw DockerPluginProtocolError.requestTooLarge(
                endpoint: .startLogging,
                maximumBytes: Self.maximumEncodedBytes
            )
        }
    }

    public var description: String {
        "DockerPluginInfo(containerID: <redacted>, config: <redacted>, environment: <redacted>, labels: <redacted>, arguments: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "config": "<redacted>",
                "containerID": "<redacted>",
                "containerArgs": "<redacted>",
                "containerEnv": "<redacted>",
                "containerLabels": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

/// Capabilities returned by `LogDriver.Capabilities`.
public struct DockerPluginCapabilities: Equatable, Sendable {
    public let readLogs: Bool

    public init(readLogs: Bool) {
        self.readLogs = readLogs
    }
}

/// The Engine-visible read strategy selected from a plugin capability reply.
public enum DockerPluginReadRouting: Equatable, Sendable {
    /// `ReadLogs` is called directly and the local cache is bypassed.
    case pluginReader
    /// The plugin remains the primary writer and a local cache is required.
    case dualLocalCache

    public init(capabilities: DockerPluginCapabilities) {
        self = capabilities.readLogs ? .pluginReader : .dualLocalCache
    }
}

/// Exact Docker `ReadConfig` fields used by the logging-plugin protocol.
public struct DockerPluginReadConfiguration: Equatable, Sendable {
    public let since: Date?
    public let until: Date?
    public let tail: Int
    public let follow: Bool

    public init(_ request: ContainerLogReadRequest) {
        self.since = request.since
        self.until = request.until
        self.tail = request.tail ?? -1
        self.follow = request.follow
    }
}

/// Bounded JSON adapter for the official Docker logging-plugin RPC surface.
public struct DockerPluginProtocolClient: Sendable {
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumStreamChunkBytes = 64 * 1024
    public static let streamOpenTimeout: Duration = .seconds(30)

    private let transport: any DockerPluginRPCTransport

    public init(transport: any DockerPluginRPCTransport) {
        self.transport = transport
    }

    /// Calls `Capabilities` with Docker's exact empty request body.
    public func capabilities(
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> DockerPluginCapabilities {
        let response = try await call(
            endpoint: .capabilities,
            request: Data(),
            deadline: deadline
        )
        let decoded: CapabilitiesResponse = try decode(response, endpoint: .capabilities)
        try rejectRemoteError(decoded.error, endpoint: .capabilities)
        return DockerPluginCapabilities(readLogs: decoded.capability.readLogs)
    }

    public func startLogging(
        fifo: DockerPluginFIFOReference,
        info: DockerPluginInfo,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let request = StartRequest(file: fifo.pluginPath, info: WireInfo(info))
        let response = try await call(
            endpoint: .startLogging,
            request: try encode(request, endpoint: .startLogging),
            deadline: deadline
        )
        let decoded: ErrorResponse = try decode(response, endpoint: .startLogging)
        try rejectRemoteError(decoded.error, endpoint: .startLogging)
    }

    public func stopLogging(
        fifo: DockerPluginFIFOReference,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let request = StopRequest(file: fifo.pluginPath)
        let response = try await call(
            endpoint: .stopLogging,
            request: try encode(request, endpoint: .stopLogging),
            deadline: deadline
        )
        let decoded: ErrorResponse = try decode(response, endpoint: .stopLogging)
        try rejectRemoteError(decoded.error, endpoint: .stopLogging)
    }

    public func readLogs(
        info: DockerPluginInfo,
        configuration: DockerPluginReadConfiguration,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> any DockerPluginResponseStream {
        if let since = configuration.since {
            try DockerPluginTimestampCodec.validate(since)
        }
        if let until = configuration.until {
            try DockerPluginTimestampCodec.validate(until)
        }
        let request = ReadRequest(
            info: WireInfo(info),
            config: WireReadConfiguration(configuration)
        )
        let body = try encode(request, endpoint: .readLogs)
        let resolvedDeadline = deadline ?? (ContinuousClock().now + Self.streamOpenTimeout)
        guard ContinuousClock().now < resolvedDeadline else {
            throw DockerPluginProtocolError.deadlineExceeded
        }
        do {
            try Task.checkCancellation()
            let stream = try await transport.openStream(
                endpoint: .readLogs,
                request: body,
                maximumChunkBytes: Self.maximumStreamChunkBytes,
                deadline: resolvedDeadline
            )
            if Task.isCancelled {
                await stream.close()
                throw CancellationError()
            }
            return stream
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DockerPluginProtocolError.transportFailure(endpoint: .readLogs)
        }
    }

    private func call(
        endpoint: DockerPluginEndpoint,
        request: Data,
        deadline: ContinuousClock.Instant?
    ) async throws -> Data {
        if let deadline, ContinuousClock().now >= deadline {
            throw DockerPluginProtocolError.deadlineExceeded
        }
        do {
            try Task.checkCancellation()
            let response = try await transport.call(
                endpoint: endpoint,
                request: request,
                maximumResponseBytes: Self.maximumResponseBytes,
                deadline: deadline
            )
            try Task.checkCancellation()
            guard response.count <= Self.maximumResponseBytes else {
                throw DockerPluginProtocolError.responseTooLarge(
                    endpoint: endpoint,
                    maximumBytes: Self.maximumResponseBytes
                )
            }
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DockerPluginProtocolError {
            throw error
        } catch {
            throw DockerPluginProtocolError.transportFailure(endpoint: endpoint)
        }
    }

    private func encode<Value: Encodable>(
        _ value: Value,
        endpoint: DockerPluginEndpoint
    ) throws -> Data {
        do {
            let data = try JSONEncoder.dockerPlugin.encode(value)
            guard data.count <= DockerPluginInfo.maximumEncodedBytes else {
                throw DockerPluginProtocolError.requestTooLarge(
                    endpoint: endpoint,
                    maximumBytes: DockerPluginInfo.maximumEncodedBytes
                )
            }
            return data
        } catch let error as DockerPluginProtocolError {
            throw error
        } catch {
            throw DockerPluginProtocolError.malformedResponse(endpoint: endpoint)
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from data: Data,
        endpoint: DockerPluginEndpoint
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DockerPluginProtocolError.malformedResponse(endpoint: endpoint)
        }
    }

    private func decode<Value: Decodable>(
        _ data: Data,
        endpoint: DockerPluginEndpoint
    ) throws -> Value {
        try decode(Value.self, from: data, endpoint: endpoint)
    }

    private func rejectRemoteError(
        _ error: String,
        endpoint: DockerPluginEndpoint
    ) throws {
        guard error.isEmpty else {
            throw DockerPluginProtocolError.endpointRejected(endpoint: endpoint)
        }
    }
}

private struct WireInfo: Encodable {
    let config: [String: String]
    let containerID: String
    let containerName: String
    let containerEntrypoint: String
    let containerArgs: [String]
    let containerImageID: String
    let containerImageName: String
    let containerCreated: String
    let containerEnv: [String]
    let containerLabels: [String: String]
    let logPath: String
    let daemonName: String

    private enum CodingKeys: String, CodingKey {
        case config = "Config"
        case containerID = "ContainerID"
        case containerName = "ContainerName"
        case containerEntrypoint = "ContainerEntrypoint"
        case containerArgs = "ContainerArgs"
        case containerImageID = "ContainerImageID"
        case containerImageName = "ContainerImageName"
        case containerCreated = "ContainerCreated"
        case containerEnv = "ContainerEnv"
        case containerLabels = "ContainerLabels"
        case logPath = "LogPath"
        case daemonName = "DaemonName"
    }

    init(_ info: DockerPluginInfo) {
        self.config = info.config
        self.containerID = info.containerID
        self.containerName = info.containerName
        self.containerEntrypoint = info.containerEntrypoint
        self.containerArgs = info.containerArgs
        self.containerImageID = info.containerImageID
        self.containerImageName = info.containerImageName
        self.containerCreated = DockerPluginTimestampCodec.string(info.containerCreated)
        self.containerEnv = info.containerEnv
        self.containerLabels = info.containerLabels
        self.logPath = info.logPath
        self.daemonName = info.daemonName
    }
}

private struct StartRequest: Encodable {
    let file: String
    let info: WireInfo

    private enum CodingKeys: String, CodingKey {
        case file = "File"
        case info = "Info"
    }
}

private struct StopRequest: Encodable {
    let file: String

    private enum CodingKeys: String, CodingKey {
        case file = "File"
    }
}

private struct ReadRequest: Encodable {
    let info: WireInfo
    let config: WireReadConfiguration

    private enum CodingKeys: String, CodingKey {
        case info = "Info"
        case config = "Config"
    }
}

private struct WireReadConfiguration: Encodable {
    let since: String
    let until: String
    let tail: Int
    let follow: Bool

    private enum CodingKeys: String, CodingKey {
        case since = "Since"
        case until = "Until"
        case tail = "Tail"
        case follow = "Follow"
    }

    init(_ configuration: DockerPluginReadConfiguration) {
        self.since = configuration.since.map(DockerPluginTimestampCodec.string) ?? DockerPluginTimestampCodec.zero
        self.until = configuration.until.map(DockerPluginTimestampCodec.string) ?? DockerPluginTimestampCodec.zero
        self.tail = configuration.tail
        self.follow = configuration.follow
    }
}

private struct ErrorResponse: Decodable {
    let error: String

    private enum CodingKeys: String, CodingKey {
        case error = "Err"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

private struct CapabilitiesResponse: Decodable {
    struct Capability: Decodable {
        let readLogs: Bool

        private enum CodingKeys: String, CodingKey {
            case readLogs = "ReadLogs"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.readLogs = try container.decodeIfPresent(Bool.self, forKey: .readLogs) ?? false
        }
    }

    let capability: Capability
    let error: String

    private enum CodingKeys: String, CodingKey {
        case capability = "Cap"
        case error = "Err"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.capability = try container.decodeIfPresent(Capability.self, forKey: .capability) ?? Capability.empty
        self.error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

extension CapabilitiesResponse.Capability {
    fileprivate static let empty: Self = {
        do {
            return try JSONDecoder().decode(Self.self, from: Data("{}".utf8))
        } catch {
            preconditionFailure("empty Docker logging-plugin capability failed to decode")
        }
    }()
}

private enum DockerPluginTimestampCodec {
    static let zero = "0001-01-01T00:00:00Z"
    private static let earliestSupportedInterval: TimeInterval = -62_135_596_800
    private static let latestSupportedInterval: TimeInterval = 253_402_300_800

    static func validate(_ date: Date) throws {
        let interval = date.timeIntervalSince1970
        guard
            date.timeIntervalSinceReferenceDate.isFinite,
            interval >= earliestSupportedInterval,
            interval < latestSupportedInterval
        else {
            throw DockerPluginProtocolError.timestampOutOfRange
        }
    }

    static func string(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = Int64(interval.rounded(.down))
        var nanoseconds = Int(((interval - Double(seconds)) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }

        var days = seconds / 86_400
        var secondsOfDay = seconds % 86_400
        if secondsOfDay < 0 {
            days -= 1
            secondsOfDay += 86_400
        }
        let date = civilDate(daysSinceUnixEpoch: days)
        let hour = secondsOfDay / 3_600
        let minute = (secondsOfDay % 3_600) / 60
        let second = secondsOfDay % 60
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            date.year,
            date.month,
            date.day,
            hour,
            minute,
            second
        )
        guard nanoseconds != 0 else {
            return base + "Z"
        }
        var fraction = String(format: "%09d", locale: Locale(identifier: "en_US_POSIX"), nanoseconds)
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return base + "." + fraction + "Z"
    }

    /// Converts Unix days using the proleptic Gregorian calendar used by Go's
    /// `time.Time`, including dates before the historical 1582 cutover.
    private static func civilDate(
        daysSinceUnixEpoch days: Int64
    ) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - (era * 146_097)
        let yearOfEra =
            (dayOfEra - (dayOfEra / 1_460) + (dayOfEra / 36_524) - (dayOfEra / 146_096)) / 365
        var year = yearOfEra + (era * 400)
        let dayOfYear = dayOfEra - ((365 * yearOfEra) + (yearOfEra / 4) - (yearOfEra / 100))
        let monthPrime = ((5 * dayOfYear) + 2) / 153
        let day = dayOfYear - (((153 * monthPrime) + 2) / 5) + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        if month <= 2 {
            year += 1
        }
        return (year, month, day)
    }
}

extension JSONEncoder {
    fileprivate static var dockerPlugin: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
