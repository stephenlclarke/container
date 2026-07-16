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

@testable import ContainerRuntimeLinuxServer

struct DiskSnapshotTests {
    @Test
    func clonePreservesContentsWhenSourceChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("source.ext4")
        let snapshot = directory.appendingPathComponent("snapshot.ext4")
        let original = Data("before-clone".utf8)
        try original.write(to: source)

        try DiskSnapshot.clone(from: source.path, to: snapshot.path)
        try Data("after-clone".utf8).write(to: source)

        #expect(try Data(contentsOf: snapshot) == original)
    }
}
