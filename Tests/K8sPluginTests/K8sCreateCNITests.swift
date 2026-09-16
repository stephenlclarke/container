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
import ContainerizationError
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerK8s

// MARK: - K8sCreate flag parsing

@Suite("K8sCreate --cni flag")
struct K8sCreateCNIFlagTests {
    @Test func cniDefaultsToNilWhenNotProvided() throws {
        let command = try K8sCreate.parse([])
        #expect(command.cni == nil)
    }

    @Test func cniCapturesProvidedPath() throws {
        let command = try K8sCreate.parse(["--cni", "/tmp/my-cni.yaml"])
        #expect(command.cni == "/tmp/my-cni.yaml")
    }

    @Test func validationAcceptsNoManifest() throws {
        #expect(try K8sCreate.snapshotCNIManifest(at: nil) == nil)
    }

    @Test func validationAcceptsExistingManifest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "kind: ConfigMap\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try K8sCreate.snapshotCNIManifest(at: url.path) == "kind: ConfigMap\n")
    }

    @Test func validationAcceptsSymlinkToExistingManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifest = directory.appendingPathComponent("generated.yaml")
        let link = directory.appendingPathComponent("cni.yaml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "kind: ConfigMap\n".write(to: manifest, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: manifest)

        #expect(try K8sCreate.snapshotCNIManifest(at: link.path) == "kind: ConfigMap\n")
    }

    @Test func validationRejectsMissingManifest() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-missing.yaml").path

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(at: path)
        }
    }

    @Test func validationRejectsDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(at: url.path)
        }
    }

    @Test func validationRejectsNonUTF8Manifest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try Data([0xff, 0xfe]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(at: url.path)
        }
    }

    @Test func validationReportsDescriptorInspectionFailure() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "kind: ConfigMap\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(
                at: url.path,
                inspect: { _, _ in
                    errno = EIO
                    return -1
                }
            )
        }
    }

    @Test func validationReportsDescriptorReadFailure() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "kind: ConfigMap\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(
                at: url.path,
                read: { _ in throw CocoaError(.fileReadCorruptFile) }
            )
        }
    }

    @Test func validationRejectsUnreadableManifest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "kind: ConfigMap\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(at: url.path)
        }
    }

    @Test func validationRejectsFIFOWithoutBlocking() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".fifo")
        #expect(mkfifo(url.path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ContainerizationError.self) {
            _ = try K8sCreate.snapshotCNIManifest(at: url.path)
        }
    }

    @Test func snapshotDoesNotChangeWhenSourceIsReplaced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try "kind: ConfigMap\nmetadata:\n  name: original\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try K8sCreate.snapshotCNIManifest(at: url.path)
        try "kind: ConfigMap\nmetadata:\n  name: replacement\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(snapshot?.contains("name: original") == true)
        #expect(snapshot?.contains("name: replacement") == false)
    }

    @Test func runRejectsMissingManifestBeforeProvisioning() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-missing.yaml").path
        let command = try K8sCreate.parse(["--cni", path])

        await #expect(throws: ContainerizationError.self) {
            try await command.run()
        }
    }
}

// MARK: - K8sHelper.resolveCNIManifest

@Suite("K8sHelper.resolveCNIManifest")
struct ResolveCNIManifestTests {
    private let log = Logger(label: "test")

    @Test func customManifestIsReturnedWithoutAnotherRead() async throws {
        let contents = "kind: DaemonSet\nmetadata:\n  name: my-custom-cni\n"

        let result = try await K8sHelper.resolveCNIManifest(customManifest: contents, log: log)
        #expect(result == contents)
    }

    @Test func defaultManifestRequiresAnInstalledK8sPlugin() async {
        await #expect(throws: ContainerizationError.self) {
            _ = try await K8sHelper.resolveCNIManifest(customManifest: nil, log: log)
        }
    }
}

// MARK: - K8sHelper.cniApplyInvocation

