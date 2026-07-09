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

import ContainerPersistence
import ContainerizationOCI
import Foundation
import GRPCCore
import Testing

@testable import ContainerBuild

struct BuilderMetadataTests {
    @Test
    func buildExportPreservesEqualsInsideValues() throws {
        let export = try Builder.BuildExport(from: "type=oci,annotation=key=value")

        #expect(export.type == "oci")
        #expect(export.additionalFields["annotation"] == "key=value")
    }

    @Test
    func buildExportStringValuePreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-builder-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let export = try Builder.BuildExport(from: "type=tar,dest=\(directory.path)")

        #expect(export.destination?.lastPathComponent == "out.tar")
        #expect(try export.stringValue == "type=tar,dest=\(directory.appendingPathComponent("out.tar").path)")
    }

    @Test
    func buildExportRejectsMalformedFields() throws {
        #expect(throws: Builder.Error.self) {
            try Builder.BuildExport(from: "type=oci,malformed")
        }
    }

    @Test
    func buildMetadataIncludesRepeatedSSHValues() throws {
        let config = Builder.BuildConfig(
            buildID: "build-id",
            contentStore: NoopContentStore(),
            buildArgs: [],
            buildContexts: [
                "base": "docker-image://example/base:latest",
                "shared": "local:shared",
            ],
            localBuildContexts: ["shared": "/tmp/shared"],
            secrets: [:],
            ssh: ["default", "git=/tmp/agent.sock"],
            entitlements: ["network.host"],
            attestations: [
                "attest-provenance": "mode=max",
                "attest-sbom": "",
            ],
            addHosts: ["build.local=127.0.0.1"],
            network: "host",
            privileged: true,
            shmSize: "67108864",
            ulimits: ["nofile=1024:2048"],
            contextDir: "/tmp/context",
            dockerfile: Data("FROM scratch\n".utf8),
            dockerignore: nil,
            labels: [],
            noCache: false,
            platforms: [],
            terminal: nil,
            tags: ["example/app:latest"],
            target: "",
            quiet: false,
            exports: [try Builder.BuildExport(from: "type=oci")],
            cacheIn: [],
            cacheOut: [],
            pull: false,
            containerSystemConfig: ContainerSystemConfig(),
            check: true
        )

        let metadata = try Builder.buildMetadata(config)

        #expect(Array(metadata[stringValues: "ssh"]) == ["default", "git=/tmp/agent.sock"])
        #expect(
            Array(metadata[stringValues: "build-contexts"]) == [
                "base=docker-image://example/base:latest",
                "shared=local:shared",
            ])
        #expect(Array(metadata[stringValues: "entitlements"]) == ["network.host"])
        #expect(Array(metadata[stringValues: "add-hosts"]) == ["build.local=127.0.0.1"])
        #expect(Array(metadata[stringValues: "network"]) == ["host"])
        #expect(Array(metadata[stringValues: "privileged"]) == [""])
        #expect(Array(metadata[stringValues: "shm-size"]) == ["67108864"])
        #expect(Array(metadata[stringValues: "ulimit"]) == ["nofile=1024:2048"])
        #expect(Array(metadata[stringValues: "attest-provenance"]) == ["mode=max"])
        #expect(Array(metadata[stringValues: "attest-sbom"]) == [""])
        #expect(Array(metadata[stringValues: "check"]) == [""])
    }
}

private struct NoopContentStore: ContentStore {
    func get(digest: String) async throws -> Content? {
        nil
    }

    func get<T>(digest: String) async throws -> T? where T: Decodable {
        nil
    }

    func delete(digests: [String]) async throws -> ([String], UInt64) {
        ([], 0)
    }

    func delete(keeping: [String]) async throws -> ([String], UInt64) {
        ([], 0)
    }

    func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try await body(url)
        return []
    }

    func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        (UUID().uuidString, FileManager.default.temporaryDirectory)
    }

    func completeIngestSession(_ id: String) async throws -> [String] {
        []
    }

    func cancelIngestSession(_ id: String) async throws {}

    func totalAllocatedSize() async throws -> UInt64 {
        0
    }
}
