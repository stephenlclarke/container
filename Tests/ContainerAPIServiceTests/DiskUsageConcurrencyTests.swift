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
import Testing

@testable import ContainerAPIService

struct DiskUsageConcurrencyTests {
    @Test
    func containerSizingPreservesActiveAndReclaimableTotals() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let running = try directory(named: "running", containing: 4_096, under: root)
        let stopped = try directory(named: "stopped", containing: 8_192, under: root)
        let runningSize = FileManager.default.allocatedSize(of: running)
        let stoppedSize = FileManager.default.allocatedSize(of: stopped)

        let result = await ContainersService.calculateDiskUsage(
            totalCount: 3,
            paths: [
                .init(path: running, status: .running),
                .init(path: stopped, status: .stopped),
            ]
        )

        #expect(result.0 == 3)
        #expect(result.1 == 1)
        #expect(result.2 == runningSize + stoppedSize)
        #expect(result.3 == stoppedSize)
    }

    @Test
    func volumeSizingPreservesActiveAndReclaimableTotals() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let active = try directory(named: "active", containing: 4_096, under: root)
        let unused = try directory(named: "unused", containing: 8_192, under: root)
        let activeSize = FileManager.default.allocatedSize(of: active)
        let unusedSize = FileManager.default.allocatedSize(of: unused)

        let result = await VolumesService.calculateDiskUsage(
            totalCount: 3,
            activeCount: 1,
            paths: [
                .init(path: active, isInUse: true),
                .init(path: unused, isInUse: false),
            ]
        )

        #expect(result.0 == 3)
        #expect(result.1 == 1)
        #expect(result.2 == activeSize + unusedSize)
        #expect(result.3 == unusedSize)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-disk-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func directory(named name: String, containing byteCount: Int, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xa5, count: byteCount).write(to: directory.appendingPathComponent("payload"))
        return directory
    }
}
