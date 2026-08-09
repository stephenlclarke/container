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

import Foundation
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct JournaldServiceDurableBackendTests {
    @Test func writerReconcilesJournalEffectAcrossBackendRestart() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal(
            failAfterFirstAppendEffect: true
        )
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let open = try journaldDurableWriterOpen()
        let entry = try journaldDurableEntry(ordinal: 1)
        try await backend.openWriter(open)

        await #expect(throws: JournaldDurableTestError.afterAppendEffect) {
            try await backend.write(sessionID: open.request.sessionID, entry: entry)
        }
        #expect(await journal.entryCount == 1)
        #expect(await journal.appendCallCount == 1)

        let recovered = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        try await recovered.write(
            sessionID: open.request.sessionID,
            entry: entry
        )
        #expect(await journal.entryCount == 1)
        #expect(await journal.appendCallCount == 2)

        try await recovered.write(
            sessionID: open.request.sessionID,
            entry: entry
        )
        #expect(await journal.appendCallCount == 2)
    }

    @Test func failedStateCommitRemainsRetryableWithoutDuplicateAppend() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal()
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let open = try journaldDurableWriterOpen()
        let entry = try journaldDurableEntry(ordinal: 1)
        try await backend.openWriter(open)
        await state.failSave(afterSuccessfulSaves: 1)

        await #expect(throws: JournaldDurableTestError.stateSave) {
            try await backend.write(sessionID: open.request.sessionID, entry: entry)
        }
        #expect(await journal.entryCount == 1)
        await #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try await backend.write(
                sessionID: open.request.sessionID,
                entry: entry
            )
        }

        let recovered = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        try await recovered.write(
            sessionID: open.request.sessionID,
            entry: entry
        )
        #expect(await journal.entryCount == 1)
        #expect(await journal.appendCallCount == 2)

        let committed = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        try await committed.write(
            sessionID: open.request.sessionID,
            entry: entry
        )
        #expect(await journal.appendCallCount == 2)
    }

    @Test func writerIdentityOrderingAndCloseFenceFailClosed() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal(blockFlush: true)
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let open = try journaldDurableWriterOpen()
        try await backend.openWriter(open)
        try await backend.openWriter(open)

        await #expect(throws: JournaldProviderError.idempotencyConflict) {
            try await backend.openWriter(
                journaldDurableWriterOpen(epoch: "different-epoch")
            )
        }
        await #expect(throws: JournaldProviderError.idempotencyConflict) {
            try await backend.write(
                sessionID: open.request.sessionID,
                entry: journaldDurableEntry(ordinal: 2)
            )
        }

        try await backend.write(
            sessionID: open.request.sessionID,
            entry: journaldDurableEntry(ordinal: 1)
        )
        await #expect(throws: JournaldProviderError.idempotencyConflict) {
            try await backend.write(
                sessionID: open.request.sessionID,
                entry: journaldDurableEntry(ordinal: 1, message: "changed")
            )
        }

        let close = Task {
            try await backend.closeWriter(
                sessionID: open.request.sessionID,
                fenced: false,
                timeoutNanoseconds: 1_000
            )
        }
        await journal.waitUntilFlushStarted()
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.write(
                sessionID: open.request.sessionID,
                entry: journaldDurableEntry(ordinal: 2)
            )
        }
        await journal.releaseFlush()
        try await close.value
        try await backend.closeWriter(
            sessionID: open.request.sessionID,
            fenced: false,
            timeoutNanoseconds: 1_000
        )
        #expect(await journal.flushCallCount == 1)
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.write(
                sessionID: open.request.sessionID,
                entry: journaldDurableEntry(ordinal: 2)
            )
        }
        await #expect(throws: JournaldProviderError.idempotencyConflict) {
            try await backend.closeWriter(
                sessionID: open.request.sessionID,
                fenced: true,
                timeoutNanoseconds: 1_000
            )
        }
    }

    @Test func readerResumesDurableSequenceAndReplaysLostResponse() async throws {
        let state = JournaldDurableMemoryStateStore()
        let firstRecord = try journaldDurableReadRecord(sequence: 1)
        let journal = JournaldDurableRecordingJournal(
            readerEvents: [
                1: .record(firstRecord),
                2: .endOfStream,
            ]
        )
        let request = try journaldDurableReaderOpen()
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        #expect(try await backend.openReader(request) == 1)
        #expect(
            try await backend.nextReader(
                sessionID: request.readerSessionID,
                sequence: 1
            ) == .record(firstRecord)
        )

        let recovered = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        #expect(try await recovered.openReader(request) == 2)
        #expect(await journal.prepareReaderCallCount == 1)
        #expect(
            try await recovered.nextReader(
                sessionID: request.readerSessionID,
                sequence: 1
            ) == .record(firstRecord)
        )
        #expect(await journal.readCallCount == 1)
        #expect(
            try await recovered.nextReader(
                sessionID: request.readerSessionID,
                sequence: 2
            ) == .endOfStream
        )

        let ended = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        #expect(try await ended.openReader(request) == 2)
        #expect(
            try await ended.nextReader(
                sessionID: request.readerSessionID,
                sequence: 2
            ) == .endOfStream
        )
        #expect(await journal.readCallCount == 2)
        #expect(
            await journal.readerCheckpoints
                == [nil, try journaldDurableCheckpoint(sequence: 1)]
        )
    }

    @Test func terminalSessionsReclaimDurablyAndActiveSessionsFailClosed() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal(
            readerEvents: [1: .endOfStream]
        )
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let writer = try journaldDurableWriterOpen()
        try await backend.openWriter(writer)
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.reclaimWriter(
                sessionID: writer.request.sessionID,
                providerID: writer.request.providerID,
                providerGeneration: writer.request.providerGeneration
            )
        }
        try await backend.closeWriter(
            sessionID: writer.request.sessionID,
            fenced: false,
            timeoutNanoseconds: 1_000
        )
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.reclaimWriter(
                sessionID: writer.request.sessionID,
                providerID: "wrong-provider",
                providerGeneration: writer.request.providerGeneration
            )
        }
        try await backend.reclaimWriter(
            sessionID: writer.request.sessionID,
            providerID: writer.request.providerID,
            providerGeneration: writer.request.providerGeneration
        )
        try await backend.reclaimWriter(
            sessionID: writer.request.sessionID,
            providerID: writer.request.providerID,
            providerGeneration: writer.request.providerGeneration
        )

        let reader = try journaldDurableReaderOpen()
        #expect(try await backend.openReader(reader) == 1)
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.reclaimReader(
                sessionID: reader.readerSessionID,
                providerID: reader.providerID,
                providerGeneration: reader.providerGeneration
            )
        }
        #expect(
            try await backend.nextReader(
                sessionID: reader.readerSessionID,
                sequence: 1
            ) == .endOfStream
        )
        try await backend.reclaimReader(
            sessionID: reader.readerSessionID,
            providerID: reader.providerID,
            providerGeneration: reader.providerGeneration
        )
        try await backend.reclaimReader(
            sessionID: reader.readerSessionID,
            providerID: reader.providerID,
            providerGeneration: reader.providerGeneration
        )

        let recovered = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        try await recovered.openWriter(writer)
        #expect(try await recovered.openReader(reader) == 1)
    }

    @Test func activeReaderSourceMustMatchDurableWriterFence() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal()
        let backend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let open = try journaldDurableWriterOpen()
        try await backend.openWriter(open)

        let staleSource = try journaldDurableActiveReaderSource(
            sandboxGeneration: 14
        )
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.openReader(
                journaldDurableReaderOpen(source: staleSource)
            )
        }

        let source = try journaldDurableActiveReaderSource(
            sandboxGeneration: 13
        )
        #expect(
            try await backend.openReader(
                journaldDurableReaderOpen(source: source)
            ) == 1
        )
        try await backend.closeWriter(
            sessionID: open.request.sessionID,
            fenced: true,
            timeoutNanoseconds: 1_000
        )
        await #expect(throws: JournaldProviderError.invalidSessionFence) {
            try await backend.openReader(
                journaldDurableReaderOpen(
                    readerSessionID: "reader-after-fence",
                    source: source
                )
            )
        }
    }

    @Test func readerCheckpointBoundsAndProgressFailClosed() async throws {
        #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try JournaldJournalReaderCheckpointV1(bytes: Data())
        }
        #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try JournaldJournalReaderCheckpointV1(
                bytes: Data(
                    repeating: 0,
                    count: JournaldServiceDurableStateLimitsV1
                        .maximumReaderCheckpointBytes + 1
                )
            )
        }

        let record = try journaldDurableReadRecord(sequence: 1)
        let stalledJournal = JournaldDurableRecordingJournal(
            readerEvents: [1: .record(record)],
            advanceRecordCheckpoint: false
        )
        let stalledRequest = try journaldDurableReaderOpen(
            readerSessionID: "stalled-reader"
        )
        let stalledBackend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: JournaldDurableMemoryStateStore(),
            journal: stalledJournal
        )
        #expect(try await stalledBackend.openReader(stalledRequest) == 1)
        await #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try await stalledBackend.nextReader(
                sessionID: stalledRequest.readerSessionID,
                sequence: 1
            )
        }

        let advancedEndJournal = JournaldDurableRecordingJournal(
            readerEvents: [1: .endOfStream],
            advanceEndCheckpoint: true
        )
        let advancedEndRequest = try journaldDurableReaderOpen(
            readerSessionID: "advanced-end-reader"
        )
        let advancedEndBackend = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: JournaldDurableMemoryStateStore(),
            journal: advancedEndJournal
        )
        #expect(try await advancedEndBackend.openReader(advancedEndRequest) == 1)
        await #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try await advancedEndBackend.nextReader(
                sessionID: advancedEndRequest.readerSessionID,
                sequence: 1
            )
        }
    }

    @Test func newSandboxGenerationResetsSessionsAndCorruptStateFailsClosed() async throws {
        let state = JournaldDurableMemoryStateStore()
        let journal = JournaldDurableRecordingJournal()
        let first = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 13,
            stateStore: state,
            journal: journal
        )
        let oldWriter = try journaldDurableWriterOpen()
        try await first.openWriter(oldWriter)

        let next = try await JournaldServiceDurableBackendV1.load(
            sandboxGeneration: 14,
            stateStore: state,
            journal: journal
        )
        #expect(await next.activeSandboxGeneration() == 14)
        await #expect(throws: JournaldProviderError.unknownSession) {
            try await next.write(
                sessionID: oldWriter.request.sessionID,
                entry: journaldDurableEntry(ordinal: 1)
            )
        }
        try await next.openWriter(
            journaldDurableWriterOpen(sandboxGeneration: 14)
        )

        await state.replace(
            with: Data(
                "{\"readers\":{},\"sandboxGeneration\":13,\"schemaVersion\":1,\"writers\":{}}"
                    .utf8
            )
        )
        await #expect(
            throws:
                JournaldServiceDurableStateError
                .unsupportedSchemaVersion(1)
        ) {
            try await JournaldServiceDurableBackendV1.load(
                sandboxGeneration: 13,
                stateStore: state,
                journal: journal
            )
        }

        await state.replace(with: Data("not-json".utf8))
        await #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try await JournaldServiceDurableBackendV1.load(
                sandboxGeneration: 13,
                stateStore: state,
                journal: journal
            )
        }
    }

    @Test func fileStoreIsPrivateAtomicAndRejectsSymbolicLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "journald-durable-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "private/state.json")
        let store = try JournaldServiceFileStateStoreV1(url: file)
        let expected = Data("state".utf8)

        try await store.save(expected)
        #expect(try await store.load() == expected)
        let parentAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        #expect(
            (parentAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )
        #expect(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )

        let target = root.appending(path: "target.json")
        try expected.write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: target
        )
        await #expect(throws: JournaldServiceDurableStateError.corruptState) {
            try await store.load()
        }
    }
}

