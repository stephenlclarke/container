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

import ContainerEngineRuntimeSPI
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIService

struct LoggingHandoffStagingReceiptTests {
    @Test
    func `receipt is canonical and binds the common staging record`() throws {
        let receipt = try makeReceipt()
        let encoded = try LoggingProtectedOptionStagingReceiptV1.canonicalBytes(
            receipt
        )
        #expect(
            try LoggingProtectedOptionStagingReceiptV1.decodeCanonicalBytes(encoded)
                == receipt
        )

        var common = commonRecord()
        try receipt.validate(commonRecord: common)
        common.stagedImportReceiptDigestSHA256 = receipt.receiptDigestSHA256
        try receipt.validate(commonRecord: common)
        common.bundleObjectID = "sha256:\(digest("different bundle"))"
        #expect(throws: LoggingHandoffStagingReceiptError.commonRecordMismatch) {
            try receipt.validate(commonRecord: common)
        }
    }

    @Test
    func `protected receipt store is idempotent authenticated and private`() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logging-handoff-receipt-tests-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let receipt = try makeReceipt()
        let store = try LoggingHandoffProtectedReceiptStore(
            rootURL: temporaryRoot,
            _testingRandomBytes: { count in Data(repeating: 0x5a, count: count) }
        )

        #expect(try await store.seal(receipt) == receipt)
        #expect(try await store.seal(receipt) == receipt)
        #expect(try await store.load(receipt.receiptDigestSHA256) == receipt)
        #expect(try permissions(temporaryRoot) == 0o700)

        let receiptURL = temporaryRoot.appendingPathComponent(
            LoggingHandoffProtectedReceiptStore.receiptFilePrefix
                + receipt.receiptDigestSHA256
                + LoggingHandoffProtectedReceiptStore.receiptFileSuffix
        )
        #expect(try permissions(receiptURL) == 0o600)
        let handle = try FileHandle(forUpdating: receiptURL)
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end - 1)
        let original = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: end - 1)
        try handle.write(contentsOf: Data([original ^ 0x01]))
        try handle.synchronize()
        try handle.close()

        await #expect(
            throws: LoggingHandoffProtectedReceiptStoreError.integrityMismatch
        ) {
            _ = try await store.load(receipt.receiptDigestSHA256)
        }

        let restore = try FileHandle(forUpdating: receiptURL)
        try restore.seek(toOffset: end - 1)
        try restore.write(contentsOf: Data([original]))
        try restore.synchronize()
        try restore.close()
        #expect(try await store.load(receipt.receiptDigestSHA256) == receipt)

        try await store.delete(receipt.receiptDigestSHA256)
        try await store.delete(receipt.receiptDigestSHA256)
        await #expect(throws: LoggingHandoffProtectedReceiptStoreError.notFound) {
            _ = try await store.load(receipt.receiptDigestSHA256)
        }
    }

    private func makeReceipt() throws -> LoggingProtectedOptionStagingReceiptV1 {
        try LoggingProtectedOptionStagingReceiptV1(
            handoffTokenID: "token-1",
            handoffManifestID: "manifest-1",
            handoffManifestDigest: digest("manifest"),
            bundleObjectID: "sha256:\(digest("bundle"))",
            payloadDescriptorDigestSHA256: digest("descriptor"),
            verifiedCanonicalContentDigest: digest("content"),
            importedEntries: [
                ImportedProtectedLoggingOptionV1(
                    entryID: "logging:01:10:option:01",
                    destinationReference: LoggingProtectedOptionsReference(
                        objectID: "destination-object-1",
                        integrityDigest: "hmac-sha256:destination-integrity-1"
                    ),
                    destinationProtectedContentDigest: digest("entry-1")
                ),
                ImportedProtectedLoggingOptionV1(
                    entryID: "logging:02:10:option:01",
                    destinationReference: LoggingProtectedOptionsReference(
                        objectID: "destination-object-2",
                        integrityDigest: "hmac-sha256:destination-integrity-2"
                    ),
                    destinationProtectedContentDigest: digest("entry-2")
                ),
            ]
        )
    }

    private func commonRecord() -> ProviderHandoffPartStagingRecordV1 {
        ProviderHandoffPartStagingRecordV1(
            tokenID: "token-1",
            manifestID: "manifest-1",
            manifestDigest: digest("manifest"),
            partKind: .logging,
            bundleObjectID: "sha256:\(digest("bundle"))",
            payloadDescriptorDigestSHA256: digest("descriptor"),
            stagingRevision: 4,
            state: .contentVerified,
            verifiedCanonicalContentDigest: digest("content")
        )
    }

    private func digest(_ value: String) -> String {
        ProviderHandoffDigest.sha256(Data(value.utf8))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }
}
