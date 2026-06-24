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

import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerResource

struct ImageResourceTests {
    @Test func roundTripsVariantHealthCheckMetadata() throws {
        let image = ImageResource(
            configuration: .init(
                description: ImageDescription(
                    reference: "example/api:latest",
                    descriptor: .init(
                        mediaType: MediaTypes.index,
                        digest: "sha256:" + String(repeating: "0", count: 64),
                        size: 0
                    )
                ),
                creationDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            variants: [
                .init(
                    platform: .init(arch: "arm64", os: "linux", variant: "v8"),
                    digest: "sha256:" + String(repeating: "1", count: 64),
                    size: 123,
                    config: .init(
                        architecture: "arm64",
                        os: "linux",
                        rootfs: .init(type: "layers", diffIDs: [])
                    ),
                    healthCheck: .init(
                        test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
                        intervalInNanoseconds: 5_000_000_000,
                        timeoutInNanoseconds: 1_000_000_000,
                        startPeriodInNanoseconds: 10_000_000_000,
                        startIntervalInNanoseconds: 500_000_000,
                        retries: 5
                    )
                )
            ]
        )

        let data = try JSONEncoder().encode(image)
        let decoded = try JSONDecoder().decode(ImageResource.self, from: data)
        let healthCheck = try #require(decoded.variants.first?.healthCheck)

        #expect(healthCheck.test == ["CMD-SHELL", "curl -f http://localhost/health || exit 1"])
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.timeoutInNanoseconds == 1_000_000_000)
        #expect(healthCheck.startPeriodInNanoseconds == 10_000_000_000)
        #expect(healthCheck.startIntervalInNanoseconds == 500_000_000)
        #expect(healthCheck.retries == 5)
    }
}
