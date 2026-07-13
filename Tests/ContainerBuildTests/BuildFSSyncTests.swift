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

import CryptoKit
import Foundation
import Testing

@testable import ContainerBuild

struct BuildFSSyncTests {
    @Test
    func fileInfoUsesLiteralSymlinkTarget() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("container-build-fssync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let link = root.appendingPathComponent("payload-link.txt")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "payload.txt")

        let info = try BuildFSSync.FileInfo(path: link, contextDir: root)

        #expect(info.name == "payload-link.txt")
        #expect(info.target == "payload.txt")
    }

    @Test
    func readUsesNamedContextDirectory() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("container-build-fssync-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("main", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fileManager.createDirectory(at: main, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try Data("main".utf8).write(to: main.appendingPathComponent("payload.txt"))
        try Data("shared".utf8).write(to: shared.appendingPathComponent("payload.txt"))

        let fssync = try BuildFSSync(main, namedContexts: ["shared": shared.path])
        let (stream, continuation) = AsyncStream<ClientStream>.makeStream()

        var transfer = BuildTransfer()
        transfer.id = "request-id"
        transfer.source = "payload.txt"
        transfer.metadata = [
            "stage": "fssync",
            "method": "Read",
            "dir-name": "shared",
            "offset": "0",
            "length": "6",
        ]
        var request = ServerStream()
        request.buildID = "build-id"
        request.buildTransfer = transfer
        request.packetType = .buildTransfer(transfer)

        try await fssync.handle(continuation, request)
        continuation.finish()

        var responses: [ClientStream] = []
        for await response in stream {
            responses.append(response)
        }

        let response = try #require(responses.first)
        #expect(String(data: response.buildTransfer.data, encoding: .utf8) == "shared")
        #expect(response.buildTransfer.source == "payload.txt")
    }

    @Test
    func tarHeaderChecksumMatchesTransferredArchive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("container-build-fssync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try Data("FROM scratch\n".utf8).write(to: root.appendingPathComponent("Dockerfile"))
        let fssync = try BuildFSSync(root)
        let (stream, continuation) = AsyncStream<ClientStream>.makeStream()

        var transfer = BuildTransfer()
        transfer.id = "request-id"
        transfer.source = "."
        transfer.metadata = [
            "stage": "fssync",
            "method": "Walk",
            "mode": "tar",
            "followpaths": "Dockerfile",
        ]
        var request = ServerStream()
        request.buildID = "build-id"
        request.buildTransfer = transfer
        request.packetType = .buildTransfer(transfer)

        try await fssync.handle(continuation, request)
        continuation.finish()

        var responses: [ClientStream] = []
        for await response in stream {
            responses.append(response)
        }

        let header = try #require(responses.first)
        let expected = try #require(header.buildTransfer.metadata["hash"])
        let archive = responses.reduce(into: Data()) { data, response in
            data.append(response.buildTransfer.data)
        }
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        #expect(actual == expected)
    }

    @Test
    func tarWalkHandlesPrivateTmpAlias() async throws {
        let fileManager = FileManager.default
        let root = URL(filePath: "/private/tmp")
            .appendingPathComponent("container-build-fssync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        try Data().write(to: root.appendingPathComponent("emptyFile"))
        let fssync = try BuildFSSync(root)
        let (stream, continuation) = AsyncStream<ClientStream>.makeStream()

        var transfer = BuildTransfer()
        transfer.id = "request-id"
        transfer.source = "."
        transfer.metadata = [
            "stage": "fssync",
            "method": "Walk",
            "mode": "tar",
            "followpaths": "emptyFile",
        ]
        var request = ServerStream()
        request.buildID = "build-id"
        request.buildTransfer = transfer
        request.packetType = .buildTransfer(transfer)

        try await fssync.handle(continuation, request)
        continuation.finish()

        var responses: [ClientStream] = []
        for await response in stream {
            responses.append(response)
        }

        #expect(responses.first?.buildTransfer.metadata["hash"] != nil)
    }
}
