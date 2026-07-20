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
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import ContainerAPIClient

struct ClientImageImageResourceTests {
    @Test func imageResourceIncludesImageConfigHealthCheck() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let indexDigest = digest(0)
        let manifestDigest = digest(1)
        let configDigest = digest(2)
        let layerDigest = digest(3)
        let configData = Data(
            """
            {
              "created": "2026-06-22T01:00:00Z",
              "architecture": "arm64",
              "os": "linux",
              "config": {
                "Labels": {
                  "com.docker.compose.bridge": "transformation"
                },
                "ExposedPorts": {
                  "8080/tcp": {},
                  "8443/udp": {}
                },
                "Volumes": {
                  "/var/lib/cache": {},
                  "/var/lib/state": {}
                },
                "Healthcheck": {
                  "Test": ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
                  "Interval": 5000000000,
                  "Timeout": 1000000000,
                  "StartPeriod": 10000000000,
                  "StartInterval": 500000000,
                  "Retries": 5
                }
              },
              "rootfs": {
                "type": "layers",
                "diff_ids": []
              }
            }
            """.utf8
        )
        let manifest = Manifest(
            config: .init(mediaType: MediaTypes.imageConfig, digest: configDigest, size: Int64(configData.count)),
            layers: [.init(mediaType: MediaTypes.imageLayer, digest: layerDigest, size: 64)]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let index = Index(
            manifests: [
                .init(
                    mediaType: MediaTypes.imageManifest,
                    digest: manifestDigest,
                    size: Int64(manifestData.count),
                    platform: platform
                )
            ]
        )
        let indexData = try JSONEncoder().encode(index)
        let store = try FixtureContentStore(
            directory: directory,
            contents: [
                indexDigest: indexData,
                manifestDigest: manifestData,
                configDigest: configData,
            ]
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/example:latest",
                descriptor: .init(mediaType: MediaTypes.index, digest: indexDigest, size: Int64(indexData.count))
            ),
            contentStore: store
        )

        let resource = try await image.toImageResource(containerSystemConfig: ContainerSystemConfig())
        let variant = try #require(resource.variants.first)
        let healthCheck = try #require(variant.healthCheck)

        #expect(resource.displayReference == "example:latest")
        #expect(variant.platform == platform)
        #expect(variant.imageConfigLabels == ["com.docker.compose.bridge": "transformation"])
        #expect(variant.exposedPorts == ["8080/tcp", "8443/udp"])
        #expect(variant.config.config?.volumes == ["/var/lib/cache": [:], "/var/lib/state": [:]])
        #expect(healthCheck.test == ["CMD-SHELL", "curl -f http://localhost/health || exit 1"])
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.timeoutInNanoseconds == 1_000_000_000)
        #expect(healthCheck.startPeriodInNanoseconds == 10_000_000_000)
        #expect(healthCheck.startIntervalInNanoseconds == 500_000_000)
        #expect(healthCheck.retries == 5)
    }
}

private struct FixtureContentStore: ContentStore {
    let contents: [String: Content]

    init(directory: URL, contents: [String: Data]) throws {
        var stored: [String: Content] = [:]
        for (digest, data) in contents {
            let url = directory.appending(path: digest.replacingOccurrences(of: ":", with: "-"))
            try data.write(to: url)
            stored[digest] = try LocalContent(path: url)
        }
        self.contents = stored
    }

    func get(digest: String) async throws -> Content? {
        contents[digest]
    }

    func get<T: Decodable>(digest: String) async throws -> T? {
        try contents[digest]?.decode()
    }

    func delete(digests: [String]) async throws -> ([String], UInt64) {
        ([], 0)
    }

    func delete(keeping: [String]) async throws -> ([String], UInt64) {
        ([], 0)
    }

    func ingest(_ body: @Sendable @escaping (URL) async throws -> Void) async throws -> [String] {
        throw ContainerizationError(.unsupported, message: "fixture content store does not support ingest")
    }

    func newIngestSession() async throws -> (id: String, ingestDir: URL) {
        throw ContainerizationError(.unsupported, message: "fixture content store does not support ingest")
    }

    func completeIngestSession(_ id: String) async throws -> [String] {
        throw ContainerizationError(.unsupported, message: "fixture content store does not support ingest")
    }

    func cancelIngestSession(_ id: String) async throws {
        throw ContainerizationError(.unsupported, message: "fixture content store does not support ingest")
    }

    func totalAllocatedSize() async throws -> UInt64 {
        0
    }
}

private func digest(_ seed: Int) -> String {
    "sha256:" + String(repeating: String(seed), count: 64)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "container-image-resource-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
