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

import Darwin
import Foundation
import Logging

/// A protected Engine-Linux TCP transport service. The service owns the
/// outbound socket so TCP reset observation uses Linux kernel semantics while
/// the existing GELF session remains the single reconnect-policy authority.
public protocol GELFTCPService: Sendable {
    func connect(
        to address: GELFNetworkAddress,
        timeout: Duration
    ) async throws -> any GELFTransport
}

/// Uses the Linux TCP service only for TCP GELF. UDP intentionally remains on
/// the native transport because it has no reset/reconnect state to preserve.
public struct GELFServiceTransportFactory: GELFTransportFactory, Sendable {
    private let nativeTransportFactory: any GELFTransportFactory
    private let tcpService: any GELFTCPService

    public init(
        nativeTransportFactory: any GELFTransportFactory,
        tcpService: any GELFTCPService
    ) {
        self.nativeTransportFactory = nativeTransportFactory
        self.tcpService = tcpService
    }

    public func connect(
        to endpoint: GELFEndpoint,
        timeout: Duration
    ) async throws -> any GELFTransport {
        guard case .tcp(let address) = endpoint else {
            return try await nativeTransportFactory.connect(
                to: endpoint,
                timeout: timeout
            )
        }
        return try await tcpService.connect(to: address, timeout: timeout)
    }
}

public enum GELFTCPServiceWireError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidAddress
    case invalidTimeout
    case frameTooLarge(Int)
    case disconnected
    case responseMismatch
}

public enum GELFTCPServiceWireOperationV1: String, Codable, Sendable {
    case activeSandboxGeneration
    case open
    case write
    case close
}

public enum GELFTCPServiceWireFailureV1: String, Codable, Sendable {
    case invalidRequest
    case connectionFailed
    case writeFailed
    case timedOut
    case unavailable
    case internalFailure
}

public struct GELFTCPServiceEndpointWireV1: Codable, Equatable, Sendable {
    public let host: String
    public let port: String

    public init(host: String, port: String) throws {
        guard host.utf8.count <= 1_024 else {
            throw GELFTCPServiceWireError.invalidAddress
        }
        guard
            !port.isEmpty,
            port.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let numericPort = Int(port),
            (0...65_535).contains(numericPort)
        else {
            throw GELFTCPServiceWireError.invalidAddress
        }
        self.host = host
        self.port = port
    }

    public init(_ address: GELFNetworkAddress) throws {
        try self.init(host: address.host, port: address.port)
    }

    public func networkAddress() -> GELFNetworkAddress {
        GELFNetworkAddress(host: host, port: port)
    }
}

