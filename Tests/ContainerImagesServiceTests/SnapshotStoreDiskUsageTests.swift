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
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerImagesService

struct SnapshotStoreDiskUsageTests {
    @Test("Snapshot descriptor traversal is rejected")
    func snapshotSizeRejectsInvalidDigest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-invalid-digest-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try SnapshotStore(
            path: root,
            unpackStrategy: { _, _ in nil },
            log: nil
        )
        let descriptor = Descriptor(
            mediaType: "application/vnd.oci.image.manifest.v1+json",
            digest: "sha256:../../outside",
            size: 0
        )

        await #expect(throws: (any Error).self) {
            _ = try await store.getSnapshotSize(descriptor: descriptor)
        }
    }

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

struct ImageCleanupTests {
    @Test("Snapshot and content cleanup overlap")
    func cleanupRunsConcurrently() async throws {
        let entrants = PollingCountdown(count: 2)
        let release = PollingGate()
        let cleanup = Task {
            try await ConcurrentImageCleanup.run(
                snapshots: {
                    await entrants.arrive()
                    try await release.wait()
                    return 10
                },
                content: {
                    await entrants.arrive()
                    try await release.wait()
                    return (deleted: ["orphan"], freed: UInt64(20))
                }
            )
        }

        do {
            try await entrants.wait(timeout: .seconds(1))
        } catch {
            cleanup.cancel()
            await release.open()
            throw error
        }
        await release.open()
        let result = try await cleanup.value

        #expect(result.snapshotBytes == 10)
        #expect(result.content.deleted == ["orphan"])
        #expect(result.content.freed + result.snapshotBytes == 30)
    }

    @Test("A cleanup failure cancels its sibling")
    func cleanupFailureCancelsSibling() async throws {
        let entrants = PollingCountdown(count: 2)
        let cancellations = PollingCountdown(count: 1)

        do {
            _ = try await ConcurrentImageCleanup.run(
                snapshots: { () async throws -> UInt64 in
                    await entrants.arrive()
                    try await entrants.wait(timeout: .seconds(1))
                    throw ConcurrencyTestError.expectedFailure
                },
                content: {
                    await entrants.arrive()
                    try await entrants.wait(timeout: .seconds(1))
                    do {
                        try await Task.sleep(for: .seconds(10))
                        return (deleted: [String](), freed: UInt64(0))
                    } catch is CancellationError {
                        await cancellations.arrive()
                        throw CancellationError()
                    }
                }
            )
        } catch ConcurrencyTestError.expectedFailure {
            // Expected: the failed cleanup cancels its unfinished sibling.
        }

        try await cancellations.wait(timeout: .seconds(1))
    }
}

struct ActiveImageDiskUsageTests {
    @Test("Independent active image reads overlap")
    func boundedMapRunsConcurrently() async throws {
        let entrants = PollingCountdown(count: 2)
        let release = PollingGate()
        let values = Task {
            try await ConcurrentActiveImageDiskUsage.boundedMap(
                [1, 2],
                maximumConcurrentTasks: 2
            ) { value in
                await entrants.arrive()
                try await release.wait()
                return value * 10
            }
        }

        do {
            try await entrants.wait(timeout: .seconds(1))
        } catch {
            values.cancel()
            await release.open()
            throw error
        }
        await release.open()

        #expect(try await values.value.sorted() == [10, 20])
    }

    @Test("Duplicate active content and snapshots count once")
    func usageReductionDeduplicatesDigests() {
        let result = ConcurrentActiveImageDiskUsage.reduce([
            .init(
                contentDigests: ["index", "manifest", "shared-layer"],
                snapshotSizes: [(digest: "shared-snapshot", size: 10)]
            ),
            .init(
                contentDigests: ["other-index", "shared-layer"],
                snapshotSizes: [
                    (digest: "shared-snapshot", size: 10),
                    (digest: "other-snapshot", size: 20),
                ]
            ),
        ])

        #expect(result.contentDigests == ["index", "manifest", "other-index", "shared-layer"])
        #expect(result.snapshotSizes == ["other-snapshot": 20, "shared-snapshot": 10])
    }

    @Test("A failed active image read cancels unfinished work")
    func boundedMapCancelsAfterFailure() async throws {
        let siblingIsCancellable = PollingCountdown(count: 1)
        let cancellations = PollingCountdown(count: 1)

        do {
            _ = try await ConcurrentActiveImageDiskUsage.boundedMap(
                [false, true],
                maximumConcurrentTasks: 2
            ) { shouldFail in
                if shouldFail {
                    try await siblingIsCancellable.wait(timeout: .seconds(1))
                    throw ConcurrencyTestError.expectedFailure
                }

                return try await withTaskCancellationHandler {
                    await siblingIsCancellable.arrive()
                    try await Task.sleep(for: .seconds(10))
                    return 0
                } onCancel: {
                    Task {
                        await cancellations.arrive()
                    }
                }
            }
        } catch ConcurrencyTestError.expectedFailure {
            // Expected: the throwing child ends the group and cancels its sibling.
        }

        try await cancellations.wait(timeout: .seconds(1))
    }
}

private enum ConcurrencyTestError: Error {
    case expectedFailure
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
