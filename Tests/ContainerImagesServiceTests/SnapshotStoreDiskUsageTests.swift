//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import Foundation
import Testing

@testable import ContainerImagesService

struct SnapshotStoreDiskUsageTests {
    @Test("Snapshot allocation is measured outside store isolation")
    func allocatedSizeReportsStoredFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-size-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8 * 1024).write(to: root.appendingPathComponent("snapshot"))

        let expected = FileManager.default.allocatedSize(of: root)
        let actual = await SnapshotStore.allocatedSize(of: root)

        #expect(actual == expected)
        #expect(actual > 0)
    }

    @Test("Missing snapshots have zero allocation")
    func allocatedSizeReportsMissingSnapshot() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-snapshot-\(UUID())")
        let size = await SnapshotStore.allocatedSize(of: missing)

        #expect(size == 0)
    }

    @Test("Independent snapshot sizes preserve descriptor order")
    func allocatedSizesRunConcurrentlyInOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-sizes-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let first = root.appendingPathComponent("first")
        let last = root.appendingPathComponent("last")
        for snapshot in [first, last] {
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8 * 1024).write(to: snapshot.appendingPathComponent("data"))
        }

        let sizes = await SnapshotStore.allocatedSizes(
            for: [
                .init(index: 0, digest: "first", path: first),
                .init(index: 1, digest: "missing", path: root.appendingPathComponent("missing")),
                .init(index: 2, digest: "last", path: last),
            ]
        )

        #expect(sizes.map(\.digest) == ["first", "last"])
        #expect(
            sizes.map(\.size) == [
                FileManager.default.allocatedSize(of: first),
                FileManager.default.allocatedSize(of: last),
            ])
    }
}

struct ImageDiskUsageTotalsTests {
    @Test("Content and snapshot totals are measured concurrently")
    func totalsOverlap() async throws {
        let entrants = PollingCountdown(count: 2)
        let release = PollingGate()
        let totals = Task {
            try await ConcurrentImageDiskUsageTotals.run(
                content: {
                    await entrants.arrive()
                    try await release.wait()
                    return 10
                },
                snapshots: {
                    await entrants.arrive()
                    try await release.wait()
                    return 20
                }
            )
        }

        do {
            try await entrants.wait(timeout: .seconds(1))
        } catch {
            totals.cancel()
            await release.open()
            throw error
        }
        await release.open()
        let result = try await totals.value

        #expect(result.content == 10)
        #expect(result.snapshots == 20)
    }
}

private enum ConcurrencyTestError: Error {
    case timedOut
}

private actor PollingCountdown {
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
                throw ConcurrencyTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor PollingGate {
    private var isOpen = false

    func wait() async throws {
        while !isOpen {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func open() {
        isOpen = true
    }
}