private enum JournaldDurableTestError: Error {
    case afterAppendEffect
    case stateSave
}

private actor JournaldDurableMemoryStateStore:
    JournaldServiceDurableStateStoreV1
{
    private var data: Data?
    private var saveAttempts = 0
    private var failingSaveAttempt: Int?

    func load() -> Data? {
        data
    }

    func save(_ state: Data) throws {
        saveAttempts += 1
        if failingSaveAttempt == saveAttempts {
            failingSaveAttempt = nil
            throw JournaldDurableTestError.stateSave
        }
        data = state
    }

    func failSave(afterSuccessfulSaves count: Int) {
        failingSaveAttempt = saveAttempts + count + 1
    }

    func replace(with data: Data) {
        self.data = data
    }
}

private actor JournaldDurableRecordingJournal: JournaldJournalAdapterV1 {
    private var entries = [JournaldJournalEntryIdentityV1: JournaldEntry]()
    private let readerEvents: [UInt64: ContainerLogReaderEventV1]
    private let advanceRecordCheckpoint: Bool
    private let advanceEndCheckpoint: Bool
    private var failAfterFirstAppendEffect: Bool
    private let blockFlush: Bool
    private var flushStarted = false
    private var flushStartWaiters = [CheckedContinuation<Void, Never>]()
    private var flushContinuation: CheckedContinuation<Void, Never>?
    private(set) var appendCallCount = 0
    private(set) var flushCallCount = 0
    private(set) var prepareReaderCallCount = 0
    private(set) var readCallCount = 0
    private(set) var readerCheckpoints = [JournaldJournalReaderCheckpointV1?]()
    private(set) var cancelledReaders = Set<String>()

    init(
        failAfterFirstAppendEffect: Bool = false,
        blockFlush: Bool = false,
        readerEvents: [UInt64: ContainerLogReaderEventV1] = [:],
        advanceRecordCheckpoint: Bool = true,
        advanceEndCheckpoint: Bool = false
    ) {
        self.failAfterFirstAppendEffect = failAfterFirstAppendEffect
        self.blockFlush = blockFlush
        self.readerEvents = readerEvents
        self.advanceRecordCheckpoint = advanceRecordCheckpoint
        self.advanceEndCheckpoint = advanceEndCheckpoint
    }

    var entryCount: Int {
        entries.count
    }

    func append(
        identity: JournaldJournalEntryIdentityV1,
        entry: JournaldEntry
    ) throws -> JournaldJournalAppendDispositionV1 {
        appendCallCount += 1
        if let existing = entries[identity] {
            guard existing == entry else {
                throw JournaldProviderError.idempotencyConflict
            }
            return .alreadyPresent
        }
        entries[identity] = entry
        if failAfterFirstAppendEffect {
            failAfterFirstAppendEffect = false
            throw JournaldDurableTestError.afterAppendEffect
        }
        return .appended
    }

    func flush(timeoutNanoseconds: UInt64) async {
        flushCallCount += 1
        guard blockFlush else {
            return
        }
        flushStarted = true
        for waiter in flushStartWaiters {
            waiter.resume()
        }
        flushStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            flushContinuation = continuation
        }
    }

    func waitUntilFlushStarted() async {
        guard !flushStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            flushStartWaiters.append(continuation)
        }
    }

    func releaseFlush() {
        flushContinuation?.resume()
        flushContinuation = nil
    }

    func prepareReader(
        request: LogDriverReaderOpenRequestV1
    ) -> JournaldJournalReaderCheckpointV1? {
        prepareReaderCallCount += 1
        return nil
    }

    func read(
        request: LogDriverReaderOpenRequestV1,
        sequence: UInt64,
        after checkpoint: JournaldJournalReaderCheckpointV1?
    ) throws -> JournaldJournalReadResultV1 {
        readCallCount += 1
        readerCheckpoints.append(checkpoint)
        let event = readerEvents[sequence] ?? .endOfStream
        switch event {
        case .record:
            return JournaldJournalReadResultV1(
                event: event,
                checkpoint: advanceRecordCheckpoint
                    ? try journaldDurableCheckpoint(sequence: sequence)
                    : checkpoint
            )
        case .endOfStream:
            return JournaldJournalReadResultV1(
                event: event,
                checkpoint: advanceEndCheckpoint
                    ? try journaldDurableCheckpoint(sequence: sequence)
                    : checkpoint
            )
        }
    }

    func cancelReader(sessionID: String) {
        cancelledReaders.insert(sessionID)
    }
}

