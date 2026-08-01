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

import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

struct ContainerClientLoggingRequestTests {
    @Test
    func clientEncodingPreservesTheExactLoggingRequest() throws {
        let request = ContainerLogRequest(
            driver: "acme.example/remote",
            options: [
                "endpoint": "https://logs.example/path?token=a=b",
                "mode": "non-blocking",
                "template": "",
            ]
        )

        let data = try #require(try ContainerClient.encodedLoggingRequest(request))

        #expect(try JSONDecoder().decode(ContainerLogRequest.self, from: data) == request)
    }

    @Test
    func clientEncodingKeepsTransportOmissionDistinctFromADefaultRequest() throws {
        let omitted = try ContainerClient.encodedLoggingRequest(nil)
        let present = try #require(try ContainerClient.encodedLoggingRequest(ContainerLogRequest()))

        #expect(omitted == nil)
        #expect(try JSONDecoder().decode(ContainerLogRequest.self, from: present) == ContainerLogRequest())
    }

    @Test
    func oversizedClientRequestFailsWithoutEchoingProtectedMaterial() throws {
        let marker = "DO_NOT_ECHO_THIS_LOGGING_SECRET"
        let request = ContainerLogRequest(
            driver: "splunk",
            options: [
                "splunk-token": marker
                    + String(
                        repeating: "x",
                        count: ContainerLogRequest.maximumEncodedTransportBytes
                    )
            ]
        )

        let error = #expect(throws: ContainerizationError.self) {
            _ = try ContainerClient.encodedLoggingRequest(request)
        }

        #expect(error?.message == "logging request exceeds the encoded byte limit")
        #expect(!String(describing: error).contains(marker))
    }
}
