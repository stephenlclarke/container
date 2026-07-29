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
import Testing

@testable import ContainerAPIService

struct ContainerNetworkNameValidationTests {
    @Test func allowsNamesToBeReusedOnDifferentNetworks() {
        let existing = [[attachment(network: "frontend", hostname: "api", aliases: ["web"])]]
        let requested = [attachment(network: "backend", hostname: "api", aliases: ["web"])]

        #expect(
            ContainersService.conflictingNetworkNames(
                existingAttachments: existing,
                requestedAttachments: requested
            ).isEmpty
        )
    }

    @Test func allowsAliasesToSharePrimaryAndAliasNamesOnTheSameNetwork() {
        let existing = [[attachment(network: "frontend", hostname: "api", aliases: ["web"])]]
        let requested = [attachment(network: "frontend", hostname: "worker", aliases: ["api", "web"])]

        #expect(
            ContainersService.conflictingNetworkNames(
                existingAttachments: existing,
                requestedAttachments: requested
            ).isEmpty
        )
    }

    @Test func rejectsDuplicatePrimaryHostnamesOnTheSameNetwork() {
        let existing = [[attachment(network: "frontend", hostname: "api", aliases: ["web"])]]
        let requested = [attachment(network: "frontend", hostname: "API.")]

        #expect(
            ContainersService.conflictingNetworkNames(
                existingAttachments: existing,
                requestedAttachments: requested
            ) == ["api"]
        )
    }

    @Test func rejectsDuplicatePrimaryHostnamesInOneRequestedNetworkOnly() {
        let requested = [
            attachment(network: "frontend", hostname: "api"),
            attachment(network: "backend", hostname: "API"),
            attachment(network: "frontend", hostname: "Api."),
        ]

        #expect(
            ContainersService.conflictingNetworkNames(
                existingAttachments: [],
                requestedAttachments: requested
            ) == ["api"]
        )
    }

    private func attachment(network: String, hostname: String, aliases: [String] = []) -> AttachmentConfiguration {
        AttachmentConfiguration(network: network, options: AttachmentOptions(hostname: hostname, aliases: aliases))
    }
}
