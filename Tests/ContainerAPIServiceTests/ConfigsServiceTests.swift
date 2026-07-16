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
import Logging
import SystemPackage
import Testing

@testable import ContainerAPIService

struct ConfigsServiceTests {
    @Test func persistsAndReadsImmutableConfigContent() async throws {
        try await withTemporaryConfigRoot { root in
            let service = try ConfigsService(resourceRoot: FilePath(root.path), log: Logger(label: "com.apple.container.test.configs"))
            let contents = Data("mode=production\n".utf8)
            let created = try await service.create(name: "app-config", contents: contents, labels: ["owner": "compose"])

            #expect(created.name == "app-config")
            #expect(created.sizeInBytes == UInt64(contents.count))
            #expect(created.labels == ["owner": "compose"])
            #expect(!String(decoding: try JSONEncoder().encode(created), as: UTF8.self).contains("mode=production"))

            await #expect(throws: ConfigError.self) {
                try await service.create(name: "app-config", contents: Data(), labels: [:])
            }

            let reloaded = try ConfigsService(resourceRoot: FilePath(root.path), log: Logger(label: "com.apple.container.test.configs"))
            #expect(try await reloaded.inspect("app-config") == created)
            #expect(try await reloaded.read(name: "app-config") == contents)

            let empty = try await reloaded.create(name: "empty-config", contents: Data())
            #expect(empty.sizeInBytes == 0)
            #expect(try await reloaded.read(name: "empty-config") == Data())

            try await reloaded.delete(name: "app-config")
            try await reloaded.delete(name: "empty-config")
            #expect(try await reloaded.list().isEmpty)
        }
    }

    @Test(arguments: ["", "../outside", "/tmp/outside", "nested/path"])
    func configPathRejectsUnsafeNames(_ name: String) {
        #expect(throws: Error.self) {
            try ConfigsService.configPath(root: URL(filePath: "/tmp/configs"), name: name)
        }
    }

    @Test func concurrentCreatesLeaveOneConfig() async throws {
        try await withTemporaryConfigRoot { root in
            let service = try ConfigsService(resourceRoot: FilePath(root.path), log: Logger(label: "com.apple.container.test.configs"))
            let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            _ = try await service.create(name: "app-config", contents: Data("enabled=true\n".utf8))
                            return true
                        } catch {
                            return false
                        }
                    }
                }

                var count = 0
                for await succeeded in group where succeeded {
                    count += 1
                }
                return count
            }

            #expect(successes == 1)
            #expect(try await service.list().count == 1)
        }
    }

    private func withTemporaryConfigRoot(body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("container-configs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}
