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
import Darwin
import Foundation

public enum JournaldServiceDurableStateError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt32)
    case generationMismatch(expected: UInt64, actual: UInt64)
    case capacityExceeded(collection: String, maximum: Int)
    case stateTooLarge(Int)
    case corruptState
}

public enum JournaldServiceDurableStateLimitsV1 {
    public static let maximumWriters = 4_096
    public static let maximumReaders = 4_096
    public static let maximumStateBytes = 64 * 1_024 * 1_024
}

public protocol JournaldServiceDurableStateStoreV1: Sendable {
    func load() async throws -> Data?
    func save(_ state: Data) async throws
}

/// Atomic private-file store used by the Linux service workload.
public actor JournaldServiceFileStateStoreV1:
    JournaldServiceDurableStateStoreV1
{
    private let url: URL

    public init(url: URL) throws {
        guard url.isFileURL else {
            throw JournaldServiceDurableStateError.corruptState
        }
        self.url = url.standardizedFileURL
    }

    public func load() throws -> Data? {
        guard try stateFileExists() else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= JournaldServiceDurableStateLimitsV1.maximumStateBytes else {
            throw JournaldServiceDurableStateError.stateTooLarge(data.count)
        }
        return data
    }

    public func save(_ state: Data) throws {
        guard state.count <= JournaldServiceDurableStateLimitsV1.maximumStateBytes else {
            throw JournaldServiceDurableStateError.stateTooLarge(state.count)
        }
        _ = try stateFileExists()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )
        try state.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func stateFileExists() throws -> Bool {
        var attributes = stat()
        if lstat(url.path, &attributes) == 0 {
            guard attributes.st_mode & S_IFMT == S_IFREG else {
                throw JournaldServiceDurableStateError.corruptState
            }
            return true
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return false
    }
}

public struct JournaldJournalEntryIdentityV1:
    Codable, Equatable, Hashable, Sendable
{
    public let sessionID: String
    public let epoch: String
    public let ordinal: UInt64

    public init(sessionID: String, epoch: String, ordinal: UInt64) throws {
        guard !sessionID.isEmpty, !epoch.isEmpty, ordinal > 0 else {
            throw JournaldProviderError.invalidJournalEntry
        }
        self.sessionID = sessionID
        self.epoch = epoch
        self.ordinal = ordinal
    }
}

public enum JournaldJournalAppendDispositionV1: Equatable, Sendable {
    case appended
    case alreadyPresent
}

/// System-journal boundary. `append` must atomically return `alreadyPresent`
/// for the same identity and byte-identical entry, and throw
/// `idempotencyConflict` if that identity exists with different bytes. `read`
/// must return the same event for an identical request and sequence so a state
/// persistence failure can be reconciled without advancing the journal cursor.
public protocol JournaldJournalAdapterV1: Sendable {
    func append(
        identity: JournaldJournalEntryIdentityV1,
        entry: JournaldEntry
    ) async throws -> JournaldJournalAppendDispositionV1
    func flush(timeoutNanoseconds: UInt64) async throws
    func read(
        request: LogDriverReaderOpenRequestV1,
        sequence: UInt64
    ) async throws -> ContainerLogReaderEventV1
    func cancelReader(sessionID: String) async
}

/// Restart-safe writer and reader state behind the journald protocol engine.
public actor JournaldServiceDurableBackendV1: JournaldServiceBackendV1 {
    private static let currentSchemaVersion: UInt32 = 1

    private enum WriterPhase: String, Codable {
        case active
        case fenced
        case closed
    }

    private enum ReaderPhase: String, Codable {
        case active
        case ended
        case cancelled
    }

    private struct PendingEntry: Codable, Equatable {
        let identity: JournaldJournalEntryIdentityV1
        let entry: JournaldEntryWireV1
    }

    private struct WriterState: Codable, Equatable {
        let open: JournaldWriterOpenWireV1
        var phase: WriterPhase
        var closeFenced: Bool?
        var nextOrdinal: UInt64
        var pending: PendingEntry?
        var lastCommitted: PendingEntry?
    }

    private struct ReaderState: Codable, Equatable {
        let open: LogDriverReaderOpenRequestV1
        var phase: ReaderPhase
        var nextSequence: UInt64
        var lastSequence: UInt64?
        var lastEvent: JournaldServiceReaderEventWireV1?
    }

    private struct Snapshot: Codable, Equatable {
        let schemaVersion: UInt32
        let sandboxGeneration: UInt64
        var writers: [String: WriterState]
        var readers: [String: ReaderState]
    }

    private let sandboxGeneration: UInt64
    private let stateStore: any JournaldServiceDurableStateStoreV1
    private let journal: any JournaldJournalAdapterV1
    private var snapshot: Snapshot
    private var persistenceFailed = false

    private init(
        sandboxGeneration: UInt64,
        stateStore: any JournaldServiceDurableStateStoreV1,
        journal: any JournaldJournalAdapterV1,
        snapshot: Snapshot
    ) {
        self.sandboxGeneration = sandboxGeneration
        self.stateStore = stateStore
        self.journal = journal
        self.snapshot = snapshot
    }

    public static func load(
        sandboxGeneration: UInt64,
        stateStore: any JournaldServiceDurableStateStoreV1,
        journal: any JournaldJournalAdapterV1
    ) async throws -> JournaldServiceDurableBackendV1 {
        guard sandboxGeneration > 0 else {
            throw JournaldProviderError.invalidSessionFence
        }
        let snapshot: Snapshot
        if let data = try await stateStore.load() {
            do {
                snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            } catch let error as JournaldServiceDurableStateError {
                throw error
            } catch {
                throw JournaldServiceDurableStateError.corruptState
            }
            guard snapshot.schemaVersion == currentSchemaVersion else {
                throw JournaldServiceDurableStateError.unsupportedSchemaVersion(
                    snapshot.schemaVersion
                )
            }
            guard snapshot.sandboxGeneration == sandboxGeneration else {
                throw JournaldServiceDurableStateError.generationMismatch(
                    expected: sandboxGeneration,
                    actual: snapshot.sandboxGeneration
                )
            }
            try validate(snapshot)
        } else {
            snapshot = Snapshot(
                schemaVersion: currentSchemaVersion,
                sandboxGeneration: sandboxGeneration,
                writers: [:],
                readers: [:]
            )
            try await stateStore.save(try encode(snapshot))
        }
        return JournaldServiceDurableBackendV1(
            sandboxGeneration: sandboxGeneration,
            stateStore: stateStore,
            journal: journal,
            snapshot: snapshot
        )
    }

    public func activeSandboxGeneration() -> UInt64 {
        sandboxGeneration
    }

    public func openWriter(_ request: JournaldWriterOpenRequest) async throws {
        try requireHealthyPersistence()
        guard request.request.candidateSandboxGeneration == sandboxGeneration else {
            throw JournaldProviderError.invalidSessionFence
        }
        let wire = try JournaldWriterOpenWireV1(request)
        let sessionID = request.request.sessionID
        if let existing = snapshot.writers[sessionID] {
            guard existing.open == wire else {
                throw JournaldProviderError.idempotencyConflict
            }
            return
        }
        guard snapshot.writers.count < JournaldServiceDurableStateLimitsV1.maximumWriters else {
            throw JournaldServiceDurableStateError.capacityExceeded(
                collection: "writers",
                maximum: JournaldServiceDurableStateLimitsV1.maximumWriters
            )
        }
        var candidate = snapshot
        candidate.writers[sessionID] = WriterState(
            open: wire,
            phase: .active,
            closeFenced: nil,
            nextOrdinal: 1,
            pending: nil,
            lastCommitted: nil
        )
        try await commit(candidate)
    }

    public func write(sessionID: String, entry: JournaldEntry) async throws {
        try requireHealthyPersistence()
        guard var writer = snapshot.writers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        guard writer.phase == .active else {
            throw JournaldProviderError.invalidSessionFence
        }
        let open = try writer.open.value()
        let identity = try Self.identity(
            sessionID: sessionID,
            entry: entry,
            open: open
        )
        let pending = PendingEntry(
            identity: identity,
            entry: try JournaldEntryWireV1(entry)
        )

        if let last = writer.lastCommitted,
            identity.ordinal == last.identity.ordinal
        {
            guard last == pending else {
                throw JournaldProviderError.idempotencyConflict
            }
            return
        }
        if let existing = writer.pending {
            guard existing == pending else {
                throw JournaldProviderError.idempotencyConflict
            }
        } else {
            guard identity.ordinal == writer.nextOrdinal else {
                throw JournaldProviderError.idempotencyConflict
            }
            writer.pending = pending
            var candidate = snapshot
            candidate.writers[sessionID] = writer
            try await commit(candidate)
        }

        _ = try await journal.append(identity: identity, entry: entry)
        writer = snapshot.writers[sessionID] ?? writer
        writer.pending = nil
        writer.lastCommitted = pending
        let next = identity.ordinal.addingReportingOverflow(1)
        guard !next.overflow else {
            throw JournaldProviderError.invalidJournalEntry
        }
        writer.nextOrdinal = next.partialValue
        var candidate = snapshot
        candidate.writers[sessionID] = writer
        try await commit(candidate)
    }

    public func flushWriter(
        sessionID: String,
        timeoutNanoseconds: UInt64
    ) async throws {
        try requireHealthyPersistence()
        guard let writer = snapshot.writers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        guard writer.pending == nil else {
            throw JournaldProviderError.idempotencyConflict
        }
        guard writer.phase != .closed else {
            return
        }
        try await journal.flush(timeoutNanoseconds: timeoutNanoseconds)
    }

    public func closeWriter(
        sessionID: String,
        fenced: Bool,
        timeoutNanoseconds: UInt64
    ) async throws {
        try requireHealthyPersistence()
        guard var writer = snapshot.writers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        guard writer.pending == nil else {
            throw JournaldProviderError.idempotencyConflict
        }
        if writer.phase == .closed {
            guard writer.closeFenced == fenced else {
                throw JournaldProviderError.idempotencyConflict
            }
            return
        }
        if let closeFenced = writer.closeFenced {
            guard closeFenced == fenced else {
                throw JournaldProviderError.idempotencyConflict
            }
        } else {
            writer.phase = .fenced
            writer.closeFenced = fenced
            var candidate = snapshot
            candidate.writers[sessionID] = writer
            try await commit(candidate)
        }
        try await journal.flush(timeoutNanoseconds: timeoutNanoseconds)
        writer = snapshot.writers[sessionID] ?? writer
        writer.phase = .closed
        var candidate = snapshot
        candidate.writers[sessionID] = writer
        try await commit(candidate)
    }

    public func openReader(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> UInt64 {
        try requireHealthyPersistence()
        if let existing = snapshot.readers[request.readerSessionID] {
            guard existing.open == request else {
                throw JournaldProviderError.idempotencyConflict
            }
            return existing.nextSequence
        }
        try validateNewReaderSource(request)
        guard snapshot.readers.count < JournaldServiceDurableStateLimitsV1.maximumReaders else {
            throw JournaldServiceDurableStateError.capacityExceeded(
                collection: "readers",
                maximum: JournaldServiceDurableStateLimitsV1.maximumReaders
            )
        }
        var candidate = snapshot
        candidate.readers[request.readerSessionID] = ReaderState(
            open: request,
            phase: .active,
            nextSequence: 1,
            lastSequence: nil,
            lastEvent: nil
        )
        try await commit(candidate)
        return 1
    }

    public func nextReader(
        sessionID: String,
        sequence: UInt64
    ) async throws -> ContainerLogReaderEventV1 {
        try requireHealthyPersistence()
        guard var reader = snapshot.readers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        if reader.lastSequence == sequence, let lastEvent = reader.lastEvent {
            return try Self.event(lastEvent)
        }
        guard reader.phase == .active, reader.nextSequence == sequence else {
            throw JournaldProviderError.idempotencyConflict
        }

        let event = try await journal.read(
            request: reader.open,
            sequence: sequence
        )
        guard let current = snapshot.readers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        if current.phase == .cancelled {
            throw ContainerLogReaderError.cancelled
        }
        if current.lastSequence == sequence, let lastEvent = current.lastEvent {
            return try Self.event(lastEvent)
        }
        guard current.phase == .active, current.nextSequence == sequence else {
            throw JournaldProviderError.idempotencyConflict
        }
        reader = current
        reader.lastSequence = sequence
        switch event {
        case .record(let record):
            reader.lastEvent = .record(ContainerLogReadRecordWireV1(record))
            let next = sequence.addingReportingOverflow(1)
            guard !next.overflow else {
                throw JournaldProviderError.invalidJournalEntry
            }
            reader.nextSequence = next.partialValue
        case .endOfStream:
            reader.lastEvent = .endOfStream
            reader.phase = .ended
        }
        var candidate = snapshot
        candidate.readers[sessionID] = reader
        try await commit(candidate)
        return event
    }

    public func cancelReader(sessionID: String) async throws {
        try requireHealthyPersistence()
        guard var reader = snapshot.readers[sessionID] else {
            throw JournaldProviderError.unknownSession
        }
        guard reader.phase == .active else {
            return
        }
        reader.phase = .cancelled
        var candidate = snapshot
        candidate.readers[sessionID] = reader
        try await commit(candidate)
        await journal.cancelReader(sessionID: sessionID)
    }

    private func commit(_ candidate: Snapshot) async throws {
        try requireHealthyPersistence()
        do {
            try await stateStore.save(try Self.encode(candidate))
            snapshot = candidate
        } catch {
            persistenceFailed = true
            throw error
        }
    }

    private func requireHealthyPersistence() throws {
        guard !persistenceFailed else {
            throw JournaldServiceDurableStateError.corruptState
        }
    }

    private func validateNewReaderSource(
        _ request: LogDriverReaderOpenRequestV1
    ) throws {
        guard
            case .activeWriter(
                let sessionID,
                let providerID,
                let providerGeneration,
                let processGeneration,
                let activeSandboxGeneration
            ) = request.source
        else {
            return
        }
        guard
            activeSandboxGeneration == sandboxGeneration,
            let writer = snapshot.writers[sessionID],
            writer.phase == .active,
            let open = try? writer.open.value(),
            open.request.containerID == request.containerID,
            open.request.leaseGeneration == request.leaseGeneration,
            open.request.providerID == providerID,
            open.request.providerGeneration == providerGeneration,
            open.request.candidateProcessGeneration == processGeneration
        else {
            throw JournaldProviderError.invalidSessionFence
        }
    }

    private static func encode(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard
            snapshot.writers.count
                <= JournaldServiceDurableStateLimitsV1.maximumWriters,
            snapshot.readers.count
                <= JournaldServiceDurableStateLimitsV1.maximumReaders
        else {
            throw JournaldServiceDurableStateError.corruptState
        }
        for (sessionID, writer) in snapshot.writers {
            let open = try writer.open.value()
            guard
                open.request.sessionID == sessionID,
                open.request.candidateSandboxGeneration
                    == snapshot.sandboxGeneration,
                writer.nextOrdinal > 0,
                (writer.phase == .active) == (writer.closeFenced == nil),
                writer.phase == .active || writer.pending == nil
            else {
                throw JournaldServiceDurableStateError.corruptState
            }
            if let pending = writer.pending {
                guard
                    pending.identity.sessionID == sessionID,
                    pending.identity.epoch == open.epoch,
                    pending.identity.ordinal == writer.nextOrdinal,
                    try identity(
                        sessionID: sessionID,
                        entry: pending.entry.entry(),
                        open: open
                    ) == pending.identity
                else {
                    throw JournaldServiceDurableStateError.corruptState
                }
            }
            if let committed = writer.lastCommitted {
                let next = committed.identity.ordinal.addingReportingOverflow(1)
                guard
                    !next.overflow,
                    next.partialValue == writer.nextOrdinal,
                    committed.identity.sessionID == sessionID,
                    committed.identity.epoch == open.epoch,
                    try identity(
                        sessionID: sessionID,
                        entry: committed.entry.entry(),
                        open: open
                    ) == committed.identity
                else {
                    throw JournaldServiceDurableStateError.corruptState
                }
            } else if writer.nextOrdinal != 1 {
                throw JournaldServiceDurableStateError.corruptState
            }
        }
        for (sessionID, reader) in snapshot.readers {
            guard
                reader.open.readerSessionID == sessionID,
                reader.nextSequence > 0,
                (reader.lastSequence == nil) == (reader.lastEvent == nil)
            else {
                throw JournaldServiceDurableStateError.corruptState
            }
            guard let sequence = reader.lastSequence,
                let event = reader.lastEvent
            else {
                guard
                    reader.phase != .ended,
                    reader.nextSequence == 1
                else {
                    throw JournaldServiceDurableStateError.corruptState
                }
                continue
            }
            switch event {
            case .record:
                let next = sequence.addingReportingOverflow(1)
                guard
                    !next.overflow,
                    next.partialValue == reader.nextSequence,
                    reader.phase != .ended
                else {
                    throw JournaldServiceDurableStateError.corruptState
                }
            case .endOfStream:
                guard
                    reader.nextSequence == sequence,
                    reader.phase == .ended
                else {
                    throw JournaldServiceDurableStateError.corruptState
                }
            }
        }
    }

    private static func identity(
        sessionID: String,
        entry: JournaldEntry,
        open: JournaldWriterOpenRequest
    ) throws -> JournaldJournalEntryIdentityV1 {
        guard
            entry.fields[JournaldField.logEpoch] == open.epoch,
            entry.fields[JournaldField.containerIDFull]
                == open.configuration.containerID,
            entry.processGeneration
                == open.request.candidateProcessGeneration,
            let ordinalText = entry.fields[JournaldField.logOrdinal],
            let ordinal = UInt64(ordinalText),
            ordinal > 0,
            ordinal < UInt64.max
        else {
            throw JournaldProviderError.invalidJournalEntry
        }
        return try JournaldJournalEntryIdentityV1(
            sessionID: sessionID,
            epoch: open.epoch,
            ordinal: ordinal
        )
    }

    private static func event(
        _ wire: JournaldServiceReaderEventWireV1
    ) throws -> ContainerLogReaderEventV1 {
        switch wire {
        case .record(let record):
            return .record(try record.record())
        case .endOfStream:
            return .endOfStream
        }
    }
}
