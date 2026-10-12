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
import ContainerTestSupport
import ContainerizationArchive
import Foundation
import Testing

@Suite
struct TestCLICopySymlink {
    private let payload = Data("symlink-copy-payload\n".utf8)

    @Test(arguments: ["created", "running", "exited"])
    func copiesPreserveSymlinks(state: String) async throws {
        try await ContainerFixture.with { fixture in
            let image = try fixture.copyWarmupImage(.alpine320)
            let name = "\(fixture.testID)-symlink-copy-\(state)"
            fixture.addCleanup {
                try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true)
            }

            let command = state == "running" ? "sleep 300" : "exit 0"
            try fixture.run(["create", "--name", name, image, "sh", "-ec", command]).check()
            switch state {
            case "running":
                try fixture.run(["start", name]).check()
                try await fixture.waitForContainerRunning(name)
            case "exited":
                try fixture.run(["start", "--attach", name]).check()
            default:
                break
            }

            let statusBefore = try fixture.getContainerStatus(name)
            let inspectBefore = try canonicalInspect(fixture, name: name)
            if state == "created" {
                #expect(statusBefore == "stopped")
                #expect(try hasStartedDate(fixture, name: name) == false)
            } else if state == "running" {
                #expect(statusBefore == "running")
            } else {
                #expect(statusBefore == "stopped")
            }

            let archive = fixture.testDir.appending("symlink-fixture.tar")
            try writeFixtureArchive(at: URL(filePath: archive.string))
            let archiveHandle = try FileHandle(forReadingFrom: URL(filePath: archive.string))
            defer { try? archiveHandle.close() }
            try await ContainerClient().copyIn(
                id: name,
                archive: archiveHandle,
                destination: "/tmp/symlink-fixture"
            )

            let links = [
                (name: "relative-link", target: "payload"),
                (name: "absolute-link", target: "/tmp/symlink-fixture/payload"),
                (name: "dangling-link", target: "missing"),
            ]
            for link in links {
                let destination = fixture.testDir.appending("default-\(link.name)")
                try fixture.run([
                    "cp", "\(name):/tmp/symlink-fixture/\(link.name)", destination.string,
                ]).check()
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.string) == link.target)
            }

            for link in links.prefix(2) {
                let destination = fixture.testDir.appending("followed-\(link.name)")
                try fixture.run([
                    "cp", "-L", "\(name):/tmp/symlink-fixture/\(link.name)", destination.string,
                ]).check()
                #expect(try Data(contentsOf: URL(filePath: destination.string)) == payload)
                #expect(try fileMode(at: destination.string) == 0o640)
            }

            let danglingFollow = fixture.testDir.appending("followed-dangling-link")
            let danglingResult = try fixture.run([
                "cp", "-L", "\(name):/tmp/symlink-fixture/dangling-link", danglingFollow.string,
            ])
            #expect(danglingResult.status != 0)
            #expect(!FileManager.default.fileExists(atPath: danglingFollow.string))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: danglingFollow.string)) == nil)

            #expect(try fixture.getContainerStatus(name) == statusBefore)
            #expect(try canonicalInspect(fixture, name: name) == inspectBefore)
        }
    }

    private func canonicalInspect(_ fixture: ContainerFixture, name: String) throws -> Data {
        let data = try fixture.run(["inspect", name]).check().outputData
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func hasStartedDate(_ fixture: ContainerFixture, name: String) throws -> Bool {
        let data = try fixture.run(["inspect", name]).check().outputData
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let rows = value as? [[String: Any]],
            let first = rows.first,
            let status = first["status"] as? [String: Any]
        else {
            throw CommandError.executionFailed("container inspect did not include status")
        }
        return status["startedDate"] != nil && !(status["startedDate"] is NSNull)
    }

    private func fileMode(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func writeFixtureArchive(at url: URL) throws {
        let writer = try ArchiveWriter(format: .pax, filter: .none, file: url)
        let payloadEntry = WriteEntry()
        payloadEntry.path = "payload"
        payloadEntry.fileType = .regular
        payloadEntry.permissions = 0o640
        payloadEntry.size = Int64(payload.count)
        try writer.writeEntry(entry: payloadEntry, data: payload)

        for (path, target) in [
            ("relative-link", "payload"),
            ("absolute-link", "/tmp/symlink-fixture/payload"),
            ("dangling-link", "missing"),
        ] {
            let entry = WriteEntry()
            entry.path = path
            entry.fileType = .symbolicLink
            entry.permissions = 0o777
            entry.symlinkTarget = target
            try writer.writeEntry(entry: entry, data: nil)
        }
        try writer.finishEncoding()
    }
}
