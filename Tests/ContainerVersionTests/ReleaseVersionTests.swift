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
    func singleLineIncludesForkProvenance() throws {
        let line = ReleaseVersion.singleLine(appName: "container CLI")
        let containerization = try Self.expectedContainerizationProvenance()

        #expect(line.contains("distribution: custom"))
        #expect(line.contains("source: stephenlclarke/container"))
        #expect(line.contains("containerization: \(containerization)"))
        #expect(line.contains("builder-shim: \(ReleaseVersion.builderShimImage())"))
    }

    @Test
    func provenanceLinesIncludeSourceAndContainerization() throws {
        let lines = ReleaseVersion.provenanceLines(indent: "")
        let containerization = try Self.expectedContainerizationProvenance()

        #expect(lines.contains("distribution: custom"))
        #expect(lines.contains("source: stephenlclarke/container"))
        #expect(lines.contains("containerization: \(containerization)"))
        #expect(lines.contains("container-builder-shim: \(ReleaseVersion.builderShimImage())"))
    }

    private static func expectedContainerizationProvenance() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Package.resolved"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(object["pins"] as? [[String: Any]])
        let pin = try #require(pins.first { ($0["identity"] as? String) == "containerization" })
        let location = try #require(pin["location"] as? String)
        let state = try #require(pin["state"] as? [String: Any])
        let revision = try #require(state["revision"] as? String)
        return "\(githubRepositoryPath(from: location))@\(revision)"
    }

    private static func githubRepositoryPath(from location: String) -> String {
        var repository = location
        for prefix in ["https://github.com/", "git@github.com:"] {
            if repository.hasPrefix(prefix) {
                repository.removeFirst(prefix.count)
                break
            }
        }
        if repository.hasSuffix(".git") {
            repository.removeLast(4)
        }
        return repository
    }
}
