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
import ContainerPersistence
import ContainerResource
import ContainerTestSupport
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Testing

@Suite
struct TestCLICopyColdStopped {
    private let payload = Data("cold-copy-payload\n".utf8)
    private let archivePayload = Data("archive-copy-payload\n".utf8)

    private struct CreationEnvelope: Decodable {
        let options: ContainerCreateOptions
    }

    @Test(arguments: [false, true])
    func copyDoesNotRunWorkloadOrChangeLogs(prewarm: Bool) async throws {
        try await ContainerFixture.with { fixture in
            let imageReference = try fixture.copyWarmupImage(.alpine320)
            let name = "\(fixture.testID)-cold-copy-\(prewarm ? "prewarm" : "cold")"
            fixture.addCleanup {
                try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true)
            }

            let workload =
                "test \"$(cat /tmp/stopped-copy-file)\" = 'cold-copy-payload'; "
                + "test \"$(cat /tmp/stopped-copy-archive/payload.txt)\" = 'archive-copy-payload'; "
                + "printf 'started-after-copy' > /tmp/workload-marker; exit 13"
            let image = try await ClientImage.get(
                reference: imageReference,
                containerSystemConfig: ContainerSystemConfig()
            )
            var configuration = ContainerConfiguration(
                id: name,
                image: image.description,
                process: ProcessConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-ec", workload],
                    environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
                )
            )
            configuration.resources.cpus = 1
            configuration.resources.memoryInBytes = 512 * 1024 * 1024
            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            let client = ContainerClient()
            try await client.create(
                configuration: configuration,
                options: ContainerCreateOptions(autoRemove: false, prewarm: prewarm),
                kernel: kernel
            )

            let bundle = try containerBundleURL(id: name)
            let creation = try JSONDecoder().decode(
                CreationEnvelope.self,
                from: Data(contentsOf: bundle.appendingPathComponent("runtime-configuration.json"))
            )
            #expect(creation.options.prewarm == prewarm)
            if prewarm {
                try await waitForBootstrap(name)
            }

            #expect(try fixture.getContainerStatus(name) == "stopped")
            let inspectBefore = try canonicalInspect(fixture, name: name)
            let logsBefore = try snapshotLogArtifacts(bundle: bundle)

