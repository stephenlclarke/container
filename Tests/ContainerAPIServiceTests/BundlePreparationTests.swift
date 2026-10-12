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

import Containerization
import Foundation
import Testing

@testable import ContainerResource

struct BundlePreparationTests {
    private enum Interrupted: Error { case publication }

    @Test(arguments: ["staged", "kernel.bin", "kernel.json", "initfs.ext4", "rootfs.ext4", "rootfs.json", "options.json"])
    func interruptedPublicationRecoversWithoutDeletingContainerState(boundary: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: Interrupted.self) {
            try fixture.prepare { name in
                #expect(try !fixture.bundle.isPrepared)
                if name == boundary { throw Interrupted.publication }
            }
        }
        #expect(try !fixture.bundle.isPrepared)
        try fixture.checkState()
        // A new Bundle instance models recovery after the service restarts.
        _ = try fixture.prepare()
        let recovered = ContainerResource.Bundle(path: fixture.bundle.path)
        #expect(try recovered.isPrepared)
        #expect(try recovered.kernel.path == recovered.path.appendingPathComponent("kernel.bin"))
        #expect(try recovered.containerRootfs.source == recovered.containerRootfsBlock.path)
        #expect(try Data(contentsOf: recovered.containerRootfsBlock) == fixture.rootBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: recovered.initialFilesystem.source)) == fixture.initBytes)
        #expect(!FileManager.default.fileExists(atPath: recovered.path.appendingPathComponent(".bundle-preparation").path))
        try fixture.checkState()
        // Preparing a committed bundle must never replace a subsequent offline edit.
        try Data("copied-before-start".utf8).write(to: recovered.containerRootfsBlock)
        #expect(throws: POSIXError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: recovered.containerRootfsBlock) == Data("copied-before-start".utf8))
        #expect(try Data(contentsOf: fixture.rootSource) == fixture.rootBytes)
    }

    @Test(arguments: ["kernel", "initfs", "rootfs"])
    func missingSourceDoesNotPublishReadiness(source: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = source == "kernel" ? fixture.kernel.path : (source == "initfs" ? fixture.initSource : fixture.rootSource)
        try FileManager.default.removeItem(at: path)
        #expect(throws: (any Error).self) { try fixture.prepare() }
        #expect(try !fixture.bundle.isPrepared)
        try fixture.checkState()
    }

    @Test
    func stalePrivateStageRecoversButUnknownContentsArePreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stage = fixture.bundle.path.appendingPathComponent(".bundle-preparation", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("partial".utf8).write(to: stage.appendingPathComponent("rootfs.ext4"))
        let unknown = stage.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: unknown)
        #expect(throws: POSIXError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: unknown) == Data("preserve".utf8))
        #expect(try !fixture.bundle.isPrepared)
        try FileManager.default.removeItem(at: unknown)
        _ = try fixture.prepare()
        #expect(try fixture.bundle.isPrepared)
        try fixture.checkState()
    }

    @Test
    func stageSymlinkCannotRemoveOutsideResources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stage = fixture.bundle.path.appendingPathComponent(".bundle-preparation")
        try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: fixture.directory)
        #expect(throws: POSIXError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.rootSource) == fixture.rootBytes)
        #expect(try !fixture.bundle.isPrepared)
    }

    @Test(arguments: ["kernel.bin", "kernel.json", "initfs.ext4", "rootfs.ext4"])
    func legacyConfigFirstPartialBundleRecovers(missing: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.prepare()
        let copied = Data("preserve-offline-copied-data".utf8)
        try copied.write(to: fixture.bundle.containerRootfsBlock)
        try FileManager.default.removeItem(at: fixture.bundle.path.appendingPathComponent(missing))
        #expect(try !fixture.bundle.isPrepared)
        _ = try fixture.prepare()
        #expect(try fixture.bundle.isPrepared)
        let expected = missing == "rootfs.ext4" ? fixture.rootBytes : copied
        #expect(try Data(contentsOf: fixture.bundle.containerRootfsBlock) == expected)
        try fixture.checkState()
    }

    @Test
    func legacyImageWithoutDescriptorIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.prepare()
        try FileManager.default.removeItem(at: fixture.bundle.path.appendingPathComponent("rootfs.json"))
        #expect(try !fixture.bundle.isPrepared)
        #expect(throws: POSIXError.self) { try fixture.prepare() }
        #expect(try Data(contentsOf: fixture.bundle.containerRootfsBlock) == fixture.rootBytes)
        try fixture.checkState()
    }

    @Test
    func readonlyAndOverrideKeepTheirRuntimeSemantics() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var configuration = fixture.configuration
        configuration.readOnly = true
        _ = try ContainerResource.Bundle.create(
            path: fixture.bundle.path, initialFilesystem: fixture.initialFilesystem,
            kernel: fixture.kernel, containerConfiguration: configuration,
            containerRootFilesystem: fixture.rootFilesystem, options: .default)
        #expect(try fixture.bundle.containerRootfs.options.contains("ro"))
        let other = fixture.directory.appendingPathComponent("override-bundle")
        let override = fixture.rootFilesystem
        let bundle = try ContainerResource.Bundle.create(
            path: other, initialFilesystem: fixture.initialFilesystem, kernel: fixture.kernel,
            containerConfiguration: configuration, containerRootFilesystem: fixture.rootFilesystem,
            options: .init(autoRemove: false, rootFsOverride: override))
        let actual = try bundle.containerRootfs
        #expect(actual.type == override.type)
        #expect(actual.source == override.source)
        #expect(actual.destination == override.destination)
        #expect(actual.options == override.options)
        #expect(actual.sourceSubpath == override.sourceSubpath)
        #expect(!FileManager.default.fileExists(atPath: bundle.containerRootfsBlock.path))
    }

    private struct Fixture {
        let directory: URL
        let bundle: ContainerResource.Bundle
        let kernel: Kernel
        let initSource: URL
        let rootSource: URL
        let configuration: ContainerConfiguration
        let initBytes = Data("initial-filesystem".utf8)
        let rootBytes = Data("root-filesystem".utf8)
        let stateNames = ["runtime-configuration.json", "lifecycle-v2.json", "vminitd.log", "unrelated"]

        var initialFilesystem: Filesystem { .block(format: "ext4", source: initSource.path, destination: "/", options: ["ro"]) }
        var rootFilesystem: Filesystem { .block(format: "ext4", source: rootSource.path, destination: "/", options: []) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-preparation-\(UUID())", isDirectory: true)
            bundle = ContainerResource.Bundle(path: directory.appendingPathComponent("container", isDirectory: true))
            try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
            initSource = directory.appendingPathComponent("initial.ext4")
            rootSource = directory.appendingPathComponent("source.ext4")
            kernel = Kernel(path: directory.appendingPathComponent("source.kernel"), platform: .linuxArm)
            configuration = ContainerConfiguration(
                id: "cold-copy",
                image: .init(
                    reference: "alpine",
                    descriptor: .init(
                        mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:" + String(repeating: "0", count: 64), size: 0)),
                process: .init(executable: "/bin/true", arguments: [], environment: []))
            try initBytes.write(to: initSource)
            try rootBytes.write(to: rootSource)
            try Data("kernel".utf8).write(to: kernel.path)
            for name in stateNames { try Data(name.utf8).write(to: bundle.path.appendingPathComponent(name)) }
        }

        func prepare(didPublish: (String) throws -> Void = { _ in }) throws -> ContainerResource.Bundle {
            try ContainerResource.Bundle.prepare(
                path: bundle.path, initialFilesystem: initialFilesystem, kernel: kernel,
                containerConfiguration: configuration, containerRootFilesystem: rootFilesystem,
                options: .default, didPublish: didPublish)
        }

        func checkState() throws {
            for name in stateNames { #expect(try Data(contentsOf: bundle.path.appendingPathComponent(name)) == Data(name.utf8)) }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
