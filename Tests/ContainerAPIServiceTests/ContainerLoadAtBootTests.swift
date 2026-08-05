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
import Containerization
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct ContainerLoadAtBootTests {
    @Test
    func dockerLifecycleStateSurvivesAuthorityRestart() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "previously-run"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let started = Date(timeIntervalSince1970: 1_234)
        let exited = Date(timeIntervalSince1970: 1_250)
        try bundle.setDurably(
            lifecycleState: ContainerLifecycleStateV1(
                startedDate: started,
                exitCode: 17,
                exitedDate: exited
            )
        )

        let state = try #require(
            ContainersService.loadAtBoot(
                root: fixture.containers,
                loader: fixture.loader,
                log: fixture.log
            )[id]
        )
        #expect(state.snapshot.status == .stopped)
        #expect(state.snapshot.startedDate == started)
        #expect(state.snapshot.exitCode == 17)
        #expect(state.snapshot.exitedDate == exited)
    }

    @Test
    func corruptLifecycleStateLeavesBundleOnDisk() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "corrupt-lifecycle"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try Data("{".utf8).write(
            to: bundle.filePath(for: ContainerResource.Bundle.lifecycleStateFilename)
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        #expect(states[id] == nil)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func malformedConfigurationFilesRemainOnDisk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let bundlePath = fixture.containers.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bundlePath.appendingPathComponent("config.json"))
        try Data("{".utf8).write(to: bundlePath.appendingPathComponent("runtime-configuration.json"))

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )

        #expect(states.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func missingRuntimeBundleRemainsOnDiskButIsNotLoaded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let bundlePath = fixture.containers.appendingPathComponent("missing-runtime")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: "missing-runtime"))

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )

        #expect(states.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
        let recovered: ContainerConfiguration = try bundle.load(filename: "config.json")
        #expect(recovered.id == "missing-runtime")
    }

    private func testConfiguration(id: String) -> ContainerConfiguration {
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
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }
}

private struct Fixture {
    let root: URL
    let containers: URL
    let loader: PluginLoader
    let log = Logger(label: "ContainerLoadAtBootTests")

    init(includeRuntime: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        containers = root.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        let pluginRoot = root.appendingPathComponent("plugins")
        if includeRuntime {
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("container-runtime-linux"),
                withIntermediateDirectories: true
            )
        }
        loader = try PluginLoader(
            appRoot: root,
            installRoot: root,
            logRoot: nil,
            pluginDirectories: includeRuntime ? [pluginRoot] : [],
            pluginFactories: includeRuntime
                ? [LifecycleRuntimePluginFactory()]
                : []
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LifecycleRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux" else {
            return nil
        }
        let services = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [
                PluginConfig.Service(type: .runtime, description: nil)
            ],
            defaultArguments: []
        )
        return Plugin(
            binaryURL: installURL.appendingPathComponent(
                "container-runtime-linux"
            ),
            config: PluginConfig(
                abstract: "runtime",
                author: nil,
                servicesConfig: services
            )
        )
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}
