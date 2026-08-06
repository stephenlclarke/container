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

import Testing

@testable import ContainerAPIService

struct ContainerLoggingStartErrorTests {
    @Test func mapsDeferredLocalCompressionFailureToDockerDiagnostic() {
        let reason = "compression cannot be enabled when max file count is 1"
        let mapped = ContainersService.mapLoggingStartError(
            ContainerLogResolutionError.invalidOption(
                driver: "local",
                name: "compress",
                reason: reason
            )
        )

        #expect(mapped.code == .invalidState)
        #expect(mapped.message == "failed to initialize logging driver: \(reason)")
    }

    @Test func preservesTheGenericStartValidationDiagnosticForOtherOptions() {
        let mapped = ContainersService.mapLoggingStartError(
            ContainerLogResolutionError.invalidOption(
                driver: "json-file",
                name: "compress",
                reason: "compress cannot be true when max-file is less than 2 or max-size is not set"
            )
        )

        #expect(
            mapped.message
                == "container logging configuration is not valid for start: invalid log option \"compress\" for driver \"json-file\": compress cannot be true when max-file is less than 2 or max-size is not set"
        )
    }
}
