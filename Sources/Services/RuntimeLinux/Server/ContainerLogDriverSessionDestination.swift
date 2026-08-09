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
import Foundation

package enum ContainerLogDriverSessionDestinationError: Error, Equatable, Sendable {
    case closed
    case invalidCloseTimeout
}

package struct ContainerLogDriverSessionDestinationSnapshot: Equatable, Sendable {
    package let writeAttemptCount: UInt64
    package let writeSuccessCount: UInt64
    package let writeFailureCount: UInt64
    package let flushAttemptCount: UInt64
    package let flushFailureCount: UInt64
    package let closeAttemptCount: UInt64
    package let closeFailureCount: UInt64
    package let closing: Bool
    package let closed: Bool
}

/// Adapts an asynchronous provider session to Containerization's synchronous
/// process-output writer boundary.
///
/// Blocking delivery intentionally waits for each provider write before
/// returning to the guest-output copier. A single operation lock serializes
/// stdout and stderr records with flush and close, while provider write errors
/// remain per-record failures so a later record can still be delivered.
///
/// The provider owns enforcement of the supplied close deadline. The adapter
/// never returns while an asynchronous operation is still able to mutate the
/// session: an unresponsive provider must instead be fenced by the authority's
/// generation-bound lifecycle controller.
package final class ContainerLogDriverSessionDestination: ContainerLogRecordDestination,
    @unchecked Sendable
{
    private enum State {
        case open
        case closing
        case closed
    }

    private struct MutableState {
        var state: State = .open
        var terminalError: (any Error)?
        var writeAttemptCount: UInt64 = 0
        var writeSuccessCount: UInt64 = 0
        var writeFailureCount: UInt64 = 0
        var flushAttemptCount: UInt64 = 0
        var flushFailureCount: UInt64 = 0
        var closeAttemptCount: UInt64 = 0
        var closeFailureCount: UInt64 = 0
    }

    private let session: any ContainerLogDriverSession
    private let closeTimeout: Duration
    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var mutableState = MutableState()

    package init(
        session: any ContainerLogDriverSession,
        closeTimeout: Duration = .seconds(10)
    ) throws {
        guard closeTimeout > .zero else {
            throw ContainerLogDriverSessionDestinationError.invalidCloseTimeout
        }
        self.session = session
        self.closeTimeout = closeTimeout
    }

    deinit {
        try? close()
    }

    package func write(_ record: ContainerLogRecordV2) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        let isOpen = withState { state -> Bool in
            guard state.state == .open else {
                return false
            }
            Self.increment(&state.writeAttemptCount)
            return true
        }
        guard isOpen else {
            throw ContainerLogDriverSessionDestinationError.closed
        }

        do {
            try Self.waitForAsyncOperation { [session] in
                try await session.write(record)
            }
            withState { state in
                Self.increment(&state.writeSuccessCount)
            }
        } catch {
            withState { state in
                Self.increment(&state.writeFailureCount)
            }
            throw error
        }
    }

    package func close() throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        let replay = withState { state -> (isReplay: Bool, error: (any Error)?) in
            switch state.state {
            case .open:
                state.state = .closing
                return (false, nil)
            case .closing, .closed:
                return (true, state.terminalError)
            }
        }
        if replay.isReplay {
            if let error = replay.error {
                throw error
            }
            return
        }

        let deadline = ContinuousClock().now.advanced(by: closeTimeout)
        var firstError: (any Error)?

        withState { state in
            Self.increment(&state.flushAttemptCount)
        }
        do {
            try Self.waitForAsyncOperation { [session] in
                try await session.flush(deadline: deadline)
            }
        } catch {
            firstError = error
            withState { state in
                Self.increment(&state.flushFailureCount)
            }
        }

        withState { state in
            Self.increment(&state.closeAttemptCount)
        }
        do {
            try Self.waitForAsyncOperation { [session] in
                try await session.close(deadline: deadline)
            }
        } catch {
            if firstError == nil {
                firstError = error
            }
            withState { state in
                Self.increment(&state.closeFailureCount)
            }
        }

        withState { state in
            state.terminalError = firstError
            state.state = .closed
        }
        if let firstError {
            throw firstError
        }
    }

    package var snapshot: ContainerLogDriverSessionDestinationSnapshot {
        withState { state in
            ContainerLogDriverSessionDestinationSnapshot(
                writeAttemptCount: state.writeAttemptCount,
                writeSuccessCount: state.writeSuccessCount,
                writeFailureCount: state.writeFailureCount,
                flushAttemptCount: state.flushAttemptCount,
                flushFailureCount: state.flushFailureCount,
                closeAttemptCount: state.closeAttemptCount,
                closeFailureCount: state.closeFailureCount,
                closing: state.state == .closing,
                closed: state.state == .closed
            )
        }
    }

    private static func waitForAsyncOperation(
        _ operation: @escaping @Sendable () async throws -> Void
    ) throws {
        let completion = AsyncOperationCompletion()
        Task.detached {
            do {
                try await operation()
                completion.finish(.success(()))
            } catch {
                completion.finish(.failure(error))
            }
        }
        try completion.wait().get()
    }

    private func withState<Result>(
        _ body: (inout MutableState) throws -> Result
    ) rethrows -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body(&mutableState)
    }

    private static func increment(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}

private final class AsyncOperationCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Void, any Error>?

    func finish(_ result: Result<Void, any Error>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> Result<Void, any Error> {
        condition.lock()
        while result == nil {
            condition.wait()
        }
        let result = self.result!
        condition.unlock()
        return result
    }
}
