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

import ContainerPersistence
import ContainerResource
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ContainerAPIService

struct LoggingProtectedOptionsStoreTests {
    @Test func storesArbitraryUTF8ValuesWithPrivateOwnedFilesAndHMACReference() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 7)
            let secret = "raw-secret-value"
            let options = [
                "": "",
                "a=b": "value=with=equals",
                "dotted.name": "line one\nline two",
                "nul\u{0}name": "nul\u{0}value",
                "unicode-雪": secret,
            ]

            let reference = try await store.store(options)
            #expect(reference.objectID.utf8.count == 32)
            #expect(reference.objectID.utf8.allSatisfy(Self.isLowercaseHex))
            #expect(reference.integrityDigest.hasPrefix("hmac-sha256:"))
            #expect(!reference.integrityDigest.contains(secret))
            #expect(!reference.objectID.contains(secret))
            #expect(try await store.load(reference) == options)

            let rootMetadata = try Self.metadata(root)
            let keyMetadata = try Self.metadata(
                root.appendingPathComponent(LoggingProtectedOptionsStore.keyFileName)
            )
            let objectURL = Self.objectURL(root: root, objectID: reference.objectID)
            let objectMetadata = try Self.metadata(objectURL)
            #expect(Self.permissions(rootMetadata) == 0o700)
            #expect(Self.permissions(keyMetadata) == 0o600)
            #expect(Self.permissions(objectMetadata) == 0o600)
            #expect(rootMetadata.st_uid == geteuid())
            #expect(keyMetadata.st_uid == geteuid())
            #expect(objectMetadata.st_uid == geteuid())

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!names.contains { $0.contains(".tmp.") })
            let payload = try Data(contentsOf: objectURL)
            let plainDigest = Self.hex(SHA256.hash(data: payload))
            #expect(reference.integrityDigest != "hmac-sha256:\(plainDigest)")
        }
    }

    @Test func canonicalEncodingIsIndependentOfDictionaryInsertionOrder() async throws {
        try await Self.withTemporaryParent { parent in
            let firstRoot = parent.appendingPathComponent("first", isDirectory: true)
            let secondRoot = parent.appendingPathComponent("second", isDirectory: true)
            let firstStore = try Self.makeStore(root: firstRoot, seed: 19)
            let secondStore = try Self.makeStore(root: secondRoot, seed: 19)
            var first: [String: String] = [:]
            first["z"] = "last"
            first[""] = "empty-name"
            first["a"] = "first"
            var second: [String: String] = [:]
            second["a"] = "first"
            second[""] = "empty-name"
            second["z"] = "last"

            let firstReference = try await firstStore.store(first)
            let secondReference = try await secondStore.store(second)
            #expect(firstReference == secondReference)
            #expect(
                try Data(contentsOf: Self.objectURL(root: firstRoot, objectID: firstReference.objectID))
                    == Data(contentsOf: Self.objectURL(root: secondRoot, objectID: secondReference.objectID))
            )
        }
    }

    @Test func persistedKeyAllowsAReopenedStoreToVerifyExistingObjects() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let firstStore = try Self.makeStore(root: root, seed: 3)
            let reference = try await firstStore.store(["token": "protected"])
            let reopened = try Self.makeStore(root: root, seed: 222)

            #expect(try await reopened.load(reference) == ["token": "protected"])
        }
    }

    @Test func rejectsTamperingInvalidSchemaWrongEmbeddedIDDuplicateNamesAndNoncanonicalOrder() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 31)
            let reference = try await store.store(["name": "value"])
            let objectURL = Self.objectURL(root: root, objectID: reference.objectID)
            let key = try Data(
                contentsOf: root.appendingPathComponent(LoggingProtectedOptionsStore.keyFileName)
            )
            let original = try Data(contentsOf: objectURL)

            var tampered = original
            tampered[tampered.index(before: tampered.endIndex)] ^= 0xff
            try Self.replaceContents(of: objectURL, with: tampered)
            await #expect(throws: LoggingProtectedOptionsStoreError.integrityMismatch) {
                try await store.load(reference)
            }

            var invalidSchema = original
            invalidSchema[11] = 2
            try Self.replaceContents(of: objectURL, with: invalidSchema)
            let invalidSchemaReference = Self.reference(
                objectID: reference.objectID,
                payload: invalidSchema,
                key: key
            )
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidEncoding) {
                try await store.load(invalidSchemaReference)
            }

            var wrongIdentity = original
            wrongIdentity[12] = wrongIdentity[12] == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a")
            try Self.replaceContents(of: objectURL, with: wrongIdentity)
            let wrongIdentityReference = Self.reference(
                objectID: reference.objectID,
                payload: wrongIdentity,
                key: key
            )
            await #expect(throws: LoggingProtectedOptionsStoreError.objectIdentityMismatch) {
                try await store.load(wrongIdentityReference)
            }

            var duplicate = original
            duplicate.replaceSubrange(44..<48, with: [0, 0, 0, 2])
            duplicate.append(original[48...])
            try Self.replaceContents(of: objectURL, with: duplicate)
            let duplicateReference = Self.reference(
                objectID: reference.objectID,
                payload: duplicate,
                key: key
            )
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidEncoding) {
                try await store.load(duplicateReference)
            }

            let orderedReference = try await store.store(["a": "first", "z": "last"])
            let orderedURL = Self.objectURL(root: root, objectID: orderedReference.objectID)
            let noncanonical = try Self.reversingFirstTwoEntries(in: Data(contentsOf: orderedURL))
            try Self.replaceContents(of: orderedURL, with: noncanonical)
            let noncanonicalReference = Self.reference(
                objectID: orderedReference.objectID,
                payload: noncanonical,
                key: key
            )
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidEncoding) {
                try await store.load(noncanonicalReference)
            }
        }
    }

    @Test func rejectsTraversalSymlinksAndPermissionChangesWithoutDeletingTargets() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 41)
            let plausibleDigest = "hmac-sha256:" + String(repeating: "0", count: 64)
            let traversal = LoggingProtectedOptionsReference(
                objectID: "../outside",
                integrityDigest: plausibleDigest
            )
            let traversalError = await #expect(throws: LoggingProtectedOptionsStoreError.self) {
                try await store.load(traversal)
            }
            #expect(traversalError == .invalidReference)
            #expect(!String(describing: traversalError).contains("../outside"))

            let reference = try await store.store(["token": "protected"])
            let objectURL = Self.objectURL(root: root, objectID: reference.objectID)
            let outside = parent.appendingPathComponent("outside")
            try Data("outside-value".utf8).write(to: outside)
            try FileManager.default.removeItem(at: objectURL)
            try FileManager.default.createSymbolicLink(at: objectURL, withDestinationURL: outside)

            await #expect(throws: LoggingProtectedOptionsStoreError.self) {
                try await store.load(reference)
            }
            await #expect(throws: LoggingProtectedOptionsStoreError.self) {
                try await store.delete(reference)
            }
            #expect(try Data(contentsOf: outside) == Data("outside-value".utf8))
            #expect(try Self.metadata(objectURL).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 43)
            let reference = try await store.store(["token": "protected"])
            let objectURL = Self.objectURL(root: root, objectID: reference.objectID)
            #expect(Darwin.chmod(objectURL.path, mode_t(0o644)) == 0)
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidMetadata(.object)) {
                try await store.load(reference)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 47)
            let reference = try await store.store(["token": "protected"])
            let keyURL = root.appendingPathComponent(LoggingProtectedOptionsStore.keyFileName)
            #expect(Darwin.chmod(keyURL.path, mode_t(0o644)) == 0)
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidMetadata(.key)) {
                try await store.load(reference)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 53)
            let reference = try await store.store(["token": "protected"])
            #expect(Darwin.chmod(root.path, mode_t(0o755)) == 0)
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidMetadata(.root)) {
                try await store.load(reference)
            }
        }
    }

    @Test func rejectsRootAndKeySymlinksAtInitialization() async throws {
        try await Self.withTemporaryParent { parent in
            let realRoot = parent.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
            #expect(Darwin.chmod(realRoot.path, mode_t(0o700)) == 0)
            let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
            #expect(throws: LoggingProtectedOptionsStoreError.self) {
                try Self.makeStore(root: linkedRoot, seed: 59)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(Darwin.chmod(root.path, mode_t(0o700)) == 0)
            let outsideKey = parent.appendingPathComponent("outside-key")
            try Data(repeating: 1, count: 32).write(to: outsideKey)
            #expect(Darwin.chmod(outsideKey.path, mode_t(0o600)) == 0)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(LoggingProtectedOptionsStore.keyFileName),
                withDestinationURL: outsideKey
            )
            #expect(throws: LoggingProtectedOptionsStoreError.self) {
                try Self.makeStore(root: root, seed: 61)
            }
        }
    }

    @Test func rejectsKeyReplacementAndOversizedObjects() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 67)
            let reference = try await store.store(["token": "protected"])
            let keyURL = root.appendingPathComponent(LoggingProtectedOptionsStore.keyFileName)
            var key = try Data(contentsOf: keyURL)
            key[0] ^= 0xff
            try Self.replaceContents(of: keyURL, with: key)
            await #expect(throws: LoggingProtectedOptionsStoreError.invalidMetadata(.key)) {
                try await store.load(reference)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 71)
            let reference = try await store.store(["token": "protected"])
            let objectURL = Self.objectURL(root: root, objectID: reference.objectID)
            let handle = try FileHandle(forWritingTo: objectURL)
            try handle.truncate(atOffset: UInt64(LoggingProtectedOptionsStore.maximumEncodedBytes + 1))
            try handle.synchronize()
            try handle.close()
            await #expect(throws: LoggingProtectedOptionsStoreError.boundsExceeded) {
                try await store.load(reference)
            }
        }
    }

    @Test func enforcesEncodingBoundsWithoutPuttingRawValuesInErrors() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 73)
            let marker = "DO_NOT_EXPOSE_THIS_VALUE"
            let oversizedValue =
                marker
                + String(
                    repeating: "x",
                    count: LoggingProtectedOptionsStore.maximumOptionValueBytes
                )
            let error = await #expect(throws: LoggingProtectedOptionsStoreError.boundsExceeded) {
                try await store.store(["token": oversizedValue])
            }
            #expect(!String(describing: error).contains(marker))

            let oversizedName = String(
                repeating: "n",
                count: LoggingProtectedOptionsStore.maximumOptionNameBytes + 1
            )
            await #expect(throws: LoggingProtectedOptionsStoreError.boundsExceeded) {
                try await store.store([oversizedName: "value"])
            }

            var tooMany: [String: String] = [:]
            for index in 0...LoggingProtectedOptionsStore.maximumOptionCount {
                tooMany[String(index)] = "value"
            }
            await #expect(throws: LoggingProtectedOptionsStoreError.boundsExceeded) {
                try await store.store(tooMany)
            }
        }
    }

    @Test func exactObjectDeletionIsIdempotent() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 79)
            let first = try await store.store(["first": "protected"])
            let second = try await store.store(["second": "protected"])
            let firstURL = Self.objectURL(root: root, objectID: first.objectID)
            let secondURL = Self.objectURL(root: root, objectID: second.objectID)

            try await store.delete(first)
            #expect(!FileManager.default.fileExists(atPath: firstURL.path))
            #expect(FileManager.default.fileExists(atPath: secondURL.path))
            try await store.delete(first)
            await #expect(throws: LoggingProtectedOptionsStoreError.notFound) {
                try await store.load(first)
            }
            #expect(try await store.load(second) == ["second": "protected"])
        }
    }

    @Test func authorityBindingRejectsCrossContainerReferenceSubstitutionWithoutLeakingValues() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 83)
            let protectedValue = "DO_NOT_EXPOSE_THIS_VALUE"
            let prepared = try ContainerLogRequestResolver(
                defaults: LoggingConfig(),
                catalog: BuiltinLogDriverDescriptors.current
            ).prepare(
                ContainerLogRequest(
                    driver: "none",
                    options: ["opaque": protectedValue]
                )
            )
            let firstBinding = LoggingProtectedOptionsBinding(
                containerID: "first",
                prepared: prepared,
                leaseGeneration: 1
            )
            let secondBinding = LoggingProtectedOptionsBinding(
                containerID: "second",
                prepared: prepared,
                leaseGeneration: 1
            )
            let reference = try await store.store(
                ["opaque": protectedValue],
                boundTo: firstBinding
            )
            let configuration = try prepared.finalizedConfiguration(
                protectedReference: reference
            )
            let reconstructedBinding = try LoggingProtectedOptionsBinding(
                containerID: "first",
                configuration: configuration
            )

            #expect(reconstructedBinding == firstBinding)
            #expect(
                try await store.load(reference, boundTo: reconstructedBinding)
                    == ["opaque": protectedValue]
            )
            let loadError = await #expect(throws: LoggingProtectedOptionsStoreError.integrityMismatch) {
                try await store.load(reference, boundTo: secondBinding)
            }
            #expect(!String(describing: loadError).contains(protectedValue))

            await #expect(throws: LoggingProtectedOptionsStoreError.integrityMismatch) {
                try await store.delete(reference, boundTo: secondBinding)
            }
            #expect(FileManager.default.fileExists(atPath: Self.objectURL(root: root, objectID: reference.objectID).path))
        }
    }

    @Test func reconciliationRetainsDurableReferencesAndRemovesOrphansAndCrashTemps() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 89)
            let retained = try await store.store(["retained": "value"])
            let orphan = try await store.store(["orphan": "value"])
            let crashTemp = root.appendingPathComponent(".logging-options.tmp.crash-remnant")
            try Data("temporary".utf8).write(to: crashTemp)

            try await store.reconcile(retainingObjectIDs: [retained.objectID])

            #expect(FileManager.default.fileExists(atPath: Self.objectURL(root: root, objectID: retained.objectID).path))
            #expect(!FileManager.default.fileExists(atPath: Self.objectURL(root: root, objectID: orphan.objectID).path))
            #expect(!FileManager.default.fileExists(atPath: crashTemp.path))
            #expect(try await store.load(retained) == ["retained": "value"])
        }
    }

    private static func makeStore(root: URL, seed: UInt8) throws -> LoggingProtectedOptionsStore {
        let random = DeterministicRandom(seed: seed)
        return try LoggingProtectedOptionsStore(
            rootURL: root,
            _testingRandomBytes: { count in random.bytes(count: count) }
        )
    }

    private static func objectURL(root: URL, objectID: String) -> URL {
        root.appendingPathComponent(
            LoggingProtectedOptionsStore.objectFilePrefix + objectID
                + LoggingProtectedOptionsStore.objectFileSuffix
        )
    }

    private static func reference(objectID: String, payload: Data, key: Data) -> LoggingProtectedOptionsReference {
        let domain = Data("container.logging.protected-options.v1\u{0}".utf8)
        let context = Data("unbound-test-context-v1".utf8)
        var authenticated = Data()
        authenticated.append(domain)
        authenticated.append(Data(objectID.utf8))
        var contextLength = UInt32(context.count).bigEndian
        Swift.withUnsafeBytes(of: &contextLength) {
            authenticated.append(contentsOf: $0)
        }
        authenticated.append(context)
        authenticated.append(payload)
        let code = HMAC<SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: key)
        )
        return LoggingProtectedOptionsReference(
            objectID: objectID,
            integrityDigest: "hmac-sha256:\(hex(code))"
        )
    }

    private static func replaceContents(of url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private static func reversingFirstTwoEntries(in payload: Data) throws -> Data {
        let headerEnd = 48
        guard payload.count >= headerEnd + 8, payload[44..<48] == Data([0, 0, 0, 2]) else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        let firstEnd = try entryEnd(in: payload, startingAt: headerEnd)
        let secondEnd = try entryEnd(in: payload, startingAt: firstEnd)
        guard secondEnd == payload.endIndex else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }

        var reversed = Data(payload[..<headerEnd])
        reversed.append(payload[firstEnd..<secondEnd])
        reversed.append(payload[headerEnd..<firstEnd])
        return reversed
    }

    private static func entryEnd(in payload: Data, startingAt start: Int) throws -> Int {
        guard start >= 0, start <= payload.count - 8 else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        let nameCount = Self.uint32(in: payload, at: start)
        let valueCount = Self.uint32(in: payload, at: start + 4)
        let end = start.addingReportingOverflow(8 + nameCount + valueCount)
        guard !end.overflow, end.partialValue <= payload.count else {
            throw LoggingProtectedOptionsStoreError.invalidEncoding
        }
        return end.partialValue
    }

    private static func uint32(in data: Data, at offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
    }

    private static func metadata(_ url: URL) throws -> stat {
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else {
            throw LoggingProtectedOptionsStoreError.ioFailure(.read, errno)
        }
        return metadata
    }

    private static func permissions(_ metadata: stat) -> mode_t {
        metadata.st_mode & mode_t(0o7777)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func withTemporaryParent(
        _ body: (URL) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("logging-protected-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(parent)
    }
}

private final class DeterministicRandom: @unchecked Sendable {
    private let lock = NSLock()
    private let seed: UInt8
    private var invocation: UInt8 = 0

    init(seed: UInt8) {
        self.seed = seed
    }

    func bytes(count: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        invocation &+= 1
        return Data(
            (0..<count).map { index in
                seed &+ invocation &+ UInt8(truncatingIfNeeded: index)
            })
    }
}
