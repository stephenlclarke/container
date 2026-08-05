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

import ContainerVersion
import Foundation
import Testing

struct ReleaseVersionTests {
    @Test
    func runtimeCapabilityManifestIsVersionedUniqueAndSorted() throws {
        let manifest = RuntimeCapabilityManifest.current
        let identifiers = manifest.capabilities.map(\.rawValue)

        #expect(manifest.schemaVersion == 1)
        #expect(identifiers.count == 8)
        #expect(identifiers.contains("io.github.stephenlclarke.container.logging-drivers.v1"))
        #expect(identifiers == identifiers.sorted())
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.hasSuffix(".v1") })
        #expect(
            try JSONDecoder().decode(
                RuntimeCapabilityManifest.self,
                from: JSONEncoder().encode(manifest)
            ) == manifest
        )
    }

    @Test
    func singleLineIncludesForkProvenance() throws {
        let line = ReleaseVersion.singleLine(appName: "container CLI")
        let containerization = Self.expectedContainerizationProvenance()

        #expect(line.contains("distribution: custom"))
        #expect(line.contains("source: stephenlclarke/container"))
        #expect(line.contains("containerization: \(containerization)"))
        #expect(line.contains("vminit: \(ReleaseVersion.vminitImage())"))
        #expect(line.contains("builder-shim: \(ReleaseVersion.builderShimImage())"))
    }

    @Test
    func provenanceLinesIncludeSourceAndContainerization() throws {
        let lines = ReleaseVersion.provenanceLines(indent: "")
        let containerization = Self.expectedContainerizationProvenance()

        #expect(lines.contains("distribution: custom"))
        #expect(lines.contains("source: stephenlclarke/container"))
        #expect(lines.contains("containerization: \(containerization)"))
        #expect(lines.contains("vminit: \(ReleaseVersion.vminitImage())"))
        #expect(lines.contains("container-builder-shim: \(ReleaseVersion.builderShimImage())"))
    }

    @Test
    func customVminitImageUsesExactContainerizationRevision() {
        let revision = String(repeating: "a", count: 40)
        #expect(
            ReleaseVersion.vminitImage(
                containerizationSource: "Example/Containerization",
                containerizationRef: revision.uppercased(),
                upstreamVersion: "0.40.1"
            ) == "ghcr.io/example/containerization/vminit:\(revision)"
        )
        #expect(
            ReleaseVersion.vminitImage(
                containerizationSource: "apple/containerization",
                containerizationRef: revision,
                upstreamVersion: "0.40.1"
            ) == "ghcr.io/apple/containerization/vminit:0.40.1"
        )
        #expect(
            ReleaseVersion.vminitImage(
                containerizationSource: "example/containerization",
                containerizationRef: "main",
                upstreamVersion: "0.40.1"
            ) == "vminit:latest"
        )
        #expect(
            ReleaseVersion.vminitImage(
                containerizationSource: "unsafe source",
                containerizationRef: revision,
                upstreamVersion: "0.40.1"
            ) == "vminit:latest"
        )
    }

    @Test
    func engineAPIVersionMatchesResolvedPackage() throws {
        let expected = try Self.expectedEngineAPIVersion()
        #expect(ReleaseVersion.containerEngineAPIVersion() == expected)
    }

    private static func expectedContainerizationProvenance() -> String {
        "\(ReleaseVersion.containerizationSource())@\(ReleaseVersion.containerizationRef())"
    }

    private static func expectedEngineAPIVersion() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Package.resolved"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let pins = try #require(object["pins"] as? [[String: Any]])
        let pin = try #require(
            pins.first {
                ($0["identity"] as? String) == "container-engine-api"
            }
        )
        let state = try #require(pin["state"] as? [String: Any])
        return try #require(state["version"] as? String)
    }

}
