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
import ContainerizationError
import Testing

@testable import ContainerAPIService

struct ContainerLoggingCreateValidationTests {
    @Test func legacyLoggingRemainsAcceptedAtCreateBoundary() throws {
        try ContainersService.validateLoggingConfigurationForCreate(.default)
        try ContainersService.validateLoggingConfigurationForCreate(
            ContainerLogConfiguration(storage: .none)
        )
    }

    @Test func v2LoggingIsRejectedAtCreateBoundaryBeforeRuntimeWork() throws {
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: "json-file",
            delivery: try LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: BuiltinLogDriverDescriptors.coreProvider,
            providerGenerationAtResolution: 1,
            contractDigest: "sha256:contract"
        )
        let logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: "json-file"),
            resolved: resolved
        )

        let error = #expect(throws: ContainerizationError.self) {
            try ContainersService.validateLoggingConfigurationForCreate(logging)
        }
        #expect(error?.code == .unsupported)
        #expect(error?.message == "logging schema version 2 is not yet supported for container creation")
    }
}
