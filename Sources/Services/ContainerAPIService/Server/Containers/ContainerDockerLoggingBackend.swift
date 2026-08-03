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

import ContainerEngineLogging
import ContainerLoggingStorage
import ContainerResource
import ContainerizationError
import Foundation

struct ContainerEngineLoggingInspection: Sendable {
    let driver: String
    let options: [String: String]
    let publicLogPath: String?
    let terminal: Bool
}

enum ContainerEngineLogReadSource: Sendable {
    case direct(reader: any ContainerLogReader, terminal: Bool)
    case activeWire(file: FileHandle, terminal: Bool)
}

/// Projects the authority-owned Container logging controller onto the neutral
/// Docker Engine logging backend. It never opens a second catalog, store, or
/// provider session and therefore cannot diverge from native clients.
public struct ContainerDockerLoggingBackend: DockerLoggingBackend, Sendable {
    private let containers: ContainersService

    public init(containers: ContainersService) {
        self.containers = containers
    }

    public func loggingSystemInfo() async throws -> DockerLoggingSystemInfo {
        do {
            let info = try await containers.engineLoggingSystemInfo()
            return DockerLoggingSystemInfo(
                defaultDriver: info.defaultDriver,
                registeredDrivers: info.registeredDrivers
            )
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

    public func inspectContainerLogging(
        containerID: String
    ) async throws -> DockerContainerLoggingInspection {
        do {
            let inspection = try await containers.engineLoggingInspection(
                containerID: containerID
            )
            return DockerContainerLoggingInspection(
                configuration: DockerResolvedLogConfiguration(
                    driver: inspection.driver,
                    options: inspection.options
                ),
                publicLogPath: inspection.publicLogPath,
                terminal: inspection.terminal
            )
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func openContainerLogs(
        containerID: String,
        request: DockerLogReadRequest
    ) async throws -> any DockerLogReadSession {
        do {
            let source = try await containers.engineLogReadSource(
                containerID: containerID,
                request: try Self.containerRequest(request)
            )
            switch source {
            case .direct(let reader, let terminal):
                return DirectDockerLogReadSession(
                    reader: reader,
                    terminal: terminal
                )
            case .activeWire(let file, let terminal):
                return WireDockerLogReadSession(
                    file: file,
                    terminal: terminal
                )
            }
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    public func attachContainer(
        containerID: String,
        request: DockerAttachRequest
    ) async throws -> DockerAttachConnection {
        _ = containerID
        _ = request
        // The enhanced provider declaration deliberately omits ContainerAttach
        // until historical replay plus live-stream handoff can be made atomic.
        throw DockerLoggingBackendError.server(
            "container attach is not advertised by this provider"
        )
    }

    private static func containerRequest(
        _ request: DockerLogReadRequest
    ) throws -> ContainerLogReadRequest {
        try ContainerLogReadRequest(
            stdout: request.stdout,
            stderr: request.stderr,
            follow: request.follow,
            tail: request.tail,
            since: request.since.map(Self.date),
            until: request.until.map(Self.date),
            timestamps: request.timestamps,
            details: request.details
        )
    }

    private static func date(_ timestamp: DockerLogTimestamp) -> Date {
        Date(
            timeIntervalSince1970:
                Double(timestamp.secondsSinceUnixEpoch)
                + Double(timestamp.nanoseconds) / 1_000_000_000
        )
    }

    fileprivate static func map(
        _ error: any Error,
        containerID: String?
    ) -> DockerLoggingBackendError {
        if let error = error as? DockerLoggingBackendError {
            return error
        }
        if let error = error as? ContainerizationError {
            switch error.code {
            case .notFound:
                return .containerNotFound(containerID ?? "")
            case .invalidArgument:
                return .invalidParameter("invalid logging request")
            case .invalidState:
                return .conflict("container logging state does not permit this operation")
            default:
                return .server("container logging operation failed")
            }
        }
        if let error = error as? ContainerLogReaderError {
            switch error {
            case .configuredDriverDoesNotSupportReading:
                return .unsupportedLogReader
            case .activeReaderRequired:
                return .conflict("active container logging reader is required")
            default:
                return .server("container logging reader failed")
            }
        }
        if let error = error as? ContainerLogNativeReaderFactoryError {
            switch error {
            case .providerReaderRequired:
                return .unsupportedLogReader
            default:
                return .server("container logging reader failed")
            }
        }
        if error is LogDriverLifecycleContractError {
            return .invalidParameter("invalid logging request")
        }
        return .server("container logging operation failed")
    }
}

private actor DirectDockerLogReadSession: DockerLogReadSession {
    nonisolated let terminal: Bool

    private let reader: any ContainerLogReader
    private var ended = false

    init(reader: any ContainerLogReader, terminal: Bool) {
        self.reader = reader
        self.terminal = terminal
    }

    func nextRecord() async throws -> DockerLogRecord? {
        guard !ended else {
            return nil
        }
        do {
            switch try await reader.next() {
            case .record(let record):
                return try Self.dockerRecord(record)
            case .endOfStream:
                ended = true
                return nil
            }
        } catch {
            throw ContainerDockerLoggingBackend.map(
                error,
                containerID: nil
            )
        }
    }

    func close() async {
        guard !ended else {
            return
        }
        ended = true
        await reader.cancel()
    }

    func cancel() async {
        await close()
    }

    private static func dockerRecord(
        _ record: ContainerLogReadRecordV1
    ) throws -> DockerLogRecord {
        try DockerLogRecord(
            source: record.stream == .stdout
                ? .standardOutput
                : .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: record.timestamp.secondsSinceUnixEpoch,
                nanoseconds: record.timestamp.nanoseconds
            ),
            line: record.data,
            attributes: record.attributes
        )
    }
}

actor WireDockerLogReadSession: DockerLogReadSession {
    nonisolated let terminal: Bool

    private static let readChunkBytes = 64 * 1_024

    private let file: FileHandle
    private var buffer = Data()
    private var ended = false

    init(file: FileHandle, terminal: Bool) {
        self.file = file
        self.terminal = terminal
    }

    deinit {
        try? file.close()
    }

    func nextRecord() async throws -> DockerLogRecord? {
        guard !ended else {
            return nil
        }
        guard let encoded = try await nextEncodedRecord() else {
            ended = true
            try? file.close()
            return nil
        }
        do {
            let wire = try JSONDecoder().decode(
                ContainerLogReadRecordWireV1.self,
                from: encoded
            )
            return try Self.dockerRecord(wire.record())
        } catch {
            throw ContainerDockerLoggingBackend.map(
                error,
                containerID: nil
            )
        }
    }

    func close() async {
        guard !ended else {
            return
        }
        ended = true
        try? file.close()
    }

    func cancel() async {
        await close()
    }

    private func nextEncodedRecord() async throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                guard
                    newline
                        <= ContainerLogReadRecordWireV1
                        .maximumEncodedRecordBytes
                else {
                    throw DockerLoggingBackendError.server(
                        "container logging record exceeds the transport limit"
                    )
                }
                let record = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !record.isEmpty else {
                    continue
                }
                return record
            }
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
            else {
                throw DockerLoggingBackendError.server(
                    "container logging record exceeds the transport limit"
                )
            }
            let file = self.file
            let chunk = try await Task.detached(priority: .utility) {
                try file.read(upToCount: Self.readChunkBytes) ?? Data()
            }.value
            if chunk.isEmpty {
                guard buffer.isEmpty else {
                    throw DockerLoggingBackendError.server(
                        "container logging stream ended with a partial record"
                    )
                }
                return nil
            }
            buffer.append(chunk)
            guard
                buffer.count
                    <= ContainerLogReadRecordWireV1.maximumEncodedRecordBytes
                    + Self.readChunkBytes
            else {
                throw DockerLoggingBackendError.server(
                    "container logging record exceeds the transport limit"
                )
            }
        }
    }

    private static func dockerRecord(
        _ record: ContainerLogReadRecordV1
    ) throws -> DockerLogRecord {
        try DockerLogRecord(
            source: record.stream == .stdout
                ? .standardOutput
                : .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: record.timestamp.secondsSinceUnixEpoch,
                nanoseconds: record.timestamp.nanoseconds
            ),
            line: record.data,
            attributes: record.attributes
        )
    }
}
