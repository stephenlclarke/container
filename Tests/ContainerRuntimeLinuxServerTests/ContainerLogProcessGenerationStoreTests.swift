//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

struct ContainerLogProcessGenerationStoreTests {
    @Test
    func persistsStrictlyIncreasingGenerationsAcrossReopen() throws {
        try withFixture { directory in
            var store: ContainerLogProcessGenerationStore? = try ContainerLogProcessGenerationStore(
                directoryURL: directory
            )
            #expect(try store?.next() == 1)
            #expect(try store?.next() == 2)
            store = nil

            let reopened = try ContainerLogProcessGenerationStore(directoryURL: directory)
            #expect(try reopened.next() == 3)
        }
    }

    @Test
    func serializesIndependentConcurrentAllocators() async throws {
        try await withFixture { directory in
            let results = try await withThrowingTaskGroup(
                of: UInt64.self,
                returning: [UInt64].self
            ) { group in
                for _ in 0..<64 {
                    group.addTask {
                        let store = try ContainerLogProcessGenerationStore(directoryURL: directory)
                        return try store.next()
                    }
                }
                var allocated: [UInt64] = []
                for try await value in group {
                    allocated.append(value)
                }
                return allocated
            }
            #expect(results.sorted() == Array(1...64).map(UInt64.init))
        }
    }

    @Test
    func rejectsCorruptOrExhaustedDurableState() throws {
        try withFixture { directory in
            let store = try ContainerLogProcessGenerationStore(directoryURL: directory)
            #expect(try store.next() == 1)
            let state = directory.appendingPathComponent("process-generation-v1.bin")

            try Data("corrupt".utf8).write(to: state)
            #expect(throws: ContainerLogProcessGenerationError.invalidEncoding) {
                try store.next()
            }

            try ContainerLogProcessGenerationStore.encode(UInt64.max).write(to: state)
            #expect(throws: ContainerLogProcessGenerationError.exhausted) {
                try store.next()
            }
        }
    }

    @Test
    func removesInterruptedTemporaryFilesBeforeAllocation() throws {
        try withFixture { directory in
            let store = try ContainerLogProcessGenerationStore(directoryURL: directory)
            let temporary = directory.appendingPathComponent(
                ".process-generation-v1.tmp.interrupted"
            )
            try Data("partial".utf8).write(to: temporary)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporary.path
            )

            #expect(try store.next() == 1)
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
        }
    }

    @Test
    func refusesSymlinkAndWorldReadableStorage() throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "container-log-generation-security-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: target.path
        )
        let symlink = parent.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try ContainerLogProcessGenerationStore(directoryURL: symlink)
        }

        let unsafe = parent.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: unsafe.path
        )
        #expect(throws: ContainerLogProcessGenerationError.unsafeStorage) {
            try ContainerLogProcessGenerationStore(directoryURL: unsafe)
        }
    }

    private func withFixture<Result>(
        _ body: (URL) throws -> Result
    ) throws -> Result {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "container-log-generation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let directory = parent.appendingPathComponent("logging-v2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        return try body(directory)
    }

    private func withFixture<Result: Sendable>(
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "container-log-generation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: parent.path
        )
        let directory = parent.appendingPathComponent("logging-v2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        return try await body(directory)
    }
}
