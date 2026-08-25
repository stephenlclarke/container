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

import ContainerizationArchive
import Foundation
import Testing

@testable import ContainerImagesService

struct ImageArchiveIOTests {
    @Test("Image archives round trip outside actor isolation")
    func archiveRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        let archive = root.appendingPathComponent("image.tar")
        let extracted = root.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("image-data".utf8).write(to: source.appendingPathComponent("manifest.json"))

        try await ConcurrentImageArchiveIO.writeDirectory(source, to: archive)
        let rejected = try await ConcurrentImageArchiveIO.extract(archive, to: extracted)

        #expect(rejected.isEmpty)
        #expect(try Data(contentsOf: extracted.appendingPathComponent("manifest.json")) == Data("image-data".utf8))
    }

    @Test("Image extraction reports path traversal members")
    func extractionPreservesRejectedMembers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-archive-rejection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("image.tar")
        let extracted = root.appendingPathComponent("extracted")
        let escapedName = "escaped-\(UUID()).txt"
        let escaped = root.appendingPathComponent(escapedName)
        let entry = WriteEntry()
        entry.path = "../\(escapedName)"
        entry.size = 4
        entry.modificationDate = Date()
        entry.fileType = .regular
        entry.permissions = 0o644
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: archive)
        try writer.writeEntry(entry: entry, data: Data("nope".utf8))
        try writer.finishEncoding()

        let rejected = try await ConcurrentImageArchiveIO.extract(archive, to: extracted)

        #expect(rejected == ["../\(escapedName)"])
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test("Image archive work does not hold actor isolation")
    func archiveDoesNotBlockActor() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = ImageArchiveIsolationProbe()
        let archive = Task {
            try await probe.archive(started: started, release: release)
        }

        let didStart = await ImageArchiveSemaphore.wait(started, timeout: .now() + 1)
        guard didStart else {
            release.signal()
            archive.cancel()
            throw ImageArchiveTestError.timedOut
        }

        let pinged = ImageArchiveCountdown(count: 1)
        let ping = Task {
            await probe.ping(pinged)
        }
        do {
            try await pinged.wait(timeout: .seconds(1))
        } catch {
            release.signal()
            archive.cancel()
            throw error
        }

        release.signal()
        await ping.value
        #expect(try await archive.value == 1)
    }
}

private enum ImageArchiveTestError: Error {
    case timedOut
}

private enum ImageArchiveSemaphore {
    static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

private actor ImageArchiveCountdown {
    private var remaining: Int

    init(count: Int) {
        self.remaining = count
    }

    func arrive() {
        remaining -= 1
    }

    func wait(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while remaining > 0 {
            guard clock.now < deadline else {
                throw ImageArchiveTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor ImageArchiveIsolationProbe {
    func archive(started: DispatchSemaphore, release: DispatchSemaphore) async throws -> Int {
        try await ConcurrentImageArchiveIO.run {
            started.signal()
            release.wait()
            return 1
        }
    }

    func ping(_ countdown: ImageArchiveCountdown) async {
        await countdown.arrive()
    }
}
