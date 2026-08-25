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

import ContainerizationOS
import CryptoKit
import Foundation
import SystemPackage
import Testing

@testable import ContainerBuild

// Tests for BuildFSSync — the handler that serves build-context files to the
// builder over the FSSync protocol.  The suite creates real files on disk and
// calls the actor methods directly, bypassing the Walk/cache layer in the shim
// so that the macOS-side boundary enforcement is exercised in isolation.
@Suite class BuildFSSyncTests {
    let fm = FileManager.default
    let base: URL
    let contextDir: URL
    let outsideDir: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        contextDir = base.appendingPathComponent("context")
        outsideDir = base.appendingPathComponent("outside")
        try fm.createDirectory(at: URL(fileURLWithPath: contextDir.path(percentEncoded: false)), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: outsideDir.path(percentEncoded: false)), withIntermediateDirectories: true)
    }

    deinit {
        try? fm.removeItem(at: base)
    }

    // MARK: - Helpers

    private func write(_ content: String, to url: URL) throws {
        try content.data(using: .utf8)!.write(to: url)
    }

    /// Returns a minimal BuildTransfer packet for the given context-relative source path.
    private func readPacket(source: String) -> BuildTransfer {
        var p = BuildTransfer()
        p.id = UUID().uuidString
        p.source = source
        return p
    }

    // MARK: - read(): symlink boundary enforcement
    //
    // The tests below call read() directly and expect it to throw when the
    // requested path resolves outside the context directory.
    //
    // Final-component symlink tests (testReadRejectsAbsoluteSymlinkOutsideContext,
    // testReadRejectsRelativeSymlinkOutsideContext): the source path is itself a
    // symlink that resolves outside the context.
    //
    // Intermediate-component symlink test (testReadRejectsIntermediateDirectorySymlinkOutsideContext):
    // the source path looks like a normal relative path ("subdir/secret.txt"), but
    // an intermediate directory component is a symlink that escapes the context.
    // read() unconditionally resolves the full path and checks parentOf, so this
    // case is caught as well.

    @Test func testReadRejectsAbsoluteSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        // Symlink inside context → absolute path outside context.
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: secretFile.path(percentEncoded: false)
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.read(continuation, readPacket(source: "leak"), "build-0")
            Issue.record("read() should throw BuildFSSync.Error for a symlink that resolves outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    @Test func testReadRejectsRelativeSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        // Symlink inside context → relative path that traverses above the context root.
        // contextDir = base/context, outsideDir = base/outside, so the relative
        // path from base/context/leak to base/outside/secret.txt is ../outside/secret.txt.
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: "../outside/secret.txt"
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.read(continuation, readPacket(source: "leak"), "build-0")
            Issue.record("read() should throw BuildFSSync.Error for a relative symlink that resolves outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    @Test func testReadRejectsIntermediateDirectorySymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        // Directory symlink inside context → directory outside context.
        // The requested source "subdir/secret.txt" has a plain file as its final
        // component, but read() resolves the full path unconditionally, so the
        // intermediate symlink escape is caught by the parentOf check.
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("subdir").path(percentEncoded: false),
            withDestinationPath: outsideDir.path(percentEncoded: false)
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.read(continuation, readPacket(source: "subdir/secret.txt"), "build-0")
            Issue.record("read() should throw BuildFSSync.Error when an intermediate path component is a symlink outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    // MARK: - info(): symlink boundary enforcement
    //
    // info() is the metadata-only half of the shim's FS.Open() fallback path.
    // It must enforce the same context boundary as read(). All three tests
    // below should pass: the fix unconditionally resolves the full path and
    // checks parentOf before serving any metadata.

    @Test func testInfoRejectsAbsoluteSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: secretFile.path(percentEncoded: false)
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.info(continuation, readPacket(source: "leak"), "build-0")
            Issue.record("info() should throw BuildFSSync.Error for a symlink that resolves outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    @Test func testInfoRejectsRelativeSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: "../outside/secret.txt"
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.info(continuation, readPacket(source: "leak"), "build-0")
            Issue.record("info() should throw BuildFSSync.Error for a relative symlink that resolves outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    @Test func testInfoRejectsIntermediateDirectorySymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("subdir").path(percentEncoded: false),
            withDestinationPath: outsideDir.path(percentEncoded: false)
        )

        let fssync = try BuildFSSync(contextDir)
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.info(continuation, readPacket(source: "subdir/secret.txt"), "build-0")
            Issue.record("info() should throw BuildFSSync.Error when an intermediate path component is a symlink outside the context")
        } catch is BuildFSSync.Error {
            // expected
        }
    }

    // MARK: - walk(): directory symlink boundary enforcement
    //
    // walk() is the primary data path — every build goes through it, and its
    // results are what gets packed into the tar sent to the builder. A
    // directory symlink inside the context must not let anything physically
    // outside the context root end up in those results. The test below
    // asserts that directly.

    @Test func testWalkDoesNotFollowDirectorySymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        // Directory symlink inside context → directory outside context.
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("subdir").path(percentEncoded: false),
            withDestinationPath: outsideDir.path(percentEncoded: false)
        )

        let fssync = try BuildFSSync(contextDir)
        // Request the symlinked directory. Globber.childrenRecursive follows it
        // and currently returns the external file as if it were in the context.
        let urls = try await fssync.walk(root: contextDir, includePatterns: ["subdir"])

        // The directory symlink itself is expected in results (Rule 2: it appears
        // as a symlink entry in the tar). What must not appear are non-symlink
        // entries — regular files or directories — that physically reside outside
        // the context root.
        let leaked = urls.filter { url in
            guard !url.isSymlink else { return false }
            let resolved = url.resolvingSymlinksInPath()
            return !self.contextDir.parentOf(resolved)
                && resolved.cleanPath != self.contextDir.cleanPath
        }

        #expect(leaked.isEmpty, "walk() returned non-symlink URLs that physically resolve outside the context: \(leaked)")
    }

    // MARK: - walk(): JSON/FileInfo metadata paths
    //
    // walk() has two response formats: a tar stream (the primary data path,
    // handled above) and a JSON array of FileInfo, used for metadata-only
    // walks. FileInfo.target reports the same literal, unresolved on-disk
    // symlink destination for every symlink — in-context or not — that tar
    // mode already exposes via Archiver's use of destinationOfSymbolicLink.
    // It must never be an absolute or canonicalized path derived from
    // resolvingSymlinksInPath(), which would disclose a host-resolved path
    // for a symlink that escapes the context.

    /// Returns a minimal BuildTransfer packet requesting a JSON-mode walk.
    private func walkJSONPacket(followPaths: [String]) -> BuildTransfer {
        var p = BuildTransfer()
        p.id = UUID().uuidString
        p.source = "."
        p.metadata = [
            "followpaths": followPaths.joined(separator: ","),
            "mode": "json",
        ]
        return p
    }

    /// Drives the actor's real walk(_:_:_:) method in JSON mode and decodes
    /// the resulting FileInfo array.
    private func walkJSON(_ fssync: BuildFSSync, followPaths: [String] = ["*"]) async throws -> [BuildFSSync.FileInfo] {
        var continuation: AsyncStream<ClientStream>.Continuation!
        let stream = AsyncStream<ClientStream> { continuation = $0 }
        try await fssync.walk(continuation, walkJSONPacket(followPaths: followPaths), "build-0")
        continuation.finish()

        var fileInfos: [BuildFSSync.FileInfo] = []
        for await resp in stream {
            let data = resp.buildTransfer.data
            if !data.isEmpty {
                fileInfos += try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: data)
            }
        }
        return fileInfos
    }

    private func walkTAR(
        _ fssync: BuildFSSync,
        followPaths: [String] = ["*"],
        dirName: String? = nil
    ) async throws -> [ClientStream] {
        var packet = walkJSONPacket(followPaths: followPaths)
        packet.metadata["mode"] = "tar"
        if let dirName {
            packet.metadata["dir-name"] = dirName
        }

        var continuation: AsyncStream<ClientStream>.Continuation!
        let stream = AsyncStream<ClientStream> { continuation = $0 }
        try await fssync.walk(continuation, packet, "build-0")
        continuation.finish()

        var responses: [ClientStream] = []
        for await response in stream {
            responses.append(response)
        }
        return responses
    }

    @Test("A cached context sends only a completed digest header")
    func cachedContextSkipsTarBody() async throws {
        try write("hello", to: contextDir.appendingPathComponent("plain.txt"))
        let fssync = try BuildFSSync(contextDir) { digest in
            #expect(digest.count == 64)
            return true
        }

        let responses = try await walkTAR(fssync)
        let header = try #require(responses.first).buildTransfer
        #expect(responses.count == 1)
        #expect(header.complete)
        #expect(header.data.isEmpty)
        #expect(header.metadata["hash"]?.count == 64)
    }

    @Test("A missing context retains the ordered tar stream")
    func missingContextStreamsTarBody() async throws {
        try write("hello", to: contextDir.appendingPathComponent("plain.txt"))
        let fssync = try BuildFSSync(contextDir) { _ in false }

        let responses = try await walkTAR(fssync)
        let transfers = responses.map(\.buildTransfer)
        let header = try #require(transfers.first)
        let completion = try #require(transfers.last)
        #expect(transfers.count >= 3)
        #expect(!header.complete)
        #expect(header.metadata["hash"]?.count == 64)
        #expect(transfers.dropFirst().dropLast().contains { !$0.data.isEmpty })
        #expect(completion.complete)
    }

    @Test("Named contexts archive from their selected root")
    func namedContextTarUsesSelectedRoot() async throws {
        let shared = base.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try write("main-only", to: contextDir.appendingPathComponent("payload.txt"))
        try write("shared-only", to: shared.appendingPathComponent("payload.txt"))

        let fssync = try BuildFSSync(contextDir, namedContexts: ["shared": shared.path])
        let responses = try await walkTAR(fssync, dirName: "shared")
        let body = responses.dropFirst().dropLast().reduce(into: Data()) { result, response in
            result.append(response.buildTransfer.data)
        }
        let archive = String(decoding: body, as: UTF8.self)

        #expect(archive.contains("shared-only"))
        #expect(!archive.contains("main-only"))
    }

    @Test("Context archive work does not hold actor isolation")
    func contextArchiveDoesNotBlockActor() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = BuildArchiveIsolationProbe()
        let archive = Task {
            try await probe.archive(started: started, release: release)
        }

        let didStart = await BuildArchiveSemaphore.wait(started, timeout: .now() + 1)
        guard didStart else {
            release.signal()
            archive.cancel()
            throw BuildArchiveTestError.timedOut
        }

        let pinged = BuildArchiveCountdown(count: 1)
        let ping = Task {
            await probe.ping(pinged)
        }
        do {
            try await pinged.wait(timeout: .seconds(1))
        } catch {
            release.signal()
            archive.cancel()
            throw error
        }

        release.signal()
        await ping.value
        #expect(try await archive.value == SHA256.hash(data: Data()))
    }

    @Test func testWalkJSONReportsEmptyTargetForRegularFile() async throws {
        try write("hello", to: contextDir.appendingPathComponent("plain.txt"))

        let fssync = try BuildFSSync(contextDir)
        let infos = try await walkJSON(fssync)

        let plain = infos.first { $0.name == "plain.txt" }
        #expect(plain != nil, "the regular file should appear in walk() results")
        #expect(plain?.target == "", "a regular file should report an empty target")
    }

    @Test func testWalkJSONReportsLiteralTargetForInContextSymlink() async throws {
        try write("hello", to: contextDir.appendingPathComponent("real.txt"))
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("alias").path(percentEncoded: false),
            withDestinationPath: "real.txt"
        )

        let fssync = try BuildFSSync(contextDir)
        let infos = try await walkJSON(fssync)

        let alias = infos.first { $0.name == "alias" }
        #expect(alias != nil, "the in-context symlink should appear in walk() results")
        #expect(alias?.target == "real.txt", "in-context symlink target should be the literal on-disk value, got \(alias?.target ?? "nil")")
    }

    @Test func testWalkJSONReportsLiteralTargetForAbsoluteSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        let literalDestination = secretFile.path(percentEncoded: false)
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: literalDestination
        )

        let fssync = try BuildFSSync(contextDir)
        let infos = try await walkJSON(fssync)

        let leak = infos.first { $0.name == "leak" }
        #expect(leak != nil, "the escaping symlink should still appear in walk() results")
        #expect(
            leak?.target == literalDestination,
            "target should be the literal symlink destination, not a resolved/canonicalized path: \(leak?.target ?? "nil")")
    }

    @Test func testWalkJSONReportsLiteralTargetForRelativeSymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        // contextDir = base/context, outsideDir = base/outside, so the
        // relative destination from context/leak to outside/secret.txt is
        // ../outside/secret.txt. Resolving this always yields an absolute
        // path, so a literal-vs-resolved mismatch here is deterministic and
        // does not depend on any symlink quirks in the host's temp dir.
        let literalDestination = "../outside/secret.txt"
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("leak").path(percentEncoded: false),
            withDestinationPath: literalDestination
        )

        let fssync = try BuildFSSync(contextDir)
        let infos = try await walkJSON(fssync)

        let leak = infos.first { $0.name == "leak" }
        #expect(leak != nil, "the escaping symlink should still appear in walk() results")
        #expect(
            leak?.target == literalDestination,
            "target should be the literal (relative) symlink destination, never a resolved absolute host path: \(leak?.target ?? "nil")"
        )
        #expect(leak?.target.hasPrefix("/") == false, "target must not be an absolute host path for an out-of-context symlink")
    }

    @Test func testWalkJSONReportsLiteralTargetForDirectorySymlinkOutsideContext() async throws {
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try write("supersecret", to: secretFile)

        let literalDestination = outsideDir.path(percentEncoded: false)
        try fm.createSymbolicLink(
            atPath: contextDir.appendingPathComponent("subdir").path(percentEncoded: false),
            withDestinationPath: literalDestination
        )

        let fssync = try BuildFSSync(contextDir)
        let infos = try await walkJSON(fssync, followPaths: ["subdir"])

        let leak = infos.first { $0.name == "subdir" }
        #expect(leak != nil, "the escaping directory symlink should still appear in walk() results")
        #expect(
            leak?.target == literalDestination,
            "target should be the literal symlink destination, not the resolved external directory path: \(leak?.target ?? "nil")")

        // Nothing from inside the external directory should have leaked in as
        // its own entry — the fixed Globber must not have descended into it.
        let secretLeak = infos.first { $0.name.hasSuffix("secret.txt") }
        #expect(secretLeak == nil, "no entry for the external file should appear in walk() results: \(infos.map { $0.name })")
    }

    @Test func readRejectsSymlinkEscapeFromNamedContext() async throws {
        let shared = base.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let secret = outsideDir.appendingPathComponent("secret.txt")
        try write("secret", to: secret)
        try fm.createSymbolicLink(
            atPath: shared.appendingPathComponent("leak").path,
            withDestinationPath: secret.path
        )

        let fssync = try BuildFSSync(contextDir, namedContexts: ["shared": shared.path])
        var transfer = readPacket(source: "leak")
        transfer.metadata = ["dir-name": "shared"]
        var continuation: AsyncStream<ClientStream>.Continuation!
        _ = AsyncStream<ClientStream> { continuation = $0 }
        defer { continuation.finish() }

        do {
            try await fssync.read(continuation, transfer, "build-0")
            Issue.record("read should reject a named-context symlink that resolves outside that context")
        } catch is BuildFSSync.Error {
            // Expected.
        }
    }

    // MARK: - Fork support regressions

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
    func walkDoesNotPublishContextRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
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
            "mode": "json",
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

        let response = try #require(responses.first)
        let entries = try JSONDecoder().decode([BuildFSSync.FileInfo].self, from: response.buildTransfer.data)
        #expect(entries.map(\.name) == ["emptyFile"])
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

private enum BuildArchiveTestError: Error {
    case timedOut
}

private enum BuildArchiveSemaphore {
    static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

private actor BuildArchiveCountdown {
    private var remaining: Int

    init(count: Int) {
        self.remaining = count
    }

    func arrive() {
        remaining -= 1
    }

    func wait(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while remaining > 0 {
            guard clock.now < deadline else {
                throw BuildArchiveTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor BuildArchiveIsolationProbe {
    func archive(started: DispatchSemaphore, release: DispatchSemaphore) async throws -> SHA256.Digest {
        try await ConcurrentBuildContextArchive.run {
            started.signal()
            release.wait()
            return SHA256.hash(data: Data())
        }
    }

    func ping(_ countdown: BuildArchiveCountdown) async {
        await countdown.arrive()
    }
}
