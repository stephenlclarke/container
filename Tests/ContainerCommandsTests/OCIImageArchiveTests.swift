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

import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation
import Testing

@testable import ContainerCommands

struct OCIImageArchiveTests {
    @Test func committedArchivePreservesContentAndContainerMetadata() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("commit-archive-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let rootfs = temporary.appendingPathComponent("rootfs.tar")
        let rootfsWriter = try ArchiveWriter(format: .pax, filter: .none, file: rootfs)
        let entry = WriteEntry()
        entry.path = "committed-file"
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = 7
        try rootfsWriter.writeEntry(entry: entry, data: Data("content".utf8))
        try rootfsWriter.finishEncoding()

        let reference = "docker.io/library/committed:test"
        let archive = try OCIImageArchive.create(
            from: rootfs,
            in: temporary,
            reference: reference,
            container: snapshot(),
            sourceImage: sourceImage()
        )
        let extracted = temporary.appendingPathComponent("extracted")
        let rejected = try ArchiveReader(file: archive).extractContents(to: extracted)
        #expect(rejected.isEmpty)

        let decoder = JSONDecoder()
        let layout = try decoder.decode([String: String].self, from: Data(contentsOf: extracted.appendingPathComponent("oci-layout")))
        #expect(layout == ["imageLayoutVersion": "1.0.0"])
        let index = try decoder.decode(Index.self, from: Data(contentsOf: extracted.appendingPathComponent("index.json")))
        #expect(index.schemaVersion == 2)
        let manifestDescriptor = try #require(index.manifests.only)
        #expect(manifestDescriptor.mediaType == MediaTypes.imageManifest)
        #expect(manifestDescriptor.platform?.architecture == "arm64")
        #expect(manifestDescriptor.platform?.os == "linux")
        for key in ["org.opencontainers.image.ref.name", "io.containerd.image.name", "com.apple.containerization.image.name"] {
            #expect(manifestDescriptor.annotations?[key] == reference)
        }

        let manifest = try decoder.decode(Manifest.self, from: blob(manifestDescriptor, in: extracted))
        let layer = try #require(manifest.layers.only)
        #expect(layer.mediaType == MediaTypes.imageLayer)
        #expect(manifest.config.mediaType == MediaTypes.imageConfig)
        #expect(try blob(layer, in: extracted) == Data(contentsOf: rootfs))
        let image = try decoder.decode(Image.self, from: blob(manifest.config, in: extracted))
        #expect(image.architecture == "arm64")
        #expect(image.os == "linux")
        #expect(image.osVersion == "1.0")
        #expect(image.osFeatures == ["feature"])
        #expect(image.variant == "v8")
        #expect(image.author == "source-author")
        #expect(image.rootfs.type == "layers")
        #expect(image.rootfs.diffIDs == [layer.digest])
        #expect(image.history?.only?.createdBy == "container commit")
        #expect(image.config?.user == "1000:1001")
        #expect(image.config?.env == ["COMMIT_TEST=preserved"])
        #expect(image.config?.entrypoint == nil)
        #expect(image.config?.cmd == ["/bin/sh", "-c", "true"])
        #expect(image.config?.workingDir == "/work")
        #expect(image.config?.stopSignal == "SIGTERM")
        #expect(image.config?.labels == ["source-only": "old", "shared": "container", "container-only": "new"])
    }

