//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct ContainerCreationReservationsTests {
    @Test("A unique container can reserve its identity")
    func reserveUniqueContainer() throws {
        var reservations = ContainerCreationReservations()

        try reservations.reserve(
            Self.snapshot(id: "first", hostname: "first"),
            existing: [],
            reservedNames: []
        )

        #expect(reservations.snapshots.map(\.id) == ["first"])
    }

    @Test("Pending creations reserve identifiers and Docker names")
    func rejectPendingIdentityConflicts() throws {
        var reservations = ContainerCreationReservations()
        try reservations.reserve(
            Self.snapshot(id: "first", hostname: "first", dockerName: "friendly"),
            existing: [],
            reservedNames: []
        )

        let idError = #expect(throws: ContainerizationError.self) {
            try reservations.reserve(
                Self.snapshot(id: "first", hostname: "second"),
                existing: [],
                reservedNames: []
            )
        }
        #expect(idError?.code == .exists)

        let nameError = #expect(throws: ContainerizationError.self) {
            try reservations.reserve(
                Self.snapshot(id: "second", hostname: "second", dockerName: "friendly"),
                existing: [],
                reservedNames: []
            )
        }
        #expect(nameError?.code == .exists)
        #expect(nameError?.message == "container name already exists: friendly")
    }

    @Test("Pending creations reserve hostnames on the same network")
    func rejectPendingHostnameConflict() throws {
        var reservations = ContainerCreationReservations()
        try reservations.reserve(
            Self.snapshot(id: "first", hostname: "shared"),
            existing: [],
            reservedNames: []
        )

        let error = #expect(throws: ContainerizationError.self) {
            try reservations.reserve(
                Self.snapshot(id: "second", hostname: "SHARED."),
                existing: [],
                reservedNames: []
            )
        }
        #expect(error?.code == .exists)
        #expect(error?.message == "hostname(s) already exist: [\"shared\"]")
    }

    @Test("Rolling back a creation releases its reservations")
    func rollbackReleasesReservations() throws {
        var reservations = ContainerCreationReservations()
        let snapshot = Self.snapshot(id: "retry", hostname: "retry")
        try reservations.reserve(snapshot, existing: [], reservedNames: [])

        #expect(reservations.remove("retry")?.id == "retry")
        try reservations.reserve(snapshot, existing: [], reservedNames: [])

        #expect(reservations.snapshots.map(\.id) == ["retry"])
    }

    @Test("Failed validation rolls back the service reservation")
    func failedValidationRollsBackServiceReservation() async throws {
        let appRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-creation-reservations-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: appRoot)
        }
        let pluginLoader = try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        let service = try ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "com.apple.container.test.creation-reservations")
        )
        let configuration = Self.snapshot(id: "retry", hostname: "retry").configuration
        let kernel = Kernel(
            path: appRoot.appendingPathComponent("kernel"),
            platform: .linuxArm
        )

        for _ in 0..<2 {
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(
                    configuration: configuration,
                    kernel: kernel,
                    options: .default
                )
            }
            #expect(error?.code == .notFound)
            #expect(error?.message == "unable to locate runtime plugin container-runtime-linux")
        }
    }

    private static func snapshot(
        id: String,
        hostname: String,
        dockerName: String? = nil
    ) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.dockerName = dockerName
        configuration.networks = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: hostname)
            )
        ]
        return ContainerSnapshot(
            configuration: configuration,
            status: .stopped,
            networks: [],
            startedDate: nil
        )
    }
}
