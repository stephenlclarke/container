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
import Foundation

enum LoggingHandoffPromotionControlCodecError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidReceipt
}

enum LoggingHandoffPromotionControlCodec {
    static let mediaType =
        "application/vnd.io.github.stephenlclarke.container.handoff-logging-promotion-receipt.v1+json"

    static func encode(
        _ value: LoggingHandoffControllerPromotionReceiptV1
    ) throws -> Data {
        try validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode(
        _ data: Data
    ) throws -> LoggingHandoffControllerPromotionReceiptV1 {
        let value: LoggingHandoffControllerPromotionReceiptV1
        do {
            value = try JSONDecoder().decode(
                LoggingHandoffControllerPromotionReceiptV1.self,
                from: data
            )
        } catch {
            throw LoggingHandoffPromotionControlCodecError.invalidEncoding
        }
        guard try encode(value) == data else {
            throw LoggingHandoffPromotionControlCodecError.invalidEncoding
        }
        return value
    }

    private static func validate(
        _ value: LoggingHandoffControllerPromotionReceiptV1
    ) throws {
        guard
            value.schemaVersion == 1,
            !value.handoffTokenID.isEmpty,
            !value.handoffManifestID.isEmpty,
            !value.destinationProviderFingerprint.isEmpty,
            value.controllerRevision > 0
        else {
            throw LoggingHandoffPromotionControlCodecError.invalidReceipt
        }
        for digest in [
            value.handoffManifestDigest,
            value.protectedStagingReceiptDigestSHA256,
            value.commitDigestSHA256,
            value.handoffChainHeadDigestSHA256,
            value.privateStateDigestSHA256,
            value.historySetDigestSHA256,
            value.controllerStateDigestSHA256,
            value.promotionReceiptDigestSHA256,
        ] {
            _ = try ProviderHandoffDigest.parseSHA256(digest)
        }
    }
}