@Suite("K8sHelper.cniApplyInvocation")
struct CNIApplyInvocationTests {
    @Test func streamsLargeManifestWithoutAddingItToArguments() throws {
        let marker = "cni-payload-marker"
        let manifest = String(repeating: "# \(marker)\n", count: 20_000)

        let invocation = K8sHelper.cniApplyInvocation(manifest: manifest)

        #expect(invocation.executable == "/bin/kubectl")
        #expect(invocation.arguments == ["--kubeconfig", "/etc/kubernetes/admin.conf", "apply", "-f", "-"])
        #expect(!invocation.arguments.contains(where: { $0.contains(marker) }))
        #expect(String(data: invocation.standardInput, encoding: .utf8) == manifest)
    }
}

// MARK: - K8sHelper standard input staging

@Suite("K8sHelper standard input staging")
struct StandardInputStagingTests {
    @Test func nilInputNeedsNoFile() throws {
        let staged = try K8sHelper.stageStandardInput(nil)
        defer { staged.cleanup() }

        #expect(staged.handle == nil)
        #expect(staged.url == nil)
    }

    @Test func dataIsStagedPrivatelyAndRemoved() throws {
        let payload = Data("manifest payload".utf8)
        let staged = try K8sHelper.stageStandardInput(payload)
        let url = try #require(staged.url)
        let handle = try #require(staged.handle)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(handle.readDataToEndOfFile() == payload)

        staged.cleanup()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func creationFailureIsReported() throws {
        #expect(throws: ContainerizationError.self) {
            _ = try K8sHelper.stageStandardInput(Data("manifest payload".utf8)) { _, _ in
                false
            }
        }
    }

    @Test func openFailureRemovesTheStagedFile() throws {
        var stagedPath: String?

        #expect(throws: CocoaError.self) {
            _ = try K8sHelper.stageStandardInput(
                Data("manifest payload".utf8),
                createFile: { path, contents in
                    stagedPath = path
                    return FileManager.default.createFile(atPath: path, contents: contents)
                },
                openFile: { _ in
                    throw CocoaError(.fileReadNoSuchFile)
                }
            )
        }

        let path = try #require(stagedPath)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - K8sHelper.applyCNIManifest

@Suite("K8sHelper.applyCNIManifest")
struct ApplyCNIManifestTests {
    private let log = Logger(label: "test")

    @Test func customManifestIsStreamedToKubectl() async throws {
        let manifest = "kind: DaemonSet\nmetadata:\n  name: custom-cni\n"

        let recorder = CNIInvocationRecorder()
        try await K8sHelper.applyCNIManifest(
            nodeID: "test-node",
            manifest: manifest,
            client: ContainerClient(),
            log: log
        ) { containerID, executable, arguments, _, standardInput in
            await recorder.record(
                containerID: containerID,
                executable: executable,
                arguments: arguments,
                standardInput: standardInput
            )
            return (0, "configured")
        }

        let invocation = await recorder.invocation
        #expect(invocation?.containerID == "test-node")
        #expect(invocation?.executable == "/bin/kubectl")
        #expect(invocation?.arguments == ["--kubeconfig", "/etc/kubernetes/admin.conf", "apply", "-f", "-"])
        #expect(invocation?.standardInput == Data(manifest.utf8))
    }

    @Test func kubectlFailureIsReported() async throws {
        await #expect(throws: ContainerizationError.self) {
            try await K8sHelper.applyCNIManifest(
                nodeID: "test-node",
                manifest: "kind: DaemonSet\n",
                client: ContainerClient(),
                log: log
            ) { _, _, _, _, _ in
                (17, "kubectl rejected manifest")
            }
        }
    }
}

private actor CNIInvocationRecorder {
    struct Invocation {
        let containerID: String
        let executable: String
        let arguments: [String]
        let standardInput: Data
    }

    private(set) var invocation: Invocation?

    func record(containerID: String, executable: String, arguments: [String], standardInput: Data) {
        invocation = Invocation(
            containerID: containerID,
            executable: executable,
            arguments: arguments,
            standardInput: standardInput
        )
    }
}