private func journaldDurableCheckpoint(
    sequence: UInt64
) throws -> JournaldJournalReaderCheckpointV1 {
    try JournaldJournalReaderCheckpointV1(
        bytes: Data("checkpoint-\(sequence)".utf8)
    )
}

private func journaldDurableWriterOpen(
    epoch: String = "epoch-1",
    sandboxGeneration: UInt64 = 13
) throws -> JournaldWriterOpenRequest {
    let identifier = String(repeating: "a", count: 64)
    return try JournaldWriterOpenRequest(
        request: LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "writer-operation",
            semanticRequestDigest: "sha256:writer",
            sessionID: "writer-session",
            containerID: identifier,
            leaseGeneration: 2,
            candidateProcessGeneration: 4,
            providerID: JournaldLogDriverContract.providerIdentity.id,
            providerGeneration: 1,
            candidateSandboxGeneration: sandboxGeneration
        ),
        configuration: JournaldDriverConfiguration(
            containerID: identifier,
            fields: [
                JournaldField.containerID: String(identifier.prefix(12)),
                JournaldField.containerIDFull: identifier,
                JournaldField.containerTag: "service",
                JournaldField.syslogIdentifier: "service",
            ]
        ),
        epoch: epoch
    )
}

private func journaldDurableReaderOpen(
    readerSessionID: String = "reader-session",
    source: LoggingReaderSourceV1 = .stoppedContainer
) throws -> LogDriverReaderOpenRequestV1 {
    try LogDriverReaderOpenRequestV1(
        operationGeneration: 1,
        idempotencyKey: "reader-operation",
        semanticRequestDigest: "sha256:reader",
        readerSessionID: readerSessionID,
        containerID: String(repeating: "a", count: 64),
        leaseGeneration: 2,
        providerID: JournaldLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        source: source,
        read: ContainerLogReadRequest(tail: 10)
    )
}

