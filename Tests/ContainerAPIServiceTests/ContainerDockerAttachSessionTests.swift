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
import ContainerEngineWire
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerDockerAttachSessionTests {
    @Test func bridgesRuntimeInputAndMultiplexedOutput() async throws {
        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let detachCount = AttachDetachCount()
        let session = ContainerDockerAttachSession(
            input: input.fileHandleForWriting,
            runtimeOutputs: [
                (.standardOutput, stdout.fileHandleForReading),
                (.standardError, stderr.fileHandleForReading),
            ],
            logReader: nil,
            detachKeySequence: nil,
            waitForProcess: false,
            processWait: { 99 },
            onDetach: { await detachCount.increment() }
        )

        await session.start()
        try await session.write(Data("client input".utf8))
        try await session.closeStandardInput()
        #expect(try input.fileHandleForReading.readToEnd() == Data("client input".utf8))

        try stdout.fileHandleForWriting.write(contentsOf: Data("out".utf8))
        try stderr.fileHandleForWriting.write(contentsOf: Data("err".utf8))
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        let frames = try await collect(session.frames)
        #expect(frames.count == 2)
        #expect(
            frames.contains(
                DockerStreamFrame(channel: .standardOutput, data: Data("out".utf8))
            )
        )
        #expect(
            frames.contains(
                DockerStreamFrame(channel: .standardError, data: Data("err".utf8))
            )
        )
        #expect(try await session.wait() == 0)
        #expect(await detachCount.value == 1)
    }

    @Test func detachSequenceIsConsumedAndFinishesExactlyOnce() async throws {
        let input = Pipe()
        let detachCount = AttachDetachCount()
        let session = ContainerDockerAttachSession(
            input: input.fileHandleForWriting,
            runtimeOutputs: [],
            logReader: nil,
            detachKeySequence: [0x10, 0x11],
            waitForProcess: true,
            processWait: {
                try await Task.sleep(for: .seconds(60))
                return 99
            },
            onDetach: { await detachCount.increment() }
        )

        await session.start()
        try await session.write(Data([0x61, 0x62, 0x63, 0x10, 0x11, 0x7a]))

        #expect(try input.fileHandleForReading.readToEnd() == Data("abc".utf8))
        #expect(try await session.wait() == 0)
        await session.cancel()
        #expect(await detachCount.value == 1)
    }

    @Test func splitDetachSequenceLeavesProcessAvailableForReattach() async throws {
        let firstInput = Pipe()
        let detachCount = AttachDetachCount()
        let first = ContainerDockerAttachSession(
            input: firstInput.fileHandleForWriting,
            runtimeOutputs: [],
            logReader: nil,
            detachKeySequence: [0x10, 0x11],
            waitForProcess: true,
            processWait: {
                try await Task.sleep(for: .seconds(60))
                return 99
            },
            onDetach: { await detachCount.increment() }
        )
        await first.start()
        var firstChunk = Data("before detach".utf8)
        firstChunk.append(0x10)
        try await first.write(firstChunk)
        try await first.write(Data([0x11]))

        #expect(
            try firstInput.fileHandleForReading.readToEnd()
                == Data("before detach".utf8)
        )
        #expect(try await first.wait() == 0)

        let secondInput = Pipe()
        let secondOutput = Pipe()
        let second = ContainerDockerAttachSession(
            input: secondInput.fileHandleForWriting,
            runtimeOutputs: [
                (.standardOutput, secondOutput.fileHandleForReading)
            ],
            logReader: nil,
            detachKeySequence: nil,
            waitForProcess: false,
            processWait: { 99 },
            onDetach: { await detachCount.increment() }
        )
        await second.start()
        try await second.write(Data("after reattach".utf8))
        try await second.closeStandardInput()
        #expect(
            try secondInput.fileHandleForReading.readToEnd()
                == Data("after reattach".utf8)
        )
        try secondOutput.fileHandleForWriting.write(
            contentsOf: Data("reattached output".utf8)
        )
        try secondOutput.fileHandleForWriting.close()

        #expect(
            try await collect(second.frames)
                == [
                    DockerStreamFrame(
                        channel: .standardOutput,
                        data: Data("reattached output".utf8)
                    )
                ]
        )
        #expect(try await second.wait() == 0)
        #expect(await detachCount.value == 2)
    }

    @Test func canonicalLogReaderFeedsHijackFramesWithoutRuntimeOutput() async throws {
        let record = try DockerLogRecord(
            source: .standardError,
            timestamp: DockerLogTimestamp(
                secondsSinceUnixEpoch: 1_767_323_045,
                nanoseconds: 123_456_789
            ),
            line: Data("history\n".utf8),
            attributes: [:]
        )
        let reader = ArrayDockerLogReadSession(records: [record])
        let detachCount = AttachDetachCount()
        let session = ContainerDockerAttachSession(
            input: nil,
            runtimeOutputs: [],
            logReader: reader,
            detachKeySequence: nil,
            waitForProcess: false,
            processWait: { 99 },
            onDetach: { await detachCount.increment() }
        )

        await session.start()

        #expect(
            try await collect(session.frames)
                == [DockerStreamFrame(channel: .standardError, data: record.line)]
        )
        #expect(try await session.wait() == 0)
        #expect(await reader.closeCount == 1)
        #expect(await detachCount.value == 1)
    }

    @Test func boundedFrameBufferDoesNotDropCanonicalRecords() async throws {
        let count = 300
        let records = try (0..<count).map { index in
            try DockerLogRecord(
                source: .standardOutput,
                timestamp: DockerLogTimestamp(
                    secondsSinceUnixEpoch: Int64(index),
                    nanoseconds: 0
                ),
                line: Data("\(index)\n".utf8),
                attributes: [:]
            )
        }
        let reader = ArrayDockerLogReadSession(records: records)
        let session = ContainerDockerAttachSession(
            input: nil,
            runtimeOutputs: [],
            logReader: reader,
            detachKeySequence: nil,
            waitForProcess: false,
            processWait: { 99 },
            onDetach: {}
        )

        await session.start()
        try await Task.sleep(for: .milliseconds(20))
        let frames = try await collect(session.frames)

        #expect(frames.count == count)
        #expect(frames.map(\.data) == records.map(\.line))
        #expect(try await session.wait() == 0)
    }

    private func collect(
        _ stream: AsyncThrowingStream<DockerStreamFrame, any Error>
    ) async throws -> [DockerStreamFrame] {
        var frames = [DockerStreamFrame]()
        for try await frame in stream {
            frames.append(frame)
        }
        return frames
    }
}

private actor AttachDetachCount {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor ArrayDockerLogReadSession: DockerLogReadSession {
    nonisolated let terminal = false

    private let records: [DockerLogRecord]
    private var index = 0
    private(set) var closeCount = 0

    init(records: [DockerLogRecord]) {
        self.records = records
    }

    func nextRecord() -> DockerLogRecord? {
        guard index < records.count else {
            return nil
        }
        defer { index += 1 }
        return records[index]
    }

    func close() {
        closeCount += 1
    }

    func cancel() {
        closeCount += 1
    }
}
