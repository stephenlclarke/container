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

import Foundation
import Testing

@testable import ContainerResource

struct ContainerLogHistoryHandoffTests {
    @Test func exportReceiptMatchesTheLinuxServiceCanonicalVector() throws {
        let request = try LogDriverHistoryHandoffExportRequestV1(
            tokenID: "token",
            manifestID: "manifest",
            containerID: "container-id",
            sourceStateRootUUID: "source-root",
            destinationStateRootUUID: "destination-root",
            sourceLeaseGeneration: 2,
            sourceProviderID: "io.container.logging.plugin.test",
            sourceProviderGeneration: 7,
            sourceContractDigest:
                "sha256:" + String(repeating: "c", count: 64),
            terminalHistoryDigestSHA256:
                "sha256:" + String(repeating: "a", count: 64)
        )
        let receipt = try LogDriverHistoryHandoffExportReceiptV1(
            request: request,
            providerOutcomeDigestSHA256:
                "sha256:" + String(repeating: "1", count: 64)
        )
        #expect(
            receipt.exportReceiptDigestSHA256
                == "030a20fb337c31466c2c025cd94d4469c3967ffe40932b4a6ed0f672a13fef71"
        )
        #expect(
            try JSONDecoder().decode(
                LogDriverHistoryHandoffExportReceiptV1.self,
                from: JSONEncoder().encode(receipt)
            ) == receipt
        )
    }
}
