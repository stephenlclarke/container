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

import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerLoggingRequestTransportTests {
    @Test func typedRequestRoundTripsLosslessly() throws {
        let request = ContainerLogRequest(
            driver: "installed-driver",
            options: [
                "": "",
                "endpoint": "tcp://host:1234",
                "token": "raw-protected-value",
            ]
        )
        let message = XPCMessage(route: .containerCreate)
        message.set(
            key: .containerLogRequest,
            value: try JSONEncoder().encode(request)
        )

        #expect(try ContainersHarness.loggingRequest(from: message) == request)
    }

    @Test func omissionRemainsDistinctFromAnEmptyRequest() throws {
        let omitted = XPCMessage(route: .containerCreate)
        let present = XPCMessage(route: .containerCreate)
        present.set(
            key: .containerLogRequest,
            value: try JSONEncoder().encode(ContainerLogRequest())
        )

        #expect(try ContainersHarness.loggingRequest(from: omitted) == nil)
        #expect(try ContainersHarness.loggingRequest(from: present) == ContainerLogRequest())
    }

    @Test func oversizedAndInvalidPayloadsFailWithoutEchoingValues() throws {
        let oversized = XPCMessage(route: .containerCreate)
        oversized.set(
            key: .containerLogRequest,
            value: Data(
                repeating: UInt8(ascii: "x"),
                count: ContainerLogRequestResolver.maximumEncodedRequestBytes + 1
            )
        )
        #expect(throws: ContainerizationError.self) {
            try ContainersHarness.loggingRequest(from: oversized)
        }

        let marker = "DO_NOT_ECHO_THIS_RAW_VALUE"
        let invalid = XPCMessage(route: .containerCreate)
        invalid.set(
            key: .containerLogRequest,
            value: Data("{\"schemaVersion\":2,\"options\":{\"token\":\"\(marker)\"}}".utf8)
        )
        let error = #expect(throws: ContainerizationError.self) {
            try ContainersHarness.loggingRequest(from: invalid)
        }
        #expect(error?.message == "logging request is not a valid versioned request")
        #expect(!String(describing: error).contains(marker))
    }
}