public struct GELFTCPServiceWireRequestV1: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationID: String
    public let operation: GELFTCPServiceWireOperationV1
    public let endpoint: GELFTCPServiceEndpointWireV1?
    public let timeoutNanoseconds: UInt64?
    public let frame: Data?

    public static func activeSandboxGeneration() throws -> Self {
        try Self(
            operation: .activeSandboxGeneration,
            endpoint: nil,
            timeoutNanoseconds: nil,
            frame: nil
        )
    }

    public static func open(
        endpoint: GELFTCPServiceEndpointWireV1,
        timeout: Duration
    ) throws -> Self {
        try Self(
            operation: .open,
            endpoint: endpoint,
            timeoutNanoseconds: try GELFTCPServiceWireDuration.nanoseconds(
                from: timeout
            ),
            frame: nil
        )
    }

    public static func write(
        _ frame: Data,
        timeout: Duration
    ) throws -> Self {
        try Self(
            operation: .write,
            endpoint: nil,
            timeoutNanoseconds: try GELFTCPServiceWireDuration.nanoseconds(
                from: timeout
            ),
            frame: frame
        )
    }

    public static func close() throws -> Self {
        try Self(
            operation: .close,
            endpoint: nil,
            timeoutNanoseconds: nil,
            frame: nil
        )
    }

    private init(
        operation: GELFTCPServiceWireOperationV1,
        endpoint: GELFTCPServiceEndpointWireV1?,
        timeoutNanoseconds: UInt64?,
        frame: Data?
    ) throws {
        try self.init(
            schemaVersion: Self.schemaVersion,
            operationID: UUID().uuidString.lowercased(),
            operation: operation,
            endpoint: endpoint,
            timeoutNanoseconds: timeoutNanoseconds,
            frame: frame
        )
    }

    private init(
        schemaVersion: UInt32,
        operationID: String,
        operation: GELFTCPServiceWireOperationV1,
        endpoint: GELFTCPServiceEndpointWireV1?,
        timeoutNanoseconds: UInt64?,
        frame: Data?
    ) throws {
        guard
            schemaVersion == Self.schemaVersion,
            UUID(uuidString: operationID) != nil,
            operationID == operationID.lowercased()
        else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
        switch operation {
        case .activeSandboxGeneration, .close:
            guard endpoint == nil, timeoutNanoseconds == nil, frame == nil else {
                throw GELFTCPServiceWireError.invalidEnvelope
            }
        case .open:
            guard endpoint != nil, let timeoutNanoseconds, timeoutNanoseconds > 0,
                frame == nil
            else {
                throw GELFTCPServiceWireError.invalidEnvelope
            }
        case .write:
            guard endpoint == nil, timeoutNanoseconds != nil, let frame,
                !frame.isEmpty
            else {
                throw GELFTCPServiceWireError.invalidEnvelope
            }
            guard frame.count <= GELFMessageEncoder.maximumEncodedMessageBytes else {
                throw GELFTCPServiceWireError.frameTooLarge(frame.count)
            }
        }
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.operation = operation
        self.endpoint = endpoint
        self.timeoutNanoseconds = timeoutNanoseconds
        self.frame = frame
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try container.decode(UInt32.self, forKey: .schemaVersion),
            operationID: try container.decode(String.self, forKey: .operationID),
            operation: try container.decode(
                GELFTCPServiceWireOperationV1.self,
                forKey: .operation
            ),
            endpoint: try container.decodeIfPresent(
                GELFTCPServiceEndpointWireV1.self,
                forKey: .endpoint
            ),
            timeoutNanoseconds: try container.decodeIfPresent(
                UInt64.self,
                forKey: .timeoutNanoseconds
            ),
            frame: try container.decodeIfPresent(Data.self, forKey: .frame)
        )
    }
}

public struct GELFTCPServiceWireResponseV1: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let schemaVersion: UInt32
    public let operationID: String
    public let sandboxGeneration: UInt64?
    public let writtenBytes: Int?
    public let failure: GELFTCPServiceWireFailureV1?

    public static func acknowledgement(operationID: String) throws -> Self {
        try Self(
            operationID: operationID,
            sandboxGeneration: nil,
            writtenBytes: nil,
            failure: nil
        )
    }

    public static func generation(
        operationID: String,
        sandboxGeneration: UInt64
    ) throws -> Self {
        try Self(
            operationID: operationID,
            sandboxGeneration: sandboxGeneration,
            writtenBytes: nil,
            failure: nil
        )
    }

    public static func write(
        operationID: String,
        writtenBytes: Int
    ) throws -> Self {
        try Self(
            operationID: operationID,
            sandboxGeneration: nil,
            writtenBytes: writtenBytes,
            failure: nil
        )
    }

    public static func failure(
        operationID: String,
        failure: GELFTCPServiceWireFailureV1
    ) throws -> Self {
        try Self(
            operationID: operationID,
            sandboxGeneration: nil,
            writtenBytes: nil,
            failure: failure
        )
    }

    private init(
        operationID: String,
        sandboxGeneration: UInt64?,
        writtenBytes: Int?,
        failure: GELFTCPServiceWireFailureV1?
    ) throws {
        guard
            UUID(uuidString: operationID) != nil,
            operationID == operationID.lowercased()
        else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
        if let failure {
            guard sandboxGeneration == nil, writtenBytes == nil else {
                throw GELFTCPServiceWireError.invalidEnvelope
            }
            self.failure = failure
        } else {
            guard !(sandboxGeneration != nil && writtenBytes != nil) else {
                throw GELFTCPServiceWireError.invalidEnvelope
            }
            if let sandboxGeneration {
                guard sandboxGeneration > 0 else {
                    throw GELFTCPServiceWireError.invalidEnvelope
                }
            }
            if let writtenBytes {
                guard writtenBytes >= 0 else {
                    throw GELFTCPServiceWireError.invalidEnvelope
                }
            }
            self.failure = nil
        }
        self.schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.sandboxGeneration = sandboxGeneration
        self.writtenBytes = writtenBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
        try self.init(
            operationID: try container.decode(String.self, forKey: .operationID),
            sandboxGeneration: try container.decodeIfPresent(
                UInt64.self,
                forKey: .sandboxGeneration
            ),
            writtenBytes: try container.decodeIfPresent(Int.self, forKey: .writtenBytes),
            failure: try container.decodeIfPresent(
                GELFTCPServiceWireFailureV1.self,
                forKey: .failure
            )
        )
    }
}

