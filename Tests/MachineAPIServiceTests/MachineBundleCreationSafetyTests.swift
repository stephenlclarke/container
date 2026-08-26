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
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import SystemPackage
import Testing

struct MachineBundleCreationSafetyTests {
    @Test("Creating a machine never replaces a pre-existing bundle")
    func existingBundleIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            atPath: fixture.bundlePath.string,
            withIntermediateDirectories: false
        )
        let marker = fixture.bundlePath.appending("user-data")
        try Data("preserve".utf8).write(to: URL(filePath: marker.string))

        let error = #expect(throws: ContainerizationError.self) {
            try MachineBundle.create(
                path: fixture.bundlePath,
                machineConfiguration: try Self.configuration(),
                resourceRoot: fixture.resourceRoot,
                resources: nil,
                bootConfig: .default
            )
        }

        #expect(error?.code == .exists)
        #expect(FileManager.default.fileExists(atPath: marker.string))
    }

    @Test("Failed creation removes only its newly created partial bundle")
    func failedCreationRemovesOwnedBundle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: (any Error).self) {
            try MachineBundle.create(
                path: fixture.bundlePath,
                machineConfiguration: try Self.configuration(),
                resourceRoot: fixture.resourceRoot,
                resources: nil,
                bootConfig: .default
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.bundlePath.string))
    }

    private static func configuration() throws -> MachineConfiguration {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        return try MachineConfiguration(
            id: "machine",
            image: image,
            platform: .init(arch: "arm64", os: "linux", variant: "v8"),
            userSetup: .init(username: "test", uid: 501, gid: 20)
        )
    }
}

private struct Fixture {
    let root: FilePath
    let bundlePath: FilePath
    let resourceRoot: FilePath

    init() throws {
        let fixtureRoot = FilePath(NSTemporaryDirectory()).appending("machine-bundle-safety-\(UUID())")
        root = fixtureRoot
        bundlePath = fixtureRoot.appending("machine")
        resourceRoot = fixtureRoot.appending("missing-resources")
        try FileManager.default.createDirectory(atPath: fixtureRoot.string, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root.string)
    }
}
