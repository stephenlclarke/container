//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Yams

/// Tests for `container system version` output formats and build type detection.
@Suite(.serialSuites)
final class TestCLIVersion: CLITest {
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
        let server: VersionInfo?
    }

    private func expectedBuildType() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    @Test func defaultDisplaysSummary() throws {
        let (data, out, err, status) = try run(arguments: ["system", "version"])
        #expect(status == 0, "system version should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 7)
        #expect(lines[0] == "container:")
        #expect(lines.contains(where: { $0.contains("version") }))
        #expect(lines.contains(where: { $0.contains("build") }))
        #expect(lines.contains(where: { $0.contains("commit") }))
        #expect(lines.contains(where: { $0.contains("builder-shim") }))
        #expect(!lines[0].contains("COMPONENT"))
        #expect(lines.contains(where: { $0.hasPrefix("  version: ") }))
        #expect(!out.contains("version:  "))
        #expect(out.contains("ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.3"))

        // Build should reflect the binary we are running (debug/release)
        let expected = expectedBuildType()
        #expect(lines.contains(where: { $0.contains("build") && $0.contains(expected) }))
        _ = data  // silence unused warning if assertions short-circuit
    }

    @Test func jsonFormat() throws {
        let (data, out, err, status) = try run(arguments: ["system", "version", "--format", "json"])
        #expect(status == 0, "system version --format json should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let decoded = try JSONDecoder().decode([VersionOutput].self, from: data)
        #expect(decoded[0].appName == "container")
        #expect(!decoded[0].version.isEmpty)
        #expect(!decoded[0].commit.isEmpty)
        #expect(decoded[0].builderShimRepository == "ghcr.io/stephenlclarke/container-builder-shim/builder")
        #expect(decoded[0].builderShimVersion == "0.13.3")

        let expected = expectedBuildType()
        #expect(decoded[0].buildType == expected)
    }

    @Test func yamlFormat() throws {
        let (data, out, err, status) = try run(arguments: ["system", "version", "--format", "yaml"])
        #expect(status == 0, "system version --format yaml should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let decoded = try YAMLDecoder().decode([VersionOutput].self, from: data)
        #expect(decoded[0].appName == "container")
        #expect(!decoded[0].version.isEmpty)
        #expect(!decoded[0].commit.isEmpty)

        let expected = expectedBuildType()
        #expect(decoded[0].buildType == expected)
    }

    @Test func explicitTableFormat() throws {
        let (_, out, err, status) = try run(arguments: ["system", "version", "--format", "table"])
        #expect(status == 0, "system version --format table should succeed, stderr: \(err)")
        #expect(!out.isEmpty)

        let lines = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        #expect(lines.count >= 7)
        #expect(lines[0] == "container:")
        #expect(lines.contains(where: { $0.hasPrefix("  version: ") }))
        #expect(!out.contains("version:  "))
        #expect(lines.contains(where: { $0.contains("builder-shim") }))
        #expect(out.contains("ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.3"))
    }

    @Test func buildTypeMatchesBinary() throws {
        // Validate build type via JSON to avoid parsing table text loosely
        let (data, _, err, status) = try run(arguments: ["system", "version", "--format", "json"])
        #expect(status == 0, "version --format json should succeed, stderr: \(err)")
        let decoded = try JSONDecoder().decode([VersionOutput].self, from: data)

        let expected = expectedBuildType()
        #expect(decoded[0].buildType == expected, "Expected build type \(expected) but got \(decoded[0].buildType)")
    }
}