public enum GELFTCPServiceFrameCodecV1 {
    /// The largest GELF TCP payload is 4 MiB. Base64 JSON framing adds less
    /// than 2 MiB, so 6 MiB admits valid requests and rejects allocation abuse.
    public static let maximumFrameBytes = 6 * 1_024 * 1_024

    public static func write<Value: Encodable>(
        _ value: Value,
        to handle: FileHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= maximumFrameBytes else {
            throw GELFTCPServiceWireError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try handle.write(contentsOf: frame)
    }

    public static func read<Value: Decodable>(
        _ type: Value.Type,
        from handle: FileHandle
    ) throws -> Value {
        let header = try readExactly(4, from: handle)
        let length = header.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0, length <= maximumFrameBytes else {
            throw GELFTCPServiceWireError.frameTooLarge(Int(length))
        }
        return try JSONDecoder().decode(
            type,
            from: try readExactly(Int(length), from: handle)
        )
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard
                let part = try handle.read(upToCount: count - result.count),
                !part.isEmpty
            else {
                throw GELFTCPServiceWireError.disconnected
            }
            result.append(part)
        }
        return result
    }
}

/// A service client creates one VSOCK connection per GELF TCP socket. The
/// connection deliberately does not replay writes: the GELF session's
/// go-gelf-compatible retry loop owns retry timing and frame replay.
public actor GELFTCPServiceWireClientV1: GELFTCPService {
    public typealias Connector = @Sendable () async throws -> FileHandle

    private let connector: Connector

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    public func connect(
        to address: GELFNetworkAddress,
        timeout: Duration
    ) async throws -> any GELFTransport {
        let connection = GELFTCPServiceWireConnectionV1(connector: connector)
        do {
            try await connection.open(address: address, timeout: timeout)
            return GELFTCPServiceRemoteTransportV1(connection: connection)
        } catch {
            await connection.closeSilently()
            throw error
        }
    }

    public static func activeSandboxGeneration(
        on handle: FileHandle
    ) async throws -> UInt64 {
        let request = try GELFTCPServiceWireRequestV1.activeSandboxGeneration()
        let response = try await Task.detached {
            try GELFTCPServiceFrameCodecV1.write(request, to: handle)
            return try GELFTCPServiceFrameCodecV1.read(
                GELFTCPServiceWireResponseV1.self,
                from: handle
            )
        }.value
        guard
            response.operationID == request.operationID,
            response.failure == nil,
            let generation = response.sandboxGeneration
        else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
        return generation
    }
}

