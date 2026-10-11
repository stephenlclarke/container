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
struct TestCLICopyArchiveStopped {
    private let payload = Data("stopped archive copy payload\n".utf8)

    @Test(arguments: [false, true])
    func archiveCopyPreservesStoppedContainer(previouslyExited: Bool) async throws {
        try await ContainerFixture.with { fixture in
            let image = try fixture.copyWarmupImage(.alpine320)
            let name = "\(fixture.testID)-archive-copy-\(previouslyExited ? "exited" : "created")"
            fixture.addCleanup {
                try fixture.doRemoveIfExists(name, force: true, ignoreFailure: true)
            }

            let workload = "printf run >> /tmp/workload-marker; exit 13"
            try fixture.run(["create", "--name", name, image, "sh", "-ec", workload]).check()
            if previouslyExited {
                let result = try fixture.run(["start", "--attach", name])
                #expect(result.status == 13)
            }

            #expect(try fixture.getContainerStatus(name) == "stopped")
            let inspectBefore = try canonicalInspect(fixture, name: name)

            let archiveInput = fixture.testDir.appending("archive-input.tar")
            try writePayloadArchive(at: URL(filePath: archiveInput.string), payload: payload)
            let inputHandle = try FileHandle(forReadingFrom: URL(filePath: archiveInput.string))
            defer { try? inputHandle.close() }

            let client = ContainerClient()
            try await client.copyIn(
                id: name,
                archive: inputHandle,
                destination: "/tmp/archive-copy"
            )

            let archiveOutput = fixture.testDir.appending("archive-output.tar")
            #expect(FileManager.default.createFile(atPath: archiveOutput.string, contents: nil))
            let outputHandle = try FileHandle(forWritingTo: URL(filePath: archiveOutput.string))
            defer { try? outputHandle.close() }
            try await client.copyOut(
                id: name,
                source: "/tmp/archive-copy/payload.txt",
                archive: outputHandle
            )
            try outputHandle.close()

            let regularEntries = try Array(ArchiveReader(file: URL(filePath: archiveOutput.string)))
                .filter { $0.0.fileType == .regular }
            #expect(regularEntries.count == 1)
            if let (entry, copiedPayload) = regularEntries.first {
                #expect(copiedPayload == payload)
                #expect(entry.permissions == 0o640)
            }

            let workloadMarkerArchive = fixture.testDir.appending("workload-marker.tar")
            #expect(FileManager.default.createFile(atPath: workloadMarkerArchive.string, contents: nil))
            let markerHandle = try FileHandle(forWritingTo: URL(filePath: workloadMarkerArchive.string))
            defer { try? markerHandle.close() }
            if previouslyExited {
                try await client.copyOut(
                    id: name,
                    source: "/tmp/workload-marker",
                    archive: markerHandle
                )
                try markerHandle.close()
                let markerEntries = try Array(ArchiveReader(file: URL(filePath: workloadMarkerArchive.string)))
                    .filter { $0.0.fileType == .regular }
                #expect(markerEntries.count == 1)
                if let (_, marker) = markerEntries.first {
                    #expect(marker == Data("run".utf8))
                }
            } else {
                await #expect(throws: Error.self) {
                    try await client.copyOut(
                        id: name,
                        source: "/tmp/workload-marker",
                        archive: markerHandle
                    )
                }
                try markerHandle.close()
            }

            #expect(try fixture.getContainerStatus(name) == "stopped")
            #expect(try canonicalInspect(fixture, name: name) == inspectBefore)
        }
    }

    private func canonicalInspect(_ fixture: ContainerFixture, name: String) throws -> Data {
        let data = try fixture.run(["inspect", name]).check().outputData
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
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
