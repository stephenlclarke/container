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

import ContainerResource
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ContainerAPIService

struct ProtectedLoggingEffectStoreTests {
    @Test func sealIsImmutableIdempotentAndStableAcrossReopen() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let material = try LogDriverOpaqueEffectTokenV1(
                validating: Data("effect-secret".utf8) + Data([0x00, 0xff])
            )
            let binding = try Self.binding()
            let store = try Self.makeStore(root: root, seed: 7)

            let first = try await store.seal(material, binding: binding)
            let objectURL = Self.objectURL(root: root, reference: first)
            let originalObject = try Data(contentsOf: objectURL)
            let second = try await store.seal(material, binding: binding)
            let reopened = try Self.makeStore(root: root, seed: 91)
            let afterReopen = try await reopened.seal(material, binding: binding)

            #expect(first == second)
            #expect(first == afterReopen)
            #expect(
                try await reopened.resolve(afterReopen, binding: binding)
                    .isByteIdentical(to: material)
            )
            #expect(try Data(contentsOf: objectURL) == originalObject)
            #expect(first.protectedStoreObjectID.utf8.count == 64)
            #expect(first.protectedStoreObjectID.utf8.allSatisfy(Self.isLowercaseHex))
            #expect(first.integrityDigest.hasPrefix("hmac-sha256:"))

            let rootMetadata = try Self.metadata(root)
            let keyMetadata = try Self.metadata(
                root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName)
            )
            let objectMetadata = try Self.metadata(objectURL)
            #expect(Self.permissions(rootMetadata) == 0o700)
            #expect(Self.permissions(keyMetadata) == 0o600)
            #expect(Self.permissions(objectMetadata) == 0o600)
            #expect(rootMetadata.st_uid == geteuid())
            #expect(keyMetadata.st_uid == geteuid())
            #expect(objectMetadata.st_uid == geteuid())

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(names.filter { $0.hasSuffix(ProtectedLoggingEffectStore.objectFileSuffix) }.count == 1)
            #expect(!names.contains { $0.hasPrefix(ProtectedLoggingEffectStore.temporaryFilePrefix) })
            #expect(!names.contains { $0.hasPrefix(ProtectedLoggingEffectStore.temporaryKeyPrefix) })
        }
    }

    @Test func publishedObjectSurvivesLostSealResponseAndReopensAsSameReference() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let crash = OneShotEffectStoreFailure(point: .afterObjectPublication)
            let store = try Self.makeStore(root: root, seed: 13, failure: crash)
            let material = try Self.material("response-loss-secret")
            let binding = try Self.binding(effectID: "response-loss-effect")

            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.seal(material, binding: binding)
            }
            let namesAfterLoss = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(namesAfterLoss.filter { $0.hasSuffix(ProtectedLoggingEffectStore.objectFileSuffix) }.count == 1)

            let reopened = try Self.makeStore(root: root, seed: 127)
            let recovered = try await reopened.seal(material, binding: binding)
            let replayed = try await reopened.seal(material, binding: binding)
            #expect(recovered == replayed)
            #expect(
                try await reopened.resolve(recovered, binding: binding)
                    .isByteIdentical(to: material)
            )
        }
    }

    @Test func sameBindingDifferentMaterialConflictsAndDerivedIDCollisionNeverOverwrites() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 17)
            let binding = try Self.binding(effectID: "stable-effect")
            let original = try Self.material("original-secret")
            let reference = try await store.seal(original, binding: binding)
            let objectURL = Self.objectURL(root: root, reference: reference)
            let originalBytes = try Data(contentsOf: objectURL)

            await #expect(throws: ProtectedLoggingEffectStoreError.materialConflict) {
                try await store.seal(
                    Self.material("different-secret"),
                    binding: binding
                )
            }
            #expect(try Data(contentsOf: objectURL) == originalBytes)
            #expect(
                try await store.resolve(reference, binding: binding)
                    .isByteIdentical(to: original)
            )
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let collisionID = String(repeating: "a", count: 64)
            let store = try Self.makeStore(
                root: root,
                seed: 19,
                objectID: { _ in collisionID }
            )
            let firstBinding = try Self.binding(effectID: "first-effect")
            let secondBinding = try Self.binding(effectID: "second-effect")
            let firstMaterial = try Self.material("first-secret")
            let first = try await store.seal(firstMaterial, binding: firstBinding)

            await #expect(throws: ProtectedLoggingEffectStoreError.identifierCollision) {
                try await store.seal(
                    Self.material("second-secret"),
                    binding: secondBinding
                )
            }
            #expect(
                try await store.resolve(first, binding: firstBinding)
                    .isByteIdentical(to: firstMaterial)
            )
        }
    }

    @Test func resolveAndRemoveAuthenticateEveryBindingAndReferenceField() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 23)
            let material = try Self.material("binding-secret-marker")
            let binding = try Self.binding()
            let reference = try await store.seal(material, binding: binding)
            let alternatives = [
                try Self.binding(effectID: "other-effect"),
                try Self.binding(controllerID: "other-controller"),
                try Self.binding(providerID: "other-provider"),
                try Self.binding(providerGeneration: 8),
            ]

            for alternative in alternatives {
                let forged = try Self.reference(
                    binding: alternative,
                    objectID: reference.protectedStoreObjectID,
                    digest: reference.integrityDigest
                )
                await #expect(throws: ProtectedLoggingEffectStoreError.invalidReference) {
                    try await store.resolve(forged, binding: alternative)
                }
                await #expect(throws: ProtectedLoggingEffectStoreError.invalidReference) {
                    try await store.remove(forged, binding: alternative)
                }
                await #expect(throws: LogDriverLifecycleContractError.effectReferenceBindingMismatch) {
                    try await store.resolve(reference, binding: alternative)
                }
            }

            let substitutedObject = try Self.reference(
                binding: binding,
                objectID: String(repeating: "b", count: 64),
                digest: reference.integrityDigest
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidReference) {
                try await store.resolve(substitutedObject, binding: binding)
            }
            let substitutedDigest = try Self.reference(
                binding: binding,
                objectID: reference.protectedStoreObjectID,
                digest: "hmac-sha256:" + String(repeating: "0", count: 64)
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await store.resolve(substitutedDigest, binding: binding)
            }
            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await store.remove(substitutedDigest, binding: binding)
            }
            #expect(
                try await store.resolve(reference, binding: binding)
                    .isByteIdentical(to: material)
            )
        }
    }

    @Test func objectTamperingTruncationAndOversizeFailBeforeReturnOrDelete() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 29)
            let material = try Self.material("tamper-secret")
            let binding = try Self.binding(effectID: "tamper-effect")
            let reference = try await store.seal(material, binding: binding)
            let objectURL = Self.objectURL(root: root, reference: reference)
            var tampered = try Data(contentsOf: objectURL)
            tampered[tampered.index(before: tampered.endIndex)] ^= 0xff
            try Self.replaceContents(of: objectURL, with: tampered)

            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await store.resolve(reference, binding: binding)
            }
            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await store.remove(reference, binding: binding)
            }
            #expect(FileManager.default.fileExists(atPath: objectURL.path))
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 31)
            let binding = try Self.binding(effectID: "truncated-effect")
            let reference = try await store.seal(
                Self.material("truncated-secret"),
                binding: binding
            )
            try Self.replaceContents(
                of: Self.objectURL(root: root, reference: reference),
                with: Data([0])
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.boundsExceeded) {
                try await store.resolve(reference, binding: binding)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 37)
            let binding = try Self.binding(effectID: "oversized-effect")
            let reference = try await store.seal(
                Self.material("oversized-secret"),
                binding: binding
            )
            let handle = try FileHandle(
                forWritingTo: Self.objectURL(root: root, reference: reference)
            )
            try handle.truncate(
                atOffset: UInt64(ProtectedLoggingEffectStore.maximumEncodedObjectBytes + 1)
            )
            try handle.synchronize()
            try handle.close()
            await #expect(throws: ProtectedLoggingEffectStoreError.boundsExceeded) {
                try await store.resolve(reference, binding: binding)
            }
        }
    }

    @Test func rejectsTraversalSymlinksPermissionChangesAndKeyReplacement() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 41)
            let binding = try Self.binding(effectID: "traversal-effect")
            let reference = try await store.seal(
                Self.material("symlink-secret"),
                binding: binding
            )
            let traversal = try Self.reference(
                binding: binding,
                objectID: "../outside",
                digest: reference.integrityDigest
            )
            let traversalError = await #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try await store.resolve(traversal, binding: binding)
            }
            #expect(traversalError == .invalidReference)
            #expect(!String(describing: traversalError).contains("../outside"))

            let objectURL = Self.objectURL(root: root, reference: reference)
            let outside = parent.appendingPathComponent("outside")
            try Data("outside-value".utf8).write(to: outside)
            try FileManager.default.removeItem(at: objectURL)
            try FileManager.default.createSymbolicLink(
                at: objectURL,
                withDestinationURL: outside
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try await store.resolve(reference, binding: binding)
            }
            await #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try await store.remove(reference, binding: binding)
            }
            #expect(try Data(contentsOf: outside) == Data("outside-value".utf8))
            #expect(try Self.metadata(objectURL).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 43)
            let binding = try Self.binding(effectID: "permissions-effect")
            let reference = try await store.seal(
                Self.material("permission-secret"),
                binding: binding
            )
            let objectURL = Self.objectURL(root: root, reference: reference)
            #expect(Darwin.chmod(objectURL.path, mode_t(0o644)) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.object)) {
                try await store.resolve(reference, binding: binding)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 47)
            let binding = try Self.binding(effectID: "key-effect")
            let reference = try await store.seal(
                Self.material("key-secret"),
                binding: binding
            )
            let keyURL = root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName)
            try FileManager.default.removeItem(at: keyURL)
            try Data(repeating: 0xa5, count: 32).write(to: keyURL)
            #expect(Darwin.chmod(keyURL.path, mode_t(0o600)) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.key)) {
                try await store.resolve(reference, binding: binding)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 53)
            let binding = try Self.binding(effectID: "root-mode-effect")
            let reference = try await store.seal(
                Self.material("root-mode-secret"),
                binding: binding
            )
            #expect(Darwin.chmod(root.path, mode_t(0o755)) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.root)) {
                try await store.resolve(reference, binding: binding)
            }
        }
    }

    @Test func rejectsRootAndKeySymlinksAndMissingKeyWithManagedState() async throws {
        try await Self.withTemporaryParent { parent in
            let realRoot = parent.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(
                at: realRoot,
                withIntermediateDirectories: false
            )
            #expect(Darwin.chmod(realRoot.path, mode_t(0o700)) == 0)
            let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedRoot,
                withDestinationURL: realRoot
            )
            #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try Self.makeStore(root: linkedRoot, seed: 59)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            #expect(Darwin.chmod(root.path, mode_t(0o700)) == 0)
            let outsideKey = parent.appendingPathComponent("outside-key")
            try Data(repeating: 1, count: 32).write(to: outsideKey)
            #expect(Darwin.chmod(outsideKey.path, mode_t(0o600)) == 0)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName),
                withDestinationURL: outsideKey
            )
            #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try Self.makeStore(root: root, seed: 61)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 67)
            _ = try await store.seal(
                Self.material("missing-key-secret"),
                binding: try Self.binding(effectID: "missing-key-effect")
            )
            try FileManager.default.removeItem(
                at: root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName)
            )
            #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.key)) {
                try Self.makeStore(root: root, seed: 69)
            }
        }
    }

    @Test func removeIsExactAuthenticatedAndIdempotentAcrossReopenWithoutTokenLedger() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 71)
            let marker = "DO_NOT_PERSIST_IN_TOMBSTONE"
            let material = try Self.material(marker)
            let binding = try Self.binding(effectID: "removed-effect")
            let retainedBinding = try Self.binding(effectID: "retained-effect")
            let reference = try await store.seal(material, binding: binding)
            let retained = try await store.seal(
                Self.material("retained-secret"),
                binding: retainedBinding
            )

            try await store.remove(reference, binding: binding)
            #expect(!FileManager.default.fileExists(atPath: Self.objectURL(root: root, reference: reference).path))
            #expect(FileManager.default.fileExists(atPath: Self.objectURL(root: root, reference: retained).path))
            let tombstoneURL = Self.tombstoneURL(root: root, reference: reference)
            let tombstoneData = try Data(contentsOf: tombstoneURL)
            #expect(tombstoneData.range(of: Data(marker.utf8)) == nil)
            #expect(Self.permissions(try Self.metadata(tombstoneURL)) == 0o600)

            try await store.remove(reference, binding: binding)
            let reopened = try Self.makeStore(root: root, seed: 73)
            try await reopened.remove(reference, binding: binding)
            await #expect(throws: ProtectedLoggingEffectStoreError.removed) {
                try await reopened.resolve(reference, binding: binding)
            }
            let wrongDigest = try Self.reference(
                binding: binding,
                objectID: reference.protectedStoreObjectID,
                digest: "hmac-sha256:" + String(repeating: "f", count: 64)
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await reopened.remove(wrongDigest, binding: binding)
            }
            #expect(
                try await reopened.resolve(retained, binding: retainedBinding)
                    .isByteIdentical(to: Self.material("retained-secret"))
            )
        }
    }

    @Test func startupReconcilesCrashTempsAndAuthenticatedPendingDeletion() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let crash = OneShotEffectStoreFailure(point: .afterTombstonePublication)
            let store = try Self.makeStore(root: root, seed: 79, failure: crash)
            let marker = "pending-delete-secret"
            let material = try Self.material(marker)
            let binding = try Self.binding(effectID: "pending-delete-effect")
            let reference = try await store.seal(material, binding: binding)
            let objectURL = Self.objectURL(root: root, reference: reference)

            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.remove(reference, binding: binding)
            }
            #expect(FileManager.default.fileExists(atPath: objectURL.path))
            #expect(FileManager.default.fileExists(atPath: Self.tombstoneURL(root: root, reference: reference).path))

            let objectTemp = root.appendingPathComponent(
                ProtectedLoggingEffectStore.temporaryFilePrefix + "crash-remnant"
            )
            let keyTemp = root.appendingPathComponent(
                ProtectedLoggingEffectStore.temporaryKeyPrefix + "crash-remnant"
            )
            let outside = parent.appendingPathComponent("outside-temp-target")
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: objectTemp,
                withDestinationURL: outside
            )
            try Data("key-temp".utf8).write(to: keyTemp)

            let reopened = try Self.makeStore(root: root, seed: 83)
            #expect(!FileManager.default.fileExists(atPath: objectURL.path))
            #expect(!FileManager.default.fileExists(atPath: objectTemp.path))
            #expect(!FileManager.default.fileExists(atPath: keyTemp.path))
            #expect(try Data(contentsOf: outside) == Data("outside".utf8))
            try await reopened.remove(reference, binding: binding)
            await #expect(throws: ProtectedLoggingEffectStoreError.removed) {
                try await reopened.resolve(reference, binding: binding)
            }
            let tombstoneData = try Data(
                contentsOf: Self.tombstoneURL(root: root, reference: reference)
            )
            #expect(tombstoneData.range(of: Data(marker.utf8)) == nil)
        }
    }

    @Test func tamperedTombstoneBlocksReopenAndNeverDeletesAnUnauthenticatedObject() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let crash = OneShotEffectStoreFailure(point: .afterTombstonePublication)
            let store = try Self.makeStore(root: root, seed: 89, failure: crash)
            let binding = try Self.binding(effectID: "tampered-tombstone-effect")
            let reference = try await store.seal(
                Self.material("tombstone-secret"),
                binding: binding
            )
            let objectURL = Self.objectURL(root: root, reference: reference)
            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.remove(reference, binding: binding)
            }
            let tombstoneURL = Self.tombstoneURL(root: root, reference: reference)
            var tampered = try Data(contentsOf: tombstoneURL)
            tampered[tampered.index(before: tampered.endIndex)] ^= 0xff
            try Self.replaceContents(of: tombstoneURL, with: tampered)

            #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try Self.makeStore(root: root, seed: 97)
            }
            #expect(FileManager.default.fileExists(atPath: objectURL.path))
        }
    }

    @Test func maximumMaterialAndSecurityFailuresDoNotLeakRawTokenBytes() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 101)
            let maximum = Data(
                repeating: 0x5a,
                count: LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes
            )
            let material = try LogDriverOpaqueEffectTokenV1(validating: maximum)
            let binding = try Self.binding(effectID: "maximum-effect")
            let reference = try await store.seal(material, binding: binding)
            #expect(
                try await store.resolve(reference, binding: binding)
                    .isByteIdentical(to: material)
            )

            let marker = "DO_NOT_EXPOSE_RAW_EFFECT_TOKEN"
            let conflict = await #expect(throws: ProtectedLoggingEffectStoreError.materialConflict) {
                try await store.seal(Self.material(marker), binding: binding)
            }
            for description in [
                String(describing: conflict),
                String(describing: reference),
                reference.integrityDigest,
                reference.protectedStoreObjectID,
            ] {
                #expect(!description.contains(marker))
            }
            #expect(
                throws: LogDriverLifecycleContractError.effectTokenTooLarge(
                    maximumBytes: LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes
                )
            ) {
                try LogDriverOpaqueEffectTokenV1(
                    validating: Data(
                        repeating: 0,
                        count: LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes + 1
                    )
                )
            }
        }
    }

    @Test func canonicalBindingEncodingHasFixedIndependentKnownAnswers() throws {
        let ascii = try Self.binding(
            effectID: "a",
            controllerID: "b",
            providerID: "c",
            providerGeneration: 1
        )
        #expect(
            Self.hex(try ProtectedLoggingEffectStore.canonicalBindingData(ascii))
                == "434c424e44563100000000010000000161000000016200000001630000000000000001"
        )

        let exactUnicode = try Self.binding(
            effectID: "\u{0000}/",
            controllerID: "é",
            providerID: "e\u{0301}",
            providerGeneration: UInt64.max
        )
        #expect(
            Self.hex(try ProtectedLoggingEffectStore.canonicalBindingData(exactUnicode))
                == "434c424e445631000000000100000002002f00000002c3a90000000365cc81ffffffffffffffff"
        )
        let normalized = try Self.binding(
            effectID: "\u{0000}/",
            controllerID: "e\u{0301}",
            providerID: "é",
            providerGeneration: UInt64.max
        )
        #expect(
            try ProtectedLoggingEffectStore.canonicalBindingData(exactUnicode)
                != ProtectedLoggingEffectStore.canonicalBindingData(normalized)
        )
    }

    @Test func objectIdentityObjectMACAndTombstoneHaveIndependentKnownAnswers() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 131)
            let binding = try Self.binding()
            let reference = try await store.seal(
                Self.material("vector-secret"),
                binding: binding
            )
            #expect(
                reference.protectedStoreObjectID
                    == "bffdb0453b53069a4e81a0b097b3bf4e025ef7a0297d0009ef94c75886de6e8e"
            )
            #expect(
                reference.integrityDigest
                    == "hmac-sha256:9fdf3e6537d732d8cc316230320d434eebb68f9d1ec08bb34be8d13fe3d8fccd"
            )
            #expect(
                Self.hex(try Data(contentsOf: Self.objectURL(root: root, reference: reference)))
                    == "434c4f47454646310000000162666664623034353362353330363961346538316130623039376233626634653032356566376130323937643030303965663934633735383836646536653865000000410000000d434c424e4456310000000001000000096566666563742d69640000000d636f6e74726f6c6c65722d69640000000b70726f76696465722d69640000000000000007766563746f722d7365637265749fdf3e6537d732d8cc316230320d434eebb68f9d1ec08bb34be8d13fe3d8fccd"
            )

            try await store.remove(reference, binding: binding)
            #expect(
                Self.hex(try Data(contentsOf: Self.tombstoneURL(root: root, reference: reference)))
                    == "434c4f47524d5631000000016266666462303435336235333036396134653831613062303937623362663465303235656637613032393764303030396566393463373538383664653665386500000041434c424e4456310000000001000000096566666563742d69640000000d636f6e74726f6c6c65722d69640000000b70726f76696465722d696400000000000000079fdf3e6537d732d8cc316230320d434eebb68f9d1ec08bb34be8d13fe3d8fccde873fe5fa533fb85bfe3abc0330d6e56a491c20862a534c55b7df05158b95206"
            )
        }
    }

    @Test func everyAuthenticatedObjectAndTombstoneByteRejectsSingleBitMutation() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 137)
            let binding = try Self.binding(effectID: "all-regions-effect")
            let reference = try await store.seal(
                Self.material("all-regions-secret"),
                binding: binding
            )
            let objectURL = Self.objectURL(root: root, reference: reference)
            let object = try Data(contentsOf: objectURL)
            for index in object.indices {
                var mutated = object
                mutated[index] ^= 0x01
                try Self.replaceContents(of: objectURL, with: mutated)
                await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                    try await store.resolve(reference, binding: binding)
                }
            }
            try Self.replaceContents(of: objectURL, with: object)
            try await store.remove(reference, binding: binding)

            let tombstoneURL = Self.tombstoneURL(root: root, reference: reference)
            let tombstone = try Data(contentsOf: tombstoneURL)
            for index in tombstone.indices {
                var mutated = tombstone
                mutated[index] ^= 0x01
                try Self.replaceContents(of: tombstoneURL, with: mutated)
                await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                    try await store.resolve(reference, binding: binding)
                }
            }
            try Self.replaceContents(of: tombstoneURL, with: tombstone)
        }
    }

    @Test func validMACMalformedSchemaAndLengthsAreRejectedAfterAuthentication() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 139)
            let binding = try Self.binding(effectID: "valid-mac-malformed")
            let reference = try await store.seal(
                Self.material("valid-mac-secret"),
                binding: binding
            )
            let objectURL = Self.objectURL(root: root, reference: reference)
            let original = try Data(contentsOf: objectURL)
            let key = try Data(
                contentsOf: root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName)
            )

            var badSchema = original
            badSchema[11] = 2
            Self.replaceObjectMAC(in: &badSchema, key: key)
            try Self.replaceContents(of: objectURL, with: badSchema)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidEncoding) {
                try await store.resolve(reference, binding: binding)
            }

            var badBindingLength = original
            badBindingLength.replaceSubrange(76..<80, with: [0xff, 0xff, 0xff, 0xff])
            Self.replaceObjectMAC(in: &badBindingLength, key: key)
            try Self.replaceContents(of: objectURL, with: badBindingLength)
            await #expect(throws: ProtectedLoggingEffectStoreError.boundsExceeded) {
                try await store.resolve(reference, binding: binding)
            }
        }
    }

    @Test(arguments: ProtectedStoreACLComponent.allCases)
    func addedACLOnEveryManagedBoundaryIsRejected(
        component: ProtectedStoreACLComponent
    ) async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 149)
            let binding = try Self.binding(effectID: "acl-effect")
            let reference = try await store.seal(
                Self.material("acl-secret"),
                binding: binding
            )
            if component == .tombstone {
                try await store.remove(reference, binding: binding)
            }
            let target: URL
            switch component {
            case .root:
                target = root
            case .lock:
                target = root.appendingPathComponent(ProtectedLoggingEffectStore.lockFileName)
            case .key:
                target = root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName)
            case .object:
                target = Self.objectURL(root: root, reference: reference)
            case .tombstone:
                target = Self.tombstoneURL(root: root, reference: reference)
            }
            try Self.addACL(to: target)
            let expected = component.storeComponent
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(expected)) {
                try await store.resolve(reference, binding: binding)
            }
        }
    }

    @Test func inheritedACLsAreClearedFromEveryNewManagedNode() async throws {
        try await Self.withTemporaryParent { parent in
            try Self.addInheritableACL(to: parent)
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 151)
            let reference = try await store.seal(
                Self.material("inherited-acl-secret"),
                binding: Self.binding(effectID: "inherited-acl-effect")
            )
            for target in [
                root,
                root.appendingPathComponent(ProtectedLoggingEffectStore.lockFileName),
                root.appendingPathComponent(ProtectedLoggingEffectStore.keyFileName),
                Self.objectURL(root: root, reference: reference),
            ] {
                #expect(try Self.hasExtendedACL(target) == false)
            }
        }
    }

    @Test func hardLinksCrossStoreSubstitutionAndRootSwapAreRejected() async throws {
        try await Self.withTemporaryParent { parent in
            let firstRoot = parent.appendingPathComponent("first", isDirectory: true)
            let secondRoot = parent.appendingPathComponent("second", isDirectory: true)
            let first = try Self.makeStore(root: firstRoot, seed: 157)
            let second = try Self.makeStore(root: secondRoot, seed: 163)
            let binding = try Self.binding(effectID: "lineage-effect")
            let material = try Self.material("lineage-secret")
            let firstReference = try await first.seal(material, binding: binding)
            let secondReference = try await second.seal(material, binding: binding)
            #expect(firstReference != secondReference)

            let firstObject = Self.objectURL(root: firstRoot, reference: firstReference)
            let secondObject = Self.objectURL(root: secondRoot, reference: secondReference)
            try Self.replaceContents(
                of: secondObject,
                with: Data(contentsOf: firstObject)
            )
            await #expect(throws: ProtectedLoggingEffectStoreError.integrityMismatch) {
                try await second.resolve(secondReference, binding: binding)
            }

            let hardLink = parent.appendingPathComponent("object-hard-link")
            #expect(Darwin.link(firstObject.path, hardLink.path) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.object)) {
                try await first.resolve(firstReference, binding: binding)
            }
            try FileManager.default.removeItem(at: hardLink)
            try await first.remove(firstReference, binding: binding)
            let tombstone = Self.tombstoneURL(root: firstRoot, reference: firstReference)
            let tombstoneHardLink = parent.appendingPathComponent("tombstone-hard-link")
            #expect(Darwin.link(tombstone.path, tombstoneHardLink.path) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.tombstone)) {
                try await first.resolve(firstReference, binding: binding)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 167)
            let binding = try Self.binding(effectID: "root-swap-effect")
            let reference = try await store.seal(
                Self.material("root-swap-secret"),
                binding: binding
            )
            let retainedRoot = parent.appendingPathComponent("retained", isDirectory: true)
            try FileManager.default.moveItem(at: root, to: retainedRoot)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(Darwin.chmod(root.path, mode_t(0o700)) == 0)
            await #expect(throws: ProtectedLoggingEffectStoreError.invalidMetadata(.root)) {
                try await store.resolve(reference, binding: binding)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }

        try await Self.withTemporaryParent { parent in
            let realAncestor = parent.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realAncestor, withIntermediateDirectories: false)
            let linkedAncestor = parent.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedAncestor,
                withDestinationURL: realAncestor
            )
            #expect(throws: ProtectedLoggingEffectStoreError.self) {
                try Self.makeStore(
                    root: linkedAncestor.appendingPathComponent("store", isDirectory: true),
                    seed: 173
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: realAncestor.path).isEmpty)
        }
    }

    @Test func twoInstancesSerializeSealRemoveAndResolveRemoveRaces() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let first = try Self.makeStore(root: root, seed: 179)
            let second = try Self.makeStore(root: root, seed: 181)
            let binding = try Self.binding(effectID: "seal-race-effect")
            let successes = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        _ = try await first.seal(Self.material("first-race-secret"), binding: binding)
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    do {
                        _ = try await second.seal(Self.material("second-race-secret"), binding: binding)
                        return true
                    } catch {
                        return false
                    }
                }
                var count = 0
                for await succeeded in group where succeeded {
                    count += 1
                }
                return count
            }
            #expect(successes == 1)

            let removeBinding = try Self.binding(effectID: "remove-race-effect")
            let removeReference = try await first.seal(
                Self.material("remove-race-secret"),
                binding: removeBinding
            )
            async let firstRemove: Void = first.remove(removeReference, binding: removeBinding)
            async let secondRemove: Void = second.remove(removeReference, binding: removeBinding)
            _ = try await (firstRemove, secondRemove)

            let resolveBinding = try Self.binding(effectID: "resolve-race-effect")
            let resolveReference = try await first.seal(
                Self.material("resolve-race-secret"),
                binding: resolveBinding
            )
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        _ = try await first.resolve(resolveReference, binding: resolveBinding)
                    } catch {
                        #expect(error as? ProtectedLoggingEffectStoreError == .removed)
                    }
                }
                group.addTask {
                    do {
                        try await second.remove(resolveReference, binding: resolveBinding)
                    } catch {
                        Issue.record("serialized remove failed: \(error)")
                    }
                }
            }
            await #expect(throws: ProtectedLoggingEffectStoreError.removed) {
                try await first.resolve(resolveReference, binding: resolveBinding)
            }
        }
    }

    @Test func ledgerAuthorizedCompactionMissingKeyTempAndEnumerationBoundAreStrict() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let store = try Self.makeStore(root: root, seed: 191)
            let retainedBinding = try Self.binding(effectID: "retained-tombstone")
            let compactedBinding = try Self.binding(effectID: "compacted-tombstone")
            let retained = try await store.seal(Self.material("retained"), binding: retainedBinding)
            let compacted = try await store.seal(Self.material("compacted"), binding: compactedBinding)
            try await store.remove(retained, binding: retainedBinding)
            try await store.remove(compacted, binding: compactedBinding)
            try await store.reconcile(retainingEffectReferences: [retained])
            #expect(FileManager.default.fileExists(atPath: Self.tombstoneURL(root: root, reference: retained).path))
            #expect(!FileManager.default.fileExists(atPath: Self.tombstoneURL(root: root, reference: compacted).path))
            try await store.remove(retained, binding: retainedBinding)
            await #expect(throws: ProtectedLoggingEffectStoreError.notFound) {
                try await store.remove(compacted, binding: compactedBinding)
            }
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(Darwin.chmod(root.path, mode_t(0o700)) == 0)
            let temporary = root.appendingPathComponent(
                ProtectedLoggingEffectStore.temporaryKeyPrefix + "missing-key"
            )
            try Data("incomplete-key".utf8).write(to: temporary)
            let store = try Self.makeStore(root: root, seed: 193)
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            _ = try await store.seal(
                Self.material("post-temp-secret"),
                binding: Self.binding(effectID: "post-temp-effect")
            )
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(Darwin.chmod(root.path, mode_t(0o700)) == 0)
            for index in 0..<ProtectedLoggingEffectStore.maximumDirectoryEntries {
                let name = root.appendingPathComponent("entry-\(index)").path
                let descriptor = Darwin.open(name, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                #expect(descriptor >= 0)
                if descriptor >= 0 {
                    Darwin.close(descriptor)
                }
            }
            #expect(throws: ProtectedLoggingEffectStoreError.boundsExceeded) {
                try Self.makeStore(root: root, seed: 197)
            }
        }
    }

    @Test func publicationAndTemporaryCleanupFaultsRemainRecoverable() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let failure = OneShotEffectStoreFailure(point: .beforeDirectorySynchronization)
            let store = try Self.makeStore(root: root, seed: 199, failure: failure)
            let binding = try Self.binding(effectID: "directory-fsync-effect")
            let material = try Self.material("directory-fsync-secret")
            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.seal(material, binding: binding)
            }
            let reopened = try Self.makeStore(root: root, seed: 211)
            let recovered = try await reopened.seal(material, binding: binding)
            #expect(
                try await reopened.resolve(recovered, binding: binding)
                    .isByteIdentical(to: material)
            )
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let failure = OneShotEffectStoreFailure(point: .beforeTemporaryCleanupUnlink)
            let store = try Self.makeStore(root: root, seed: 223, failure: failure)
            let binding = try Self.binding(effectID: "cleanup-unlink-effect")
            let material = try Self.material("cleanup-unlink-secret")
            let original = try await store.seal(material, binding: binding)
            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.seal(material, binding: binding)
            }
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .contains(where: { $0.hasPrefix(ProtectedLoggingEffectStore.temporaryFilePrefix) })
            )
            let reopened = try Self.makeStore(root: root, seed: 227)
            #expect(try await reopened.seal(material, binding: binding) == original)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .contains(where: { $0.hasPrefix(ProtectedLoggingEffectStore.temporaryFilePrefix) }) == false
            )
        }

        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            let failure = OneShotEffectStoreFailure(point: .afterTombstonePublication)
            let store = try Self.makeStore(root: root, seed: 239, failure: failure)
            let binding = try Self.binding(effectID: "cleanup-fsync-effect")
            let material = try Self.material("cleanup-fsync-secret")
            let original = try await store.seal(material, binding: binding)
            failure.arm(.beforeDirectorySynchronization)
            await #expect(throws: EffectStoreTestError.simulatedCrash) {
                try await store.seal(material, binding: binding)
            }
            let reopened = try Self.makeStore(root: root, seed: 241)
            #expect(try await reopened.seal(material, binding: binding) == original)
        }
    }

    @Test func externalProcessLockSerializesWholeStoreInitialization() async throws {
        try await Self.withTemporaryParent { parent in
            let root = parent.appendingPathComponent("store", isDirectory: true)
            _ = try Self.makeStore(root: root, seed: 229)
            let sentinel = parent.appendingPathComponent("lock-held")
            let release = parent.appendingPathComponent("lock-release")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [
                "-c",
                "import fcntl,os,sys,time\nf=open(sys.argv[1],'r+b',buffering=0)\nfcntl.lockf(f,fcntl.LOCK_EX)\nopen(sys.argv[2],'wb').close()\nwhile not os.path.exists(sys.argv[3]): time.sleep(.01)",
                root.appendingPathComponent(ProtectedLoggingEffectStore.lockFileName).path,
                sentinel.path,
                release.path,
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                }
            }
            let releaser = Process()
            releaser.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            releaser.arguments = [
                "-c",
                "import os,sys,time\nwhile not os.path.exists(sys.argv[1]): time.sleep(.01)\ntime.sleep(.1)\nopen(sys.argv[2],'wb').close()",
                sentinel.path,
                release.path,
            ]
            try releaser.run()
            defer {
                if releaser.isRunning {
                    releaser.terminate()
                }
            }

            try Self.waitForFileSynchronously(sentinel)
            let duration = try ContinuousClock().measure {
                _ = try Self.makeStore(root: root, seed: 233)
            }
            #expect(duration >= .milliseconds(50))
            releaser.waitUntilExit()
            #expect(releaser.terminationStatus == 0)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    private static func makeStore(
        root: URL,
        seed: UInt8,
        objectID: ProtectedLoggingEffectStore.TestingObjectID? = nil,
        failure: OneShotEffectStoreFailure? = nil
    ) throws -> ProtectedLoggingEffectStore {
        let random = DeterministicEffectStoreRandom(seed: seed)
        return try ProtectedLoggingEffectStore(
            rootURL: root,
            _testingRandomBytes: { count in random.bytes(count: count) },
            _testingObjectID: objectID,
            _testingFailureInjector: { point in
                try failure?.inject(point)
            }
        )
    }

    private static func binding(
        effectID: String = "effect-id",
        controllerID: String = "controller-id",
        providerID: String = "provider-id",
        providerGeneration: UInt64 = 7
    ) throws -> ProtectedLoggingEffectBindingV1 {
        try ProtectedLoggingEffectBindingV1(
            effectID: effectID,
            owningControllerID: controllerID,
            providerID: providerID,
            providerGeneration: providerGeneration
        )
    }

    private static func reference(
        binding: ProtectedLoggingEffectBindingV1,
        objectID: String,
        digest: String
    ) throws -> ProtectedLoggingEffectReferenceV1 {
        try ProtectedLoggingEffectReferenceV1(
            binding: binding,
            protectedStoreObjectID: objectID,
            integrityDigest: digest
        )
    }

    private static func material(_ value: String) throws -> LogDriverOpaqueEffectTokenV1 {
        try LogDriverOpaqueEffectTokenV1(validating: Data(value.utf8))
    }

    private static func objectURL(
        root: URL,
        reference: ProtectedLoggingEffectReferenceV1
    ) -> URL {
        root.appendingPathComponent(
            ProtectedLoggingEffectStore.objectFilePrefix
                + reference.protectedStoreObjectID
                + ProtectedLoggingEffectStore.objectFileSuffix
        )
    }

    private static func tombstoneURL(
        root: URL,
        reference: ProtectedLoggingEffectReferenceV1
    ) -> URL {
        root.appendingPathComponent(
            ProtectedLoggingEffectStore.objectFilePrefix
                + reference.protectedStoreObjectID
                + ProtectedLoggingEffectStore.tombstoneFileSuffix
        )
    }

    private static func replaceContents(of url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private static func metadata(_ url: URL) throws -> stat {
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
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

    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(data.count * 2)
        for byte in data {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func replaceObjectMAC(in encoded: inout Data, key: Data) {
        let authenticationCodeCount = SHA256.byteCount
        let payload = Data(encoded.dropLast(authenticationCodeCount))
        var authenticated = Data("container.logging.effect.object.v1\u{0}".utf8)
        authenticated.append(payload)
        let code = Data(
            HMAC<SHA256>.authenticationCode(
                for: authenticated,
                using: SymmetricKey(data: key)
            )
        )
        encoded.replaceSubrange(
            (encoded.count - authenticationCodeCount)..<encoded.count,
            with: code
        )
    }

    private static func addACL(to url: URL) throws {
        try runChmod(["+a", "everyone allow read", url.path])
    }

    private static func addInheritableACL(to url: URL) throws {
        try runChmod([
            "+a",
            "everyone allow read,file_inherit,directory_inherit",
            url.path,
        ])
    }

    private static func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, EIO)
        }
    }

    private static func hasExtendedACL(_ url: URL) throws -> Bool {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.read, errno)
        }
        defer { Darwin.close(descriptor) }
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return false
            }
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = Darwin.acl_get_entry(
            acl,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        )
        guard result != -1 else {
            throw ProtectedLoggingEffectStoreError.ioFailure(.accessControl, errno)
        }
        return result == 0
    }

    private static func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw ProtectedLoggingEffectStoreError.ioFailure(.lock, ETIMEDOUT)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func waitForFileSynchronously(_ url: URL) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw ProtectedLoggingEffectStoreError.ioFailure(
                    .lock,
                    ETIMEDOUT
                )
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func waitForProcessExit(_ process: Process) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard clock.now < deadline else {
                process.terminate()
                throw ProtectedLoggingEffectStoreError.ioFailure(.lock, ETIMEDOUT)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func withTemporaryParent(
        _ body: (URL) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "protected-logging-effects-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(parent)
    }
}

enum ProtectedStoreACLComponent: String, CaseIterable, Sendable {
    case root
    case lock
    case key
    case object
    case tombstone

    var storeComponent: ProtectedLoggingEffectStoreError.Component {
        switch self {
        case .root: .root
        case .lock: .lock
        case .key: .key
        case .object: .object
        case .tombstone: .tombstone
        }
    }
}

private enum EffectStoreTestError: Error, Equatable {
    case simulatedCrash
}

private final class OneShotEffectStoreFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var point: ProtectedLoggingEffectStore.TestingFailurePoint
    private var fired = false

    init(point: ProtectedLoggingEffectStore.TestingFailurePoint) {
        self.point = point
    }

    func arm(_ point: ProtectedLoggingEffectStore.TestingFailurePoint) {
        lock.lock()
        defer { lock.unlock() }
        self.point = point
        fired = false
    }

    func inject(_ observed: ProtectedLoggingEffectStore.TestingFailurePoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard observed == point, !fired else {
            return
        }
        fired = true
        throw EffectStoreTestError.simulatedCrash
    }
}

private final class DeterministicEffectStoreRandom: @unchecked Sendable {
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
            }
        )
    }
}
