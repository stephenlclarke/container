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

import Foundation
import Testing

@testable import ContainerCommands

struct SystemStatusTests {
    private func makeRunningPayload(
        paths: Application.PathInfo? = nil,
        resources: Application.ResourceCounts? = nil
    ) -> Application.StatusPayload {
        Application.StatusPayload(
            status: "running",
            client: Application.ClientInfo(version: "1.2.3", build: "release", commit: "abcdef", appName: "container"),
            server: Application.ServerInfo(
                version: "9.9.9",
                build: "release",
                commit: "deadbeef",
                appName: "container-apiserver",
                builderShimRepository: "ghcr.io/example/builder",
                builderShimVersion: "current",
                builderShimDigest: "sha256:0123456789abcdef"
            ),
            host: Application.HostInfo(architecture: "arm64", operatingSystem: "macOS 26.0", cpus: 8),
            paths: paths,
            resources: resources,
            engineStatus: "running",
            engineSocket: "/tmp/container-engine.sock"
        )
    }

    @Test
    func tableIncludesStatusClientAndHostWhenRunning() {
        let table = Application.SystemStatus.statusTable(makeRunningPayload())
        #expect(table.contains("FIELD"))
        #expect(table.contains("status"))
        #expect(table.contains("running"))
        #expect(table.contains("client.version"))
        #expect(table.contains("1.2.3"))
        #expect(table.contains("host.architecture"))
        #expect(table.contains("arm64"))
        #expect(table.contains("host.cpus"))
        #expect(table.contains("engine.status"))
        #expect(table.contains("/tmp/container-engine.sock"))
    }

    @Test
    func tableShowsOnlyStatusWhenNotRunning() {
        let table = Application.SystemStatus.statusTable(Application.StatusPayload(status: "not running"))
        #expect(table.contains("status"))
        #expect(table.contains("not running"))
        #expect(!table.contains("client.version"))
        #expect(!table.contains("server.version"))
    }

    @Test
    func tableShowsServerAndDaemonFieldsWhenRunning() {
        let payload = makeRunningPayload(
            paths: Application.PathInfo(appRoot: "/app/root", installRoot: "/install/root", logRoot: "/log/root"),
            resources: {
                Application.ResourceCounts(containersTotal: 5, containersRunning: 2, images: 7)
            }()
        )
        let table = Application.SystemStatus.statusTable(payload)
        #expect(table.contains("server.version"))
        #expect(table.contains("9.9.9"))
        #expect(table.contains("server.builderShim"))
        #expect(table.contains("ghcr.io/example/builder@sha256:0123456789abcdef"))
        #expect(table.contains("paths.appRoot"))
        #expect(table.contains("/app/root"))
        #expect(table.contains("containers.total"))
        #expect(table.contains("containers.running"))
        #expect(table.contains("images.total"))
    }

    @Test
    func payloadRoundTripsThroughJSON() throws {
        let payload = makeRunningPayload()
        let json = try Output.renderJSON(payload)
        let decoded = try JSONDecoder().decode(Application.StatusPayload.self, from: Data(json.utf8))
        #expect(decoded.status == "running")
        #expect(decoded.client?.version == "1.2.3")
        #expect(decoded.server?.commit == "deadbeef")
        #expect(decoded.host?.cpus == 8)
        #expect(decoded.paths == nil)
        #expect(decoded.engineStatus == "running")
        #expect(decoded.engineSocket == "/tmp/container-engine.sock")
    }

    @Test
    func independentResourceCountsAreRecorded() {
        let counts = Application.SystemStatus.resourceCounts(
            containersTotal: 3,
            containersRunning: 1,
            imageCount: 7
        )
        #expect(counts?.containersTotal == 3)
        #expect(counts?.containersRunning == 1)
        #expect(counts?.images == 7)
        // And it surfaces in the rendered table.
        let table = Application.SystemStatus.statusTable(makeRunningPayload(resources: counts))
        #expect(table.contains("containers.total"))
        #expect(table.contains("containers.running"))
        #expect(table.contains("images.total"))
        #expect(table.contains("7"))
    }

    @Test
    func imageCountSurvivesUnavailableContainerCounts() {
        let counts = Application.SystemStatus.resourceCounts(
            containersTotal: nil,
            containersRunning: nil,
            imageCount: 7
        )
        #expect(counts?.containersTotal == nil)
        #expect(counts?.containersRunning == nil)
        #expect(counts?.images == 7)
        let table = Application.SystemStatus.statusTable(makeRunningPayload(resources: counts))
        #expect(!table.contains("containers.total"))
        #expect(!table.contains("containers.running"))
        #expect(table.contains("images.total"))
    }

    @Test
    func containerCountsSurviveUnavailableImageCount() {
        let counts = Application.SystemStatus.resourceCounts(
            containersTotal: 4,
            containersRunning: 2,
            imageCount: nil
        )
        #expect(counts?.containersTotal == 4)
        #expect(counts?.containersRunning == 2)
        #expect(counts?.images == nil)
        let table = Application.SystemStatus.statusTable(makeRunningPayload(resources: counts))
        #expect(table.contains("containers.total"))
        #expect(table.contains("containers.running"))
        #expect(!table.contains("images.total"))
    }

    @Test
    func allUnavailableResourceCountsAreOmitted() {
        #expect(
            Application.SystemStatus.resourceCounts(
                containersTotal: nil,
                containersRunning: nil,
                imageCount: nil
            ) == nil
        )
    }
}
