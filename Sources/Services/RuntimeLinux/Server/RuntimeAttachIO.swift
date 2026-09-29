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
/// A client may explicitly own stdin EOF; its drained descriptor then finishes
/// only this input generation, without a later container-ID lookup.
final class AttachableInput: ReaderStream, @unchecked Sendable {
    private struct State {
        var handles: [UUID: FileHandle] = [:]
        var finished = false
    }

    private let state = Mutex(State())
    private let streamStorage: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init(initial: FileHandle? = nil, closeOnEOF: Bool = false) {
        let pair = AsyncStream<Data>.makeStream()
        streamStorage = pair.stream
        continuation = pair.continuation
        if let initial {
            add(initial, closeOnEOF: closeOnEOF)
        }
    }

    func stream() -> AsyncStream<Data> {
        streamStorage
    }

    /// Registers a client-owned read handle. By default EOF detaches only that
    /// client; explicit ownership finishes guest stdin after queued bytes drain.
    func add(_ handle: FileHandle, closeOnEOF: Bool = false) {
        let identifier = UUID()
        let accepted = state.withLock { state in
            guard !state.finished else {
                return false
            }
            state.handles[identifier] = handle
            // Registration and closure share the same lifecycle lock. A queued
            // callback resolves its handle under that lock instead of retaining
            // a descriptor which another client's EOF may already have closed.
            handle.readabilityHandler = { [weak self] _ in
                self?.read(identifier, closeOnEOF: closeOnEOF)
            }
            return true
        }
        guard accepted else {
            try? handle.close()
            return
        }

    }

    func close() {
        closeHandles(state.withLock { finish(&$0) })
    }

    private func read(_ identifier: UUID, closeOnEOF: Bool) {
        let handles = state.withLock { state -> [FileHandle] in
            guard let handle = state.handles[identifier] else { return [] }
            let data = handle.availableData
            if !data.isEmpty {
                continuation.yield(data)
                return []
            }
            // Read EOF orders completion after all bytes from this client.
            // A separate close RPC could discard bytes still in its socket.
            if closeOnEOF {
                return finish(&state)
            }
            state.handles.removeValue(forKey: identifier)
            return [handle]
        }
        closeHandles(handles)
    }

    /// Called with the state lock, after all earlier reads have been yielded.
    private func finish(_ state: inout State) -> [FileHandle] {
        guard !state.finished else { return [] }
        state.finished = true
        let handles = Array(state.handles.values)
        state.handles.removeAll()
        continuation.finish()
        return handles
    }

    private func closeHandles(_ handles: [FileHandle]) {
        for handle in handles {
            handle.readabilityHandler = nil
            try? handle.close()
        }
    }
}

/// A process output writer that keeps durable log capture while allowing
/// additional XPC clients to join and leave a running process's output.
enum AttachableOutputPersistentFailure: Equatable, Sendable {
    case write
    case close
}

final class AttachableOutput: Writer, @unchecked Sendable {
    private struct State {
        var persistentWriters: [any Writer]
        var clients: [UUID: FileHandle] = [:]
        var closed = false
    }

    private let state: Mutex<State>
    private let persistentFailureHandler: @Sendable (AttachableOutputPersistentFailure) -> Void

    init(
        initial: FileHandle? = nil,
        persistent: (any Writer)? = nil,
        persistentFailureHandler: @escaping @Sendable (AttachableOutputPersistentFailure) -> Void = { _ in }
    ) {
        var clients: [UUID: FileHandle] = [:]
        if let initial {
            clients[UUID()] = initial
        }
        state = Mutex(
            State(
                persistentWriters: persistent.map { [$0] } ?? [],
                clients: clients
            ))
        self.persistentFailureHandler = persistentFailureHandler
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

        var failed = [UUID]()
        for (identifier, handle) in snapshot.1 {
            do {
                try handle.write(contentsOf: data)
            } catch {
                failed.append(identifier)
            }
        }
        remove(failed)

        // Live attach is a distinct output path. A slow blocking driver still
        // applies backpressure after this write, but a driver error can never
        // suppress bytes which the process already produced for attached
        // clients.
        for writer in snapshot.0 {
            do {
                try writer.write(data)
            } catch {
                persistentFailureHandler(.write)
            }
        }
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

        // Publish EOF to attached clients before a driver drain or close can
        // block runtime cleanup.
        for handle in snapshot.1 {
            try? handle.close()
        }
        for writer in snapshot.0 {
            do {
                try writer.close()
            } catch {
                persistentFailureHandler(.close)
            }
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
