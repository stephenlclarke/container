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

import ContainerEngineGateway
import ContainerEngineLogging
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerUnixHTTPServer
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerAPIService

struct VolumeDriverResolutionTests {
    @Test(arguments: ["", "local"])
    func resolvesBuiltinLocalDriver(_ driver: String) throws {
        #expect(try VolumesService.resolveDriver(driver) == "local")
    }

    @Test(arguments: ["missing-driver", "nfs"])
    func rejectsUnavailableDriverBeforeMutation(_ driver: String) {
        let error = #expect(throws: VolumeError.self) {
            _ = try VolumesService.resolveDriver(driver)
        }

        guard case .driverNotSupported(let rejectedDriver)? = error else {
            Issue.record("expected unavailable volume-driver rejection")
            return
        }
        #expect(rejectedDriver == driver)
    }

    @Test func unavailableDriverDoesNotAllocateVolumeStorage() async throws {
        try await withTemporaryVolumeService { service, _, volumeRoot in
            do {
                _ = try await service.create(
                    name: "must-not-exist",
                    driver: "missing-driver",
                    driverOpts: ["size": "not-a-size"]
                )
                Issue.record("expected unavailable volume-driver rejection")
            } catch let error as VolumeError {
                guard case .driverNotSupported(let rejectedDriver) = error else {
                    Issue.record("expected unavailable volume-driver rejection, got \(error)")
                    return
                }
                #expect(rejectedDriver == "missing-driver")
            }

            #expect(!FileManager.default.fileExists(atPath: volumeRoot.appendingPathComponent("must-not-exist").path))
            #expect(try await service.list().isEmpty)
        }
    }

    @Test func builtinDriverCreatesLocalVolumeStorage() async throws {
        try await withTemporaryVolumeService { service, _, _ in
            let volume = try await service.create(
                name: "local-volume",
                driver: "",
                driverOpts: ["size": "1m"]
            )

            #expect(volume.driver == "local")
            #expect(volume.format == "ext4")
            #expect(volume.sizeInBytes == 1_048_576)
            #expect(FileManager.default.fileExists(atPath: volume.source))
            #expect(try await service.inspect("local-volume") == volume)
        }
    }

    @Test func dockerRouteRejectsUnavailableDriverBeforeNativeAllocation() async throws {
        try await withTemporaryVolumeService {
            volumes,
            containers,
            volumeRoot in
            let loggingBackend = ContainerDockerLoggingBackend(
                containers: containers,
                engineIdentity: "volume-route-test",
                serverVersion: "test",
                containerSystemConfig: ContainerSystemConfig()
            )
            let controller = try DockerLoggingAPIController(
                backend: loggingBackend,
                sharedResponseBackend: loggingBackend,
                volumeBackend: ContainerDockerVolumeBackend(volumes: volumes)
            )

            let response = await controller.respond(
                to: DockerHTTPRequest(
                    method: .post,
                    target: "/v1.53/volumes/create",
                    body: Data(
                        #"{"Name":"must-not-exist","Driver":"missing-driver","DriverOpts":{"size":"not-a-size"}}"#
                            .utf8
                    )
                )
            )
            #expect(response.status == 404)
            guard case .bytes(let body) = response.body else {
                Issue.record("expected a Docker error response body")
                return
            }
            #expect(
                try DockerJSON.decoder.decode(
                    DockerErrorEnvelope.self,
                    from: body
                ).message == "plugin \"missing-driver\" not found"
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: volumeRoot.appendingPathComponent("must-not-exist").path
                )
            )
            #expect(try await volumes.list().isEmpty)
        }
    }

    @Test func publicGatewayRejectsUnavailableDriverBeforeNativeAllocation() async throws {
        try await withTemporaryVolumeService {
            volumes,
            containers,
            volumeRoot in
            let loggingBackend = ContainerDockerLoggingBackend(
                containers: containers,
                engineIdentity: "volume-gateway-test",
                serverVersion: "test",
                containerSystemConfig: ContainerSystemConfig()
            )
            let controller = try DockerLoggingAPIController(
                backend: loggingBackend,
                sharedResponseBackend: loggingBackend,
                volumeBackend: ContainerDockerVolumeBackend(volumes: volumes)
            )
            let declaration = try ContainerEngineProviderDeclaration(
                profile: .enhanced,
                kind: .containerAuthority,
                implementationVersion: "test",
                runtimeRevisions: ["container": "test"],
                stateSchemaVersion: 1,
                capabilities: [
                    ContainerEngineProviderCapability(
                        identifier: "engine.route.VolumeCreate",
                        status: .native
                    )
                ]
            )
            let fingerprint = try ContainerEngineProviderFingerprint(
                declaration: declaration,
                stateRootUUID: UUID()
            )
            let providerSocket =
                volumeRoot
                .deletingLastPathComponent()
                .appendingPathComponent("provider.sock")
                .path
            let provider = try ContainerEngineProviderSessionServer(
                responder: controller,
                socketPath: providerSocket,
                declaration: declaration,
                stateRootUUID: fingerprint.stateRootUUID
            )
            try provider.start()
            let response: DockerHTTPResponse
            do {
                let gateway = try ContainerEngineGatewayResponder(
                    providerSocketPath: providerSocket,
                    fingerprint: fingerprint
                )
                response = await gateway.respond(
                    to: DockerHTTPRequest(
                        method: .post,
                        target: "/v1.53/volumes/create",
                        body: Data(
                            #"{"Name":"must-not-exist","Driver":"missing-driver","DriverOpts":{"size":"not-a-size"}}"#
                                .utf8
                        )
                    )
                )
            } catch {
                await provider.shutdown()
                throw error
            }
            await provider.shutdown()

            #expect(response.status == 404)
            guard case .bytes(let body) = response.body else {
                Issue.record("expected a Docker error response body")
                return
            }
            #expect(
                try DockerJSON.decoder.decode(
                    DockerErrorEnvelope.self,
                    from: body
                ).message == "plugin \"missing-driver\" not found"
            )
            #expect(!FileManager.default.fileExists(atPath: providerSocket))
            #expect(
                !FileManager.default.fileExists(
                    atPath: volumeRoot.appendingPathComponent("must-not-exist").path
                )
            )
            #expect(try await volumes.list().isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func dockerCLIVolumeCreateRejectsUnavailableDriverBeforeNativeAllocation() async throws {
        try await withTemporaryVolumeService {
            volumes,
            containers,
            volumeRoot in
            let driver = "docker-cli-missing-driver"
            let name = "docker-cli-must-not-exist"
            let loggingBackend = ContainerDockerLoggingBackend(
                containers: containers,
                engineIdentity: "volume-docker-cli-test",
                serverVersion: "test",
                containerSystemConfig: ContainerSystemConfig()
            )
            let controller = try DockerLoggingAPIController(
                backend: loggingBackend,
                sharedResponseBackend: loggingBackend,
                volumeBackend: ContainerDockerVolumeBackend(volumes: volumes)
            )
            let declaration = try ContainerEngineProviderDeclaration(
                profile: .enhanced,
                kind: .containerAuthority,
                implementationVersion: "test",
                runtimeRevisions: ["container": "test"],
                stateSchemaVersion: 1,
                capabilities: [
                    ContainerEngineProviderCapability(
                        identifier: "engine.route.VolumeCreate",
                        status: .native
                    )
                ]
            )
            let fingerprint = try ContainerEngineProviderFingerprint(
                declaration: declaration,
                stateRootUUID: UUID()
            )
            let socketRoot = volumeRoot.deletingLastPathComponent()
            let providerSocket = socketRoot.appendingPathComponent("provider.sock").path
            let publicSocket = socketRoot.appendingPathComponent("public.sock").path
            let provider = try ContainerEngineProviderSessionServer(
                responder: controller,
                socketPath: providerSocket,
                declaration: declaration,
                stateRootUUID: fingerprint.stateRootUUID
            )
            try provider.start()
            let publicServer = try ContainerUnixHTTPServer(
                responder: ContainerEngineGatewayResponder(
                    providerSocketPath: providerSocket,
                    fingerprint: fingerprint
                ),
                socketPath: publicSocket,
                logger: Logger(label: "com.apple.container.test.volume-driver-cli")
            )

            let result: DockerCLIResult
            do {
                try await publicServer.start()
                result = try runDockerCLI(
                    socketPath: publicSocket,
                    configurationRoot: socketRoot.appendingPathComponent("docker-config"),
                    arguments: [
                        "volume",
                        "create",
                        "--driver",
                        driver,
                        "--opt",
                        "size=not-a-size",
                        name,
                    ]
                )
                try await publicServer.shutdown()
                await provider.shutdown()
            } catch {
                try? await publicServer.shutdown()
                await provider.shutdown()
                throw error
            }

            #expect(result.status != 0)
            #expect(result.output.contains("plugin \"\(driver)\" not found"))
            #expect(!FileManager.default.fileExists(atPath: publicSocket))
            #expect(!FileManager.default.fileExists(atPath: providerSocket))
            #expect(
                !FileManager.default.fileExists(
                    atPath: volumeRoot.appendingPathComponent(name).path
                )
            )
            #expect(try await volumes.list().isEmpty)
        }
    }

    private func runDockerCLI(
        socketPath: String,
        configurationRoot: URL,
        arguments: [String]
    ) throws -> DockerCLIResult {
        try FileManager.default.createDirectory(
            at: configurationRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [
                "docker",
                "--host",
                "unix://\(socketPath)",
            ] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DOCKER_CONFIG"] = configurationRoot.path
        environment["DOCKER_HOST"] = "unix://\(socketPath)"
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = Data(
            standardOutput.fileHandleForReading.readDataToEndOfFile()
                + standardError.fileHandleForReading.readDataToEndOfFile()
        )
        return DockerCLIResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self)
        )
    }

    private func withTemporaryVolumeService(
        body: (VolumesService, ContainersService, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("container-volume-driver-test-\(UUID().uuidString)")
        let marker = root.appendingPathComponent(".container-volume-driver-test-root")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("container-volume-driver-test-root\n".utf8).write(
            to: marker,
            options: .atomic
        )
        defer {
            if FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let containersService = try ContainersService(
            appRoot: root,
            pluginLoader: PluginLoader(
                appRoot: root,
                installRoot: root,
                logRoot: nil,
                pluginDirectories: [],
                pluginFactories: []
            ),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "com.apple.container.test.volume-driver")
        )
        let volumeRoot = root.appendingPathComponent("volumes")
        let service = try await VolumesService(
            resourceRoot: FilePath(volumeRoot.path),
            containersService: containersService,
            log: Logger(label: "com.apple.container.test.volume-driver")
        )

        try await body(service, containersService, volumeRoot)
    }
}

private struct DockerCLIResult {
    let status: Int32
    let output: String
}
