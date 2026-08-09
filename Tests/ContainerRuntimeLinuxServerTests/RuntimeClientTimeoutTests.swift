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

import Testing

@testable import ContainerRuntimeClient

struct RuntimeClientTimeoutTests {
    @Test(arguments: [
        (nil, Duration.seconds(10)),
        (Int32(-1), Duration.seconds(10)),
        (Int32(0), Duration.seconds(10)),
        (Int32(5), Duration.seconds(10)),
        (Int32(30), Duration.seconds(35)),
    ])
    func stopResponseTimeoutIncludesBoundedTeardownGrace(
        timeoutInSeconds: Int32?,
        expected: Duration
    ) {
        #expect(
            RuntimeClient.stopResponseTimeout(
                timeoutInSeconds: timeoutInSeconds
            ) == expected
        )
    }

    @Test func shutdownResponseTimeoutIsBounded() {
        #expect(RuntimeClient.shutdownResponseTimeout == .seconds(5))
    }
}
