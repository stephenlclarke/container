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

import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerCommands

struct SystemStartTests {
    @Test func acceptsMatchingAppRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Application.SystemStart.validateAppRoot(
            requested: FilePath(root.path(percentEncoded: false)),
            actual: root
        )
    }

    @Test func rejectsMismatchedAppRoot() throws {
        let requested = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-requested-\(UUID())")
        let actual = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-actual-\(UUID())")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: requested)
            try? FileManager.default.removeItem(at: actual)
        }

        let error = #expect(throws: ContainerizationError.self) {
            try Application.SystemStart.validateAppRoot(
                requested: FilePath(requested.path(percentEncoded: false)),
                actual: actual
            )
        }
        #expect(error?.code == .invalidState)
        #expect(error?.message.contains("stop it before changing --app-root") == true)
    }
}