            let source = fixture.testDir.appending("source.txt")
            try payload.write(to: URL(filePath: source.string))
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.string)
            try fixture.run(["cp", source.string, "\(name):/tmp/stopped-copy-file"]).check()

            if !prewarm {
                // The first regular copy must finish before any copy-only guest boot.
                let prepared = ContainerResource.Bundle(path: bundle)
                #expect(try prepared.isPrepared)
                #expect(try prepared.containerRootfs.source == prepared.containerRootfsBlock.path)
                #expect(!FileManager.default.fileExists(atPath: prepared.bootlog.path))
                #expect(try snapshotLogArtifacts(bundle: bundle) == logsBefore)
            }

            let copiedFile = fixture.testDir.appending("copied-file.txt")
            try fixture.run(["cp", "\(name):/tmp/stopped-copy-file", copiedFile.string]).check()
            #expect(try Data(contentsOf: URL(filePath: copiedFile.string)) == payload)
            #expect(try fileMode(at: copiedFile.string) == 0o640)

            let archiveInput = fixture.testDir.appending("archive-input.tar")
            try writePayloadArchive(at: URL(filePath: archiveInput.string), payload: archivePayload)
            let archiveInputHandle = try FileHandle(forReadingFrom: URL(filePath: archiveInput.string))
            defer { try? archiveInputHandle.close() }
            try await client.copyIn(
                id: name,
                archive: archiveInputHandle,
                destination: "/tmp/stopped-copy-archive"
            )

            let archiveOutput = fixture.testDir.appending("archive-output.tar")
            #expect(FileManager.default.createFile(atPath: archiveOutput.string, contents: nil))
            let archiveOutputHandle = try FileHandle(forWritingTo: URL(filePath: archiveOutput.string))
            defer { try? archiveOutputHandle.close() }
            try await client.copyOut(
                id: name,
                source: "/tmp/stopped-copy-archive/payload.txt",
                archive: archiveOutputHandle
            )
            try archiveOutputHandle.close()
            let entries = try Array(ArchiveReader(file: URL(filePath: archiveOutput.string)))
                .filter { $0.0.fileType == .regular }
            #expect(entries.count == 1)
            if let (entry, contents) = entries.first {
                #expect(contents == archivePayload)
                #expect(entry.permissions == 0o640)
            }

            let markerArchive = fixture.testDir.appending("marker-before-start.tar")
            #expect(FileManager.default.createFile(atPath: markerArchive.string, contents: nil))
            let markerHandle = try FileHandle(forWritingTo: URL(filePath: markerArchive.string))
            defer { try? markerHandle.close() }
            await #expect(throws: Error.self) {
                try await client.copyOut(id: name, source: "/tmp/workload-marker", archive: markerHandle)
            }
            try markerHandle.close()

            #expect(try fixture.getContainerStatus(name) == "stopped")
            #expect(try canonicalInspect(fixture, name: name) == inspectBefore)
            #expect(try snapshotLogArtifacts(bundle: bundle) == logsBefore)

            let start = try fixture.run(["start", "--attach", name])
            #expect(start.status == 13)
            #expect(try fixture.getContainerStatus(name) == "stopped")

            let markerAfterStart = fixture.testDir.appending("marker-after-start.tar")
            #expect(FileManager.default.createFile(atPath: markerAfterStart.string, contents: nil))
            let markerAfterStartHandle = try FileHandle(forWritingTo: URL(filePath: markerAfterStart.string))
            defer { try? markerAfterStartHandle.close() }
            try await client.copyOut(
                id: name,
                source: "/tmp/workload-marker",
                archive: markerAfterStartHandle
            )
            try markerAfterStartHandle.close()
            let markerEntries = try Array(ArchiveReader(file: URL(filePath: markerAfterStart.string)))
                .filter { $0.0.fileType == .regular }
            #expect(markerEntries.count == 1)
            if let (_, contents) = markerEntries.first {
                #expect(contents == Data("started-after-copy".utf8))
            }
        }
    }

    @Test
    func defaultCLIKeepCreatedContainerColdUntilFirstStart() async throws {
        try await ContainerFixture.with { fixture in
            let image = try fixture.copyWarmupImage(.alpine320)
            let name = "\(fixture.testID)-cli-cold-copy"
            fixture.addCleanup { try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            try fixture.run([
                "create", "--name", name, "--network", "none", "--cpus", "1", "--memory", "512m", image,
                "sh", "-ec", "test \"$(cat /tmp/payload)\" = 'cold-copy-payload'",
            ]).check()
            let path = try containerBundleURL(id: name)
            let creation = try JSONDecoder().decode(
                CreationEnvelope.self,
                from: Data(contentsOf: path.appendingPathComponent("runtime-configuration.json")))
            #expect(!creation.options.prewarm)
            let source = fixture.testDir.appending("cli-source")
            try payload.write(to: URL(filePath: source.string))
            try fixture.run(["cp", source.string, "\(name):/tmp/payload"]).check()
            #expect(try ContainerResource.Bundle(path: path).isPrepared)
            #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("vminitd.log").path))
            try fixture.run(["start", "--attach", name]).check()
        }
    }

    @Test
    func readonlyCopyInFailsBeforePreparationAndCopyOutStillWorks() async throws {
        try await ContainerFixture.with { fixture in
            let imageReference = try fixture.copyWarmupImage(.alpine320)
            let name = "\(fixture.testID)-readonly-copy"
            fixture.addCleanup { try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let image = try await ClientImage.get(reference: imageReference, containerSystemConfig: ContainerSystemConfig())
            var configuration = ContainerConfiguration(
                id: name, image: image.description,
                process: .init(executable: "/bin/true", arguments: [], environment: []))
            configuration.readOnly = true
            configuration.resources.cpus = 1
            configuration.resources.memoryInBytes = 512 * 1024 * 1024
            let kernel = try await ClientKernel.getDefaultKernel(for: .current)
            try await ContainerClient().create(
                configuration: configuration,
                options: .init(autoRemove: false, prewarm: false), kernel: kernel)
            let path = try containerBundleURL(id: name)
            let bundle = ContainerResource.Bundle(path: path)
            let before = try canonicalInspect(fixture, name: name)
            let logsBefore = try snapshotLogArtifacts(bundle: path)
            let source = fixture.testDir.appending("readonly-source")
            try payload.write(to: URL(filePath: source.string))
            let directory = fixture.testDir.appending("readonly-directory")
            try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: false)
            try payload.write(to: URL(fileURLWithPath: directory.string).appendingPathComponent("payload"))
            for input in [source.string, directory.string] {
                let result = try fixture.run(["cp", input, "\(name):/tmp/readonly-copy"])
                #expect(result.status == 1)
            }
            #expect(try !bundle.isPrepared)
            #expect(!FileManager.default.fileExists(atPath: bundle.containerRootfsBlock.path))
            #expect(!FileManager.default.fileExists(atPath: bundle.bootlog.path))
            #expect(try canonicalInspect(fixture, name: name) == before)
            #expect(try snapshotLogArtifacts(bundle: path) == logsBefore)
            try fixture.run(["cp", "\(name):/etc/alpine-release", fixture.testDir.appending("release").string]).check()
            #expect(try bundle.isPrepared)
            #expect(!FileManager.default.fileExists(atPath: bundle.bootlog.path))
            #expect(try canonicalInspect(fixture, name: name) == before)
        }
    }

    private func containerBundleURL(id: String) throws -> URL {
        guard let appRoot = ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"] else {
            throw CommandError.executionFailed("CONTAINER_APP_ROOT is required to inspect copy bundle state")
        }
        return URL(fileURLWithPath: appRoot, isDirectory: true)
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func waitForBootstrap(_ id: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["CLITEST_APISERVER_LOG"] else {
            throw CommandError.executionFailed("CLITEST_APISERVER_LOG is required for prewarm proof")
        }
        let logURL = URL(fileURLWithPath: path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: logURL, encoding: .utf8),
                text.split(separator: "\n").contains(where: {
                    $0.contains("container bootstrap timings")
                        && ($0.contains("\"id\": \(id),") || $0.contains("\"id\": \(id)]"))
                        && ($0.contains("\"outcome\": success,") || $0.contains("\"outcome\": success]"))
                })
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommandError.executionFailed("prewarm bootstrap did not complete before log snapshot")
    }

    private func snapshotLogArtifacts(bundle: URL) throws -> [String: Data] {
        let paths = [
            "stdio.log",
            "stdio.jsonl",
            "logging-v2",
        ]
        var snapshot: [String: Data] = [:]
        for relativePath in paths {
            let url = bundle.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                snapshot[relativePath] = Data("<absent>".utf8)
                continue
            }
            if isDirectory.boolValue {
                snapshot[relativePath] = try logArtifactSnapshot(at: url, directory: true)
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey]
                )
                while let file = enumerator?.nextObject() as? URL {
                    let values = try file.resourceValues(forKeys: [.isDirectoryKey])
                    let key = relativePath + "/" + file.path.replacingOccurrences(of: url.path + "/", with: "")
                    snapshot[key] = try logArtifactSnapshot(at: file, directory: values.isDirectory == true)
                }
            } else {
                snapshot[relativePath] = try logArtifactSnapshot(at: url, directory: false)
            }
        }
        return snapshot
    }

    private func logArtifactSnapshot(at url: URL, directory: Bool) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        var snapshot = Data("\(directory ? "directory" : "file")|\(modified.timeIntervalSince1970)|\(size)|\(mode)|".utf8)
        if !directory {
            snapshot.append(try Data(contentsOf: url))
        }
        return snapshot
    }

    private func canonicalInspect(_ fixture: ContainerFixture, name: String) throws -> Data {
        let data = try fixture.run(["inspect", name]).check().outputData
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func fileMode(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writePayloadArchive(at url: URL, payload: Data) throws {
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: url)
        let entry = WriteEntry()
        entry.path = "payload.txt"
        entry.fileType = .regular
        entry.permissions = 0o640
        entry.size = Int64(payload.count)
        try writer.writeEntry(entry: entry, data: payload)
        try writer.finishEncoding()
    }
}
