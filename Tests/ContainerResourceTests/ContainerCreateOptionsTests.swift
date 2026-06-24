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

struct ContainerCreateOptionsTests {
    @Test func roundTripsRestartPolicy() throws {
        let options = ContainerCreateOptions(
            autoRemove: false,
            restartPolicy: ContainerRestartPolicy(
                mode: .onFailure,
                maximumRetryCount: 3,
                retryDelayInNanoseconds: 5_000_000_000,
                successfulRunDurationInNanoseconds: 30_000_000_000
            )
        )

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: data)

        #expect(decoded.autoRemove == false)
        #expect(decoded.restartPolicy.mode == .onFailure)
        #expect(decoded.restartPolicy.maximumRetryCount == 3)
        #expect(decoded.restartPolicy.retryDelayInNanoseconds == 5_000_000_000)
        #expect(decoded.restartPolicy.successfulRunDurationInNanoseconds == 30_000_000_000)
    }

    @Test func decodesMissingRestartPolicyAsNo() throws {
        let data = Data(#"{"autoRemove":false}"#.utf8)

        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: data)

        #expect(decoded.restartPolicy == .no)
    }

    @Test func normalizesRestartPolicyInvariants() throws {
        let noPolicy = ContainerRestartPolicy(
            mode: .no,
            maximumRetryCount: 3,
            retryDelayInNanoseconds: 5_000_000_000,
            successfulRunDurationInNanoseconds: 30_000_000_000
        )
        let alwaysPolicy = ContainerRestartPolicy(mode: .always, maximumRetryCount: 3)
        let onFailureUnlimited = ContainerRestartPolicy(mode: .onFailure, maximumRetryCount: 0)

        #expect(noPolicy.maximumRetryCount == nil)
        #expect(noPolicy.retryDelayInNanoseconds == nil)
        #expect(noPolicy.successfulRunDurationInNanoseconds == nil)
        #expect(alwaysPolicy.maximumRetryCount == nil)
        #expect(onFailureUnlimited.maximumRetryCount == nil)
    }

    @Test func decodesRestartPolicyThroughInvariantInitializer() throws {
        let noPolicy = Data(
            """
            {
              "mode": "no",
              "maximumRetryCount": 3,
              "retryDelayInNanoseconds": 5000000000,
              "successfulRunDurationInNanoseconds": 30000000000
            }
            """.utf8
        )
        let alwaysPolicy = Data(
            """
            {
              "mode": "always",
              "maximumRetryCount": 3,
              "retryDelayInNanoseconds": 5000000000,
              "successfulRunDurationInNanoseconds": 30000000000
            }
            """.utf8
        )
        let onFailureUnlimited = Data(#"{"mode":"on-failure","maximumRetryCount":0}"#.utf8)

        let decodedNoPolicy = try JSONDecoder().decode(ContainerRestartPolicy.self, from: noPolicy)
        let decodedAlwaysPolicy = try JSONDecoder().decode(ContainerRestartPolicy.self, from: alwaysPolicy)
        let decodedOnFailureUnlimited = try JSONDecoder().decode(ContainerRestartPolicy.self, from: onFailureUnlimited)

        #expect(decodedNoPolicy.maximumRetryCount == nil)
        #expect(decodedNoPolicy.retryDelayInNanoseconds == nil)
        #expect(decodedNoPolicy.successfulRunDurationInNanoseconds == nil)
        #expect(decodedAlwaysPolicy.maximumRetryCount == nil)
        #expect(decodedAlwaysPolicy.retryDelayInNanoseconds == 5_000_000_000)
        #expect(decodedAlwaysPolicy.successfulRunDurationInNanoseconds == 30_000_000_000)
        #expect(decodedOnFailureUnlimited.maximumRetryCount == nil)
    }
}