    @Test func missingRootfsDoesNotProduceImageArchive() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("commit-archive-missing-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        #expect(throws: (any Error).self) {
            try OCIImageArchive.create(
                from: temporary.appendingPathComponent("missing.tar"),
                in: temporary,
                reference: "docker.io/library/committed:test",
                container: snapshot(),
                sourceImage: sourceImage()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent("image.tar").path))
    }

    private struct CommandCase: Sendable {
        let entrypoint: [String]?
        let command: [String]?
        let flags: [String]
        let arguments: [String]
        let expectedEntrypoint: [String]?
        let expectedCommand: [String]?
    }

    @Test(arguments: [
        CommandCase(entrypoint: nil, command: ["/bin/sh"], flags: [], arguments: [], expectedEntrypoint: nil, expectedCommand: ["/bin/sh"]),
        CommandCase(entrypoint: nil, command: ["/bin/sh"], flags: [], arguments: ["sleep", "300"], expectedEntrypoint: nil, expectedCommand: ["sleep", "300"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: ["-c", "true"], flags: [], arguments: [], expectedEntrypoint: ["/usr/bin/env", "sh"], expectedCommand: ["-c", "true"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: ["-c", "true"], flags: [], arguments: ["-c", "echo overridden"], expectedEntrypoint: ["/usr/bin/env", "sh"],
            expectedCommand: ["-c", "echo overridden"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: ["-c", "true"], flags: ["--clear-entrypoint"], arguments: [], expectedEntrypoint: [], expectedCommand: ["-c", "true"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: ["-c", "true"], flags: ["--entrypoint", "/bin/echo"], arguments: ["hello"], expectedEntrypoint: ["/bin/echo"],
            expectedCommand: ["hello"]),
        CommandCase(entrypoint: ["/bin/echo"], command: ["old"], flags: ["--entrypoint", ""], arguments: ["/bin/sh"], expectedEntrypoint: [], expectedCommand: ["/bin/sh"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: ["-c", "true"], flags: ["--entrypoint", "/usr/bin/env"], arguments: ["sh", "-c", "true"],
            expectedEntrypoint: ["/usr/bin/env"], expectedCommand: ["sh", "-c", "true"]),
    ])
    private func committedImageRetainsEffectiveCommandSplit(_ test: CommandCase) throws {
        let base = Image(
            architecture: "arm64", os: "linux",
            config: ImageConfig(entrypoint: test.entrypoint, cmd: test.command),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
        let process = try Parser.process(
            arguments: test.arguments,
            processFlags: Flags.Process.parse([]),
            managementFlags: Flags.Management.parse(test.flags),
            config: base.config
        )
        // Persistence must retain the split even when two requests have identical argv.
        let persisted = try JSONDecoder().decode(ProcessConfiguration.self, from: JSONEncoder().encode(process))
        let image = try committedImage(process: persisted, source: base)
        #expect(image.config?.entrypoint == test.expectedEntrypoint)
        #expect(image.config?.cmd == test.expectedCommand)
    }

    @Test(arguments: [
        CommandCase(entrypoint: nil, command: nil, flags: [], arguments: ["/bin/sh", "-c", "true"], expectedEntrypoint: nil, expectedCommand: ["/bin/sh", "-c", "true"]),
        CommandCase(entrypoint: [], command: nil, flags: [], arguments: ["/bin/sh"], expectedEntrypoint: [], expectedCommand: ["/bin/sh"]),
        CommandCase(
            entrypoint: ["/usr/bin/env", "sh"], command: nil, flags: [], arguments: ["/usr/bin/env", "sh", "-c", "false"], expectedEntrypoint: ["/usr/bin/env", "sh"],
            expectedCommand: ["-c", "false"]),
        CommandCase(entrypoint: ["/bin/echo"], command: nil, flags: [], arguments: ["sleep", "300"], expectedEntrypoint: ["sleep"], expectedCommand: ["300"]),
    ])
    private func legacyConfigurationPreservesRecoverableCommandSplit(_ test: CommandCase) throws {
        let process = ProcessConfiguration(
            executable: try #require(test.arguments.first), arguments: Array(test.arguments.dropFirst()), environment: []
        )
        let base = Image(
            architecture: "arm64", os: "linux", config: ImageConfig(entrypoint: test.entrypoint),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
        let image = try committedImage(process: process, source: base)
        #expect(image.config?.entrypoint == test.expectedEntrypoint)
        #expect(image.config?.cmd == test.expectedCommand)
    }

    @Test func ignoresCommandMetadataAfterRuntimeArgumentsChange() throws {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: ["-c", "true"], environment: [],
            imageCommand: .init(entrypoint: ["/bin/echo"], command: ["old"])
        )
        let image = try committedImage(process: process, source: sourceImage())
        #expect(image.config?.entrypoint == nil)
        #expect(image.config?.cmd == ["/bin/sh", "-c", "true"])
    }

    private func committedImage(process: ProcessConfiguration, source: Image) throws -> Image {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("commit-command-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let rootfs = temporary.appendingPathComponent("rootfs.tar")
        try ArchiveWriter(format: .pax, filter: .none, file: rootfs).finishEncoding()
        let archive = try OCIImageArchive.create(
            from: rootfs, in: temporary, reference: "localhost/command:test",
            container: snapshot(process: process), sourceImage: source
        )
        let extracted = temporary.appendingPathComponent("extracted")
        #expect(try ArchiveReader(file: archive).extractContents(to: extracted).isEmpty)
        let decoder = JSONDecoder()
        let index = try decoder.decode(Index.self, from: Data(contentsOf: extracted.appendingPathComponent("index.json")))
        let manifest = try decoder.decode(Manifest.self, from: blob(try #require(index.manifests.only), in: extracted))
        return try decoder.decode(Image.self, from: blob(manifest.config, in: extracted))
    }

    private func snapshot(process override: ProcessConfiguration? = nil) -> ContainerSnapshot {
        let description = ImageDescription(
            reference: "docker.io/library/source:latest",
            descriptor: Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:" + String(repeating: "0", count: 64), size: 0)
        )
        let process =
            override
            ?? ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "true"],
                environment: ["COMMIT_TEST=preserved"],
                workingDirectory: "/work",
                user: .id(uid: 1000, gid: 1001)
            )
        var configuration = ContainerConfiguration(id: "source", image: description, process: process)
        configuration.platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        configuration.labels = ["shared": "container", "container-only": "new"]
        configuration.stopSignal = "SIGTERM"
        return ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])
    }

    private func sourceImage() -> Image {
        Image(
            author: "source-author",
            architecture: "arm64",
            os: "linux",
            osVersion: "1.0",
            osFeatures: ["feature"],
            config: ImageConfig(labels: ["source-only": "old", "shared": "source"]),
            rootfs: Rootfs(type: "layers", diffIDs: [])
        )
    }

    private func blob(_ descriptor: Descriptor, in directory: URL) throws -> Data {
        let digest = try #require(descriptor.digest.split(separator: ":").last)
        let data = try Data(contentsOf: directory.appendingPathComponent("blobs/sha256/\(digest)"))
        #expect(descriptor.size == data.count)
        #expect(descriptor.digest == "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        return data
    }
}

extension Collection {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