private actor GELFTCPServiceWireConnectionV1 {
    private static let logger = Logger(
        label: "com.apple.container.logging.gelf.tcp-service"
    )

    private let connector: GELFTCPServiceWireClientV1.Connector
    private var handle: FileHandle?
    private var address: GELFNetworkAddress?

    init(connector: @escaping GELFTCPServiceWireClientV1.Connector) {
        self.connector = connector
    }

    func open(address: GELFNetworkAddress, timeout: Duration) async throws {
        let endpoint = try GELFTCPServiceEndpointWireV1(address)
        let request = try GELFTCPServiceWireRequestV1.open(
            endpoint: endpoint,
            timeout: timeout
        )
        let response = try await call(request)
        if let failure = response.failure {
            throw Self.openError(failure, address: address)
        }
        guard response.sandboxGeneration == nil, response.writtenBytes == nil else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
        self.address = address
    }

    func write(_ frame: Data, timeout: Duration) async throws -> Int {
        let request = try GELFTCPServiceWireRequestV1.write(frame, timeout: timeout)
        let response = try await call(request)
        if let failure = response.failure {
            // The Linux service closes its remote peer on every failed write.
            // Do not allow a caller to reuse this VSOCK connection for a later
            // frame: the GELF session is the sole retry/reconnect authority.
            let failedAddress = address
            invalidateHandle()
            throw Self.writeError(failure, address: failedAddress)
        }
        guard
            response.sandboxGeneration == nil,
            let written = response.writtenBytes,
            written == frame.count
        else {
            invalidateHandle()
            throw GELFProviderError.transportClosed
        }
        return written
    }

    func close(timeout: Duration) async throws {
        _ = timeout
        guard handle != nil else {
            return
        }
        defer { invalidateHandle() }
        let response = try await call(try GELFTCPServiceWireRequestV1.close())
        guard response.failure == nil, response.sandboxGeneration == nil,
            response.writtenBytes == nil
        else {
            throw GELFTCPServiceWireError.invalidEnvelope
        }
    }

    func closeSilently() {
        invalidateHandle()
    }

    private func call(
        _ request: GELFTCPServiceWireRequestV1
    ) async throws -> GELFTCPServiceWireResponseV1 {
        let handle: FileHandle
        do {
            handle = try await connectedHandle()
            let response = try await Task.detached {
                try GELFTCPServiceFrameCodecV1.write(request, to: handle)
                return try GELFTCPServiceFrameCodecV1.read(
                    GELFTCPServiceWireResponseV1.self,
                    from: handle
                )
            }.value
            guard response.operationID == request.operationID else {
                throw GELFTCPServiceWireError.responseMismatch
            }
            return response
        } catch is CancellationError {
            invalidateHandle()
            throw CancellationError()
        } catch {
            Self.logger.error(
                "Engine-Linux GELF TCP service request failed",
                metadata: [
                    "operation": "\(request.operation.rawValue)",
                    "error": "\(error)",
                ]
            )
            invalidateHandle()
            throw GELFProviderError.transportClosed
        }
    }

    private func connectedHandle() async throws -> FileHandle {
        if let handle {
            return handle
        }
        let connected = try await connector()
        do {
            try Self.suppressBrokenPipeSignal(on: connected)
        } catch {
            try? connected.close()
            throw error
        }
        handle = connected
        return connected
    }

    private func invalidateHandle() {
        guard let handle else {
            return
        }
        self.handle = nil
        address = nil
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
    }

    private static func openError(
        _ failure: GELFTCPServiceWireFailureV1,
        address: GELFNetworkAddress
    ) -> any Error {
        switch failure {
        case .timedOut:
            return GELFProviderError.connectionTimedOut
        case .connectionFailed:
            return GELFProviderError.connectionFailed(
                endpoint: address,
                reason: "Engine-Linux GELF service could not connect"
            )
        case .invalidRequest, .writeFailed, .unavailable, .internalFailure:
            return GELFProviderError.transportClosed
        }
    }

    private static func writeError(
        _ failure: GELFTCPServiceWireFailureV1,
        address: GELFNetworkAddress?
    ) -> any Error {
        switch failure {
        case .timedOut:
            return GELFProviderError.writeTimedOut
        case .writeFailed, .connectionFailed:
            guard let address else {
                return GELFProviderError.transportClosed
            }
            return GELFProviderError.connectionFailed(
                endpoint: address,
                reason: "Engine-Linux GELF service write failed"
            )
        case .invalidRequest, .unavailable, .internalFailure:
            return GELFProviderError.transportClosed
        }
    }

    private static func suppressBrokenPipeSignal(on handle: FileHandle) throws {
        var enabled: Int32 = 1
        let result = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(
                handle.fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private actor GELFTCPServiceRemoteTransportV1: GELFTransport {
    private let connection: GELFTCPServiceWireConnectionV1

    init(connection: GELFTCPServiceWireConnectionV1) {
        self.connection = connection
    }

    func write(_ message: Data, timeout: Duration) async throws -> Int {
        try await connection.write(message, timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        try await connection.close(timeout: timeout)
    }
}

private enum GELFTCPServiceWireDuration {
    static func nanoseconds(from duration: Duration) throws -> UInt64 {
        guard duration > .zero else {
            throw GELFTCPServiceWireError.invalidTimeout
        }
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw GELFTCPServiceWireError.invalidTimeout
        }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (whole, wholeOverflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        let (result, resultOverflow) = whole.addingReportingOverflow(nanoseconds)
        guard !wholeOverflow, !resultOverflow, result > 0 else {
            throw GELFTCPServiceWireError.invalidTimeout
        }
        return result
    }
}
