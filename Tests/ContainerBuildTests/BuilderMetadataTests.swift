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
            secrets: [:],
            ssh: ["default", "git=/tmp/agent.sock"],
            attestations: [
                "attest-provenance": "mode=max",
                "attest-sbom": "",
            ],
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