private func journaldDurableActiveReaderSource(
    sandboxGeneration: UInt64
) throws -> LoggingReaderSourceV1 {
    try LoggingReaderSourceV1(
        activeWriterSessionID: "writer-session",
        writerProviderID: JournaldLogDriverContract.providerIdentity.id,
        writerProviderGeneration: 1,
        activeProcessGeneration: 4,
        activeSandboxGeneration: sandboxGeneration
    )
}

private func journaldDurableEntry(
    ordinal: UInt64,
    message: String = "line"
) throws -> JournaldEntry {
    try JournaldEntry(
        message: Data(message.utf8),
        priority: .informational,
        fields: [
            JournaldField.containerIDFull: String(repeating: "a", count: 64),
            JournaldField.logEpoch: "epoch-1",
            JournaldField.logOrdinal: String(ordinal),
        ],
        receivedTimestamp: ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_785_751_872,
            nanoseconds: 123_456_789
        ),
        processGeneration: 4
    )
}

private func journaldDurableReadRecord(
    sequence: UInt64
) throws -> ContainerLogReadRecordV1 {
    try ContainerLogReadRecordV1(
        stream: .stdout,
        timestamp: ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_785_751_872,
            nanoseconds: 123_456_789
        ),
        data: Data("history\n".utf8),
        sequence: sequence,
        processGeneration: 4
    )
}
