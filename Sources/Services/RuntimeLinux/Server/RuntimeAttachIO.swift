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

import Containerization
import Foundation
import Synchronization

/// A process input stream that accepts one or more short-lived client sessions.
///
/// The initial process keeps one guest-side stdin pipe for its entire lifetime.
/// Clients may come and go without closing that pipe, which is the distinction
/// between reattaching and replacing a running process's standard input.
final class AttachableInput: ReaderStream, @unchecked Sendable {
    private struct State {
        var handles: [UUID: FileHandle] = [:]
        var finished = false
    }

    private let state = Mutex(State())
    private let streamStorage: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init(initial: FileHandle? = nil) {
        let pair = AsyncStream<Data>.makeStream()
        streamStorage = pair.stream
        continuation = pair.continuation
        if let initial {
            add(initial)
        }
    }

    func stream() -> AsyncStream<Data> {
        streamStorage
    }

    /// Registers a client-owned read handle. End-of-file detaches that client
    /// only; it does not close the process stdin stream.
    func add(_ handle: FileHandle) {
        let identifier = UUID()
        let accepted = state.withLock { state in
            guard !state.finished else {
                return false
            }
            state.handles[identifier] = handle
            return true
        }
        guard accepted else {
            try? handle.close()
            return
        }

        handle.readabilityHandler = { [weak self, weak handle] _ in
            guard let self, let handle else {
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                self.remove(identifier, close: true)
                return
            }
            self.continuation.yield(data)
        }
    }

    func close() {
        let handles = state.withLock { state -> [FileHandle] in
            guard !state.finished else {
                return []
            }
            state.finished = true
            let values = Array(state.handles.values)
            state.handles.removeAll()
            return values
        }
        for handle in handles {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        continuation.finish()
    }

    private func remove(_ identifier: UUID, close: Bool) {
        let handle = state.withLock { state in
            state.handles.removeValue(forKey: identifier)
        }
        guard close, let handle else {
            return
        }
        handle.readabilityHandler = nil
        try? handle.close()
    }
}

/// A process output writer that keeps durable log capture while allowing
/// additional XPC clients to join and leave a running process's output.
final class AttachableOutput: Writer, @unchecked Sendable {
    private struct State {
        var persistentWriters: [any Writer]
        var clients: [UUID: FileHandle] = [:]
        var closed = false
    }

    private let state: Mutex<State>

    init(initial: FileHandle? = nil, persistent: (any Writer)? = nil) {
        var clients: [UUID: FileHandle] = [:]
        if let initial {
            clients[UUID()] = initial
        }
        state = Mutex(
            State(
                persistentWriters: persistent.map { [$0] } ?? [],
                clients: clients
            ))
    }

    /// Adds one output sink for an attached client.
    func add(_ handle: FileHandle) {
        let accepted = state.withLock { state in
            guard !state.closed else {
                return false
            }
            state.clients[UUID()] = handle
            return true
        }
        if !accepted {
            try? handle.close()
        }
    }

    func write(_ data: Data) throws {
        let snapshot = state.withLock { state in
            (state.persistentWriters, state.clients)
        }

        for writer in snapshot.0 {
            try writer.write(data)
        }

        var failed = [UUID]()
        for (identifier, handle) in snapshot.1 {
            do {
                try handle.write(contentsOf: data)
            } catch {
                failed.append(identifier)
            }
        }
        remove(failed)
    }

    func close() throws {
        let snapshot = state.withLock { state -> ([any Writer], [FileHandle]) in
            guard !state.closed else {
                return ([], [])
            }
            state.closed = true
            let writers = state.persistentWriters
            state.persistentWriters.removeAll()
            let clients = Array(state.clients.values)
            state.clients.removeAll()
            return (writers, clients)
        }

        var firstError: Error?
        for writer in snapshot.0 {
            do {
                try writer.close()
            } catch {
                firstError = firstError ?? error
            }
        }
        for handle in snapshot.1 {
            try? handle.close()
        }
        if let firstError {
            throw firstError
        }
    }

    private func remove(_ identifiers: [UUID]) {
        guard !identifiers.isEmpty else {
            return
        }
        let handles = state.withLock { state in
            identifiers.compactMap { state.clients.removeValue(forKey: $0) }
        }
        for handle in handles {
            try? handle.close()
        }
    }
}
