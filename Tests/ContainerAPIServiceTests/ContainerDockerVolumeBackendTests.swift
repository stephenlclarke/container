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

import ContainerEngineLogging
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerDockerVolumeBackendTests {
    @Test func usesTheNativeAuthorityForBuiltinDriverResolution() async throws {
        let fixture = VolumeCreateFixture()
        let backend = ContainerDockerVolumeBackend(createVolume: {
            try await fixture.create(
                name: $0,
                driver: $1,
                driverOptions: $2,
                labels: $3
            )
        })
        let result = try await backend.createVolume(
            request: DockerVolumeCreateRequest(
                name: "fixture-volume",
                driverOptions: ["size": "1m"],
                labels: ["fixture": "true"]
            )
        )

        #expect(
            await fixture.request
                == VolumeCreateFixture.Request(
                    name: "fixture-volume",
                    driver: "local",
                    driverOptions: ["size": "1m"],
                    labels: ["fixture": "true"]
                )
        )
        #expect(result.name == "fixture-volume")
        #expect(result.driver == "local")
        #expect(result.mountpoint == "/private/fixture-volume")
        #expect(result.labels == ["fixture": "true"])
        #expect(result.options == ["size": "1m"])
        #expect(!result.createdAt.isEmpty)
    }

    @Test func mapsUnavailableDriverBeforeTheNativeAuthorityCanAllocate() async throws {
        let fixture = VolumeCreateFixture()
        let backend = ContainerDockerVolumeBackend(createVolume: {
            try await fixture.create(
                name: $0,
                driver: $1,
                driverOptions: $2,
                labels: $3
            )
        })

        await #expect(
            throws: DockerLoggingBackendError.volumeDriverNotFound("missing-driver")
        ) {
            try await backend.createVolume(
                request: DockerVolumeCreateRequest(
                    name: "must-not-exist",
                    driver: "missing-driver"
                )
            )
        }
        #expect(await fixture.didAllocate == false)
    }
}

private actor VolumeCreateFixture {
    struct Request: Equatable, Sendable {
        let name: String
        let driver: String
        let driverOptions: [String: String]
        let labels: [String: String]
    }

    private(set) var request: Request?
    private(set) var didAllocate = false

    func create(
        name: String,
        driver: String,
        driverOptions: [String: String],
        labels: [String: String]
    ) throws -> VolumeConfiguration {
        request = Request(
            name: name,
            driver: driver,
            driverOptions: driverOptions,
            labels: labels
        )
        guard driver != "missing-driver" else {
            throw VolumeError.driverNotSupported(driver)
        }
        didAllocate = true
        return VolumeConfiguration(
            name: name,
            driver: driver,
            source: "/private/\(name)",
            creationDate: Date(timeIntervalSince1970: 0),
            labels: labels,
            options: driverOptions
        )
    }
}
