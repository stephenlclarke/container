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

@testable import ContainerAPIService

struct StoragePathTests {
    @Test(arguments: ["", ".", "..", "../outside", "/tmp/outside", "nested/path"])
    func containerPathRejectsUnsafeIdentifiers(_ id: String) {
        #expect(throws: Error.self) {
            try ContainersService.containerPath(root: URL(filePath: "/tmp/containers"), id: id)
        }
    }

    @Test(arguments: ["", ".", "..", "../outside", "/tmp/outside", "nested/path"])
    func volumePathRejectsUnsafeNames(_ name: String) {
        #expect(throws: Error.self) {
            try VolumesService.volumePath(root: URL(filePath: "/tmp/volumes"), name: name)
        }
    }

    @Test(arguments: ["", ".", "..", "../outside", "/tmp/outside", "nested/path"])
    func configPathRejectsUnsafeNames(_ name: String) {
        #expect(throws: Error.self) {
            try ConfigsService.configPath(root: URL(filePath: "/tmp/configs"), name: name)
        }
    }

    @Test func storagePathsRemainInsideTheirManagedRoots() throws {
        let containerRoot = URL(filePath: "/tmp/containers")
        let volumeRoot = URL(filePath: "/tmp/volumes")
        let configRoot = URL(filePath: "/tmp/configs")

        #expect(try ContainersService.containerPath(root: containerRoot, id: "api-1").path == containerRoot.appendingPathComponent("api-1").path)
        #expect(try VolumesService.volumePath(root: volumeRoot, name: "compose-data").path == volumeRoot.appendingPathComponent("compose-data").path)
        #expect(try ConfigsService.configPath(root: configRoot, name: "app-config").path == configRoot.appendingPathComponent("app-config").path)
    }
}
