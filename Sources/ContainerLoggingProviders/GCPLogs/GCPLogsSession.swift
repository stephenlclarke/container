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

public enum GCPLogsSessionState: Equatable, Sendable {
    case active
    case closing
    case writerFenced
    case closed
}

/// Moby 29.2.1-compatible Google Cloud Logging session backed by the signed
/// helper and Google's official Go client.
public actor GCPLogsDriverSession: ContainerLogDriverSession {
    private let sessionID: String
    private let configuration: GCPLogsDriverConfiguration
    private let service: any DockerGCPLoggingServicing
    private var state: GCPLogsSessionState = .active

    public init(
        sessionID: String,
        configuration: GCPLogsDriverConfiguration,
        service: any DockerGCPLoggingServicing
    ) throws {
        self.sessionID = sessionID
        self.configuration = configuration
        self.service = service
        try service.startGCPLoggingSession(
            sessionID: sessionID,
            configuration: configuration.semanticConfiguration,
            info: configuration.dockerInfo,
            timeout: configuration.policy.startTimeout
        )
    }

    public func write(_ record: ContainerLogRecordV2) throws {
        guard state == .active else {
            throw GCPLogsProviderError.transportClosed
        }
        let timestamp = record.observation.wallClock
        try service.logGCPRecord(
            sessionID: sessionID,
            timestampSeconds: timestamp.secondsSinceUnixEpoch,
            timestampNanoseconds: timestamp.nanoseconds,
            line: record.payload,
            timeout: configuration.policy.requestTimeout
        )
    }

    public func flush(deadline: ContinuousClock.Instant) throws {
        guard state == .active else {
            throw GCPLogsProviderError.transportClosed
        }
        let timeout = try remaining(
            until: deadline,
            maximum: configuration.policy.closeTimeout,
            error: .flushTimedOut
        )
        try service.flushGCPLoggingSession(
            sessionID: sessionID,
            timeout: timeout
        )
    }

    public func close(deadline: ContinuousClock.Instant) throws {
        try close(terminalState: .closed, deadline: deadline)
    }

    public func closeUsingPolicy() throws {
        try close(
            terminalState: .closed,
            deadline: ContinuousClock().now.advanced(
                by: configuration.policy.closeTimeout
            )
        )
    }

    public func fence() throws {
        try close(
            terminalState: .writerFenced,
            deadline: ContinuousClock().now.advanced(
                by: configuration.policy.closeTimeout
            )
        )
    }

    public func currentState() -> GCPLogsSessionState { state }

    private func close(
        terminalState: GCPLogsSessionState,
        deadline: ContinuousClock.Instant
    ) throws {
        switch state {
        case .closed:
            return
        case .writerFenced:
            if terminalState == .closed {
                state = .closed
            }
            return
        case .closing:
            throw GCPLogsProviderError.transportClosed
        case .active:
            break
        }
        let timeout = try remaining(
            until: deadline,
            maximum: configuration.policy.closeTimeout,
            error: .closeTimedOut
        )
        state = .closing
        do {
            try service.closeGCPLoggingSession(
                sessionID: sessionID,
                timeout: timeout
            )
            state = terminalState
        } catch {
            state = terminalState
            throw error
        }
    }

    private func remaining(
        until deadline: ContinuousClock.Instant,
        maximum: Duration,
        error: GCPLogsProviderError
    ) throws -> Duration {
        let value = ContinuousClock().now.duration(to: deadline)
        guard value > .zero else { throw error }
        return min(value, maximum)
    }
}
