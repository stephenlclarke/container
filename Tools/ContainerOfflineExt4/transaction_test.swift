// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.
// Focused component entry point compiled with the maintained service transaction.
import ContainerizationEXT4
import CryptoKit
import Darwin
import Foundation
import Logging
import SystemPackage

@main
struct TransactionTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try condition() else { throw NSError(domain: "OfflineCopyTest", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }

    static func digest(_ path: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: path, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        let originalHash = try digest(fixture)
        let root = fixture.deletingLastPathComponent().appendingPathComponent("transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("rootfs.ext4")
        try expect(clonefile(fixture.path, image.path, UInt32(CLONE_NOFOLLOW)) == 0, "fixture clone failed")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
        let source = root.appendingPathComponent("host-file")
        let payload = Data((0..<10000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let log = Logger(label: "offline-copy-transaction-test")
        try expect(OfflineStoppedCopyIn.prepareHelper(helper: helper, log: log), "authenticated startup probe failed")
        try expect(digest(image) == originalHash, "startup probe changed private rootfs")
        try expect(Data(contentsOf: source) == payload, "startup probe changed source")

        func copy(
            _ destination: String, from input: URL? = nil, mode: UInt32 = 0o600,
            parents: Bool = true, preserve: Bool = false, tool: URL? = nil
        ) throws -> Bool {
            try OfflineStoppedCopyIn.copy(
                rootfs: image, source: (input ?? source).path,
                destination: destination,
                options: .init(mode: mode, createParents: parents, followSymlink: false, preserveOwnership: preserve),
                helper: tool ?? helper, log: log)
        }

        try expect(copy("/written", preserve: true), "new-file transaction rejected")
        var reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path), requireCleanJournal: true)
        try expect(reader.readFile(at: FilePath("/written")) == payload, "committed bytes differ")
        try expect(reader.stat(FilePath("/written")).inode.mode & 0o777 == 0o600, "explicit mode must remain independent of ownership preservation")
        try expect(copy("/a/b/target", mode: 0), "parent-creation transaction rejected")
        reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path), requireCleanJournal: true)
        try expect(reader.stat(FilePath("/a/b/target")).inode.mode & 0o777 == 0, "explicit zero mode differs")
        try expect(copy("/"), "directory destination transaction rejected")
        reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path), requireCleanJournal: true)
        try expect(reader.readFile(at: FilePath("/host-file")) == payload, "directory copy bytes differ")
        try Data("short".utf8).write(to: source)
        try expect(copy("/written"), "overwrite transaction rejected")
        reader = try EXT4.EXT4Reader(blockDevice: FilePath(image.path), requireCleanJournal: true)
        try expect(reader.readFile(at: FilePath("/written")) == Data("short".utf8), "overwrite retained tail")

        let before = try digest(image)
        try expect(!copy("/missing/target", parents: false), "missing parent must select guest")
        try expect(!copy("/../target"), "dot-dot must select guest")
        try expect(!copy("/new", from: root), "directory source must select guest")
        try expect(!copy("/new", from: image), "image/source alias must select guest")
        try expect(!copy("/new", tool: root.appendingPathComponent("missing-helper")), "missing helper must select guest")
        let link = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try expect(!copy("/new", from: link), "unfollowed source link must select guest")
        try expect(digest(image) == before, "fallback changed original rootfs")
        try expect(FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".container-copyin-") }, "staging leaked")
        try expect(digest(fixture) == originalHash, "immutable fixture changed")
        print("{\"passed\":true,\"transactions\":4,\"nonCommitChecks\":6,\"stagingClean\":true}")
    }
}
