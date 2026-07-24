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

import ContainerTestSupport
import Foundation
import Testing
import Yams

/// Tests for `container system version` output formats and build type detection.
@Suite
struct TestCLIVersion {
    struct VersionInfo: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
    }

    struct VersionOutput: Codable {
        let version: String
        let buildType: String
        let commit: String
        let appName: String
        let builderShimRepository: String?
        let builderShimVersion: String?
        let builderShimDigest: String?
        let server: VersionInfo?
    }

    private func expectedBuildType() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    @Test func defaultDisplaysSummary() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "version"])
            #expect(result.status == 0, "system version should succeed, stderr: \(result.error)")
            #expect(!result.output.isEmpty)

            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            #expect(lines.count >= 7)
            #expect(lines[0] == "container:")
            #expect(lines.contains(where: { $0.contains("version") }))
            #expect(lines.contains(where: { $0.contains("build") }))
            #expect(lines.contains(where: { $0.contains("commit") }))
            #expect(lines.contains(where: { $0.contains("builder-shim") }))
            #expect(!lines[0].contains("COMPONENT"))
            #expect(lines.contains(where: { $0.hasPrefix("  version: ") }))
            #expect(!result.output.contains("version:  "))
            #expect(result.output.contains("ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197"))

            let expected = expectedBuildType()
            #expect(lines.contains(where: { $0.contains("build") && $0.contains(expected) }))
        }
    }

    @Test func jsonFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "version", "--format", "json"])
            #expect(result.status == 0, "system version --format json should succeed, stderr: \(result.error)")
            #expect(!result.output.isEmpty)

            let decoded = try JSONDecoder().decode([VersionOutput].self, from: result.outputData)
            #expect(decoded[0].appName == "container")
            #expect(!decoded[0].version.isEmpty)
            #expect(!decoded[0].commit.isEmpty)
            #expect(decoded[0].builderShimRepository == "ghcr.io/stephenlclarke/container-builder-shim/builder")
            #expect(decoded[0].builderShimVersion == "current-30068004175-f97cddf5b3aa")
            #expect(decoded[0].builderShimDigest == "sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197")
            #expect(decoded[0].buildType == expectedBuildType())
        }
    }

    @Test func yamlFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "version", "--format", "yaml"])
            #expect(result.status == 0, "system version --format yaml should succeed, stderr: \(result.error)")
            #expect(!result.output.isEmpty)

            let decoded = try YAMLDecoder().decode([VersionOutput].self, from: result.outputData)
            #expect(decoded[0].appName == "container")
            #expect(!decoded[0].version.isEmpty)
            #expect(!decoded[0].commit.isEmpty)
            #expect(decoded[0].buildType == expectedBuildType())
        }
    }

    @Test func explicitTableFormat() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "version", "--format", "table"])
            #expect(result.status == 0, "system version --format table should succeed, stderr: \(result.error)")
            #expect(!result.output.isEmpty)

            let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            #expect(lines.count >= 7)
            #expect(lines[0] == "container:")
            #expect(lines.contains(where: { $0.hasPrefix("  version: ") }))
            #expect(!result.output.contains("version:  "))
            #expect(lines.contains(where: { $0.contains("builder-shim") }))
            #expect(result.output.contains("ghcr.io/stephenlclarke/container-builder-shim/builder@sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197"))
        }
    }

    @Test func buildTypeMatchesBinary() async throws {
        try await ContainerFixture.with { f in
            let result = try f.run(["system", "version", "--format", "json"])
            #expect(result.status == 0, "version --format json should succeed, stderr: \(result.error)")

            let decoded = try JSONDecoder().decode([VersionOutput].self, from: result.outputData)
            let expected = expectedBuildType()
            #expect(
                decoded[0].buildType == expected,
                "Expected build type \(expected) but got \(decoded[0].buildType)")
        }
    }
}
