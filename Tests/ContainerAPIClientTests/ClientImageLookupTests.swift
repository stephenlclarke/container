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

struct ClientImageLookupTests {
    private let containerSystemConfig = ContainerSystemConfig()

    @Test
    func testMatchUsesDisplayedDefaultRegistryNameWhenUnique() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "01a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let fedora = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "11a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [fedora, ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchDoesNotGuessAmbiguousDisplayedNames() throws {
        let jammy = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "21a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let noble = Self.image(
            reference: "docker.io/library/ubuntu:24.04",
            digest: "31a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [jammy, noble], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == nil)
    }

    @Test
    func testMatchUsesDigestPrefixFromImageList() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "e10577f0db681cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "e10577f0db68", in: [ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchDoesNotTreatHexTagsAsDigestPrefixes() throws {
        let digestMatch = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "deadbeefdead1cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let tagged = Self.image(
            reference: "docker.io/library/foo:deadbeefdead",
            digest: "71a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "foo:deadbeefdead", in: [digestMatch, tagged], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == tagged.reference)
    }

    @Test
    func testMatchDoesNotGuessAmbiguousDigestPrefixes() throws {
        let first = Self.image(
            reference: "docker.io/library/ubuntu:22.04",
            digest: "d56a2534ffd21cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let second = Self.image(
            reference: "docker.io/library/fedora:latest",
            digest: "d56a2534ffd22cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "d56a2534ffd2", in: [first, second], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == nil)
    }

    @Test
    func testMatchDoesNotUseAnotherDigestAlgorithmAsImageID() throws {
        let descriptor = Descriptor(
            mediaType: MediaTypes.index,
            digest: "sha512:e10577f0db681cefaaffc6ab0000000000000000000000000000000000000000",
            size: 0
        )
        let image = ClientImage(
            description: ImageDescription(
                reference: "docker.io/library/ubuntu:22.04",
                descriptor: descriptor
            )
        )

        let match = try ClientImage.match(
            reference: "e10577f0db68",
            in: [image],
            containerSystemConfig: containerSystemConfig
        )

        #expect(match == nil)
    }

    @Test
    func testMatchKeepsNormalizedReferenceBehavior() throws {
        let ubuntu = Self.image(
            reference: "docker.io/library/ubuntu:latest",
            digest: "41a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )

        let match = try ClientImage.match(reference: "ubuntu", in: [ubuntu], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == ubuntu.reference)
    }

    @Test
    func testMatchPreservesLocalImageAnnotationPreference() throws {
        let remote = Self.image(
            reference: "docker.io/library/foo:latest",
            digest: "51a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000"
        )
        let local = Self.image(
            reference: "registry.local/builds/foo:latest",
            digest: "61a3ee0b5e413cefaaffc6ab0000000000000000000000000000000000000000",
            annotations: [AnnotationKeys.containerizationImageName: "foo:latest"]
        )

        let match = try ClientImage.match(reference: "foo", in: [remote, local], containerSystemConfig: containerSystemConfig)

        #expect(match?.reference == local.reference)
    }

    @Test
    func testAsyncMatchResolvesFullConfigDigestAndDeduplicatesAliases() async throws {
        let firstAlias = Self.image(reference: "registry.local/example:latest", digest: String(repeating: "a", count: 64))
        let secondAlias = Self.image(reference: "example:latest", digest: String(repeating: "a", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)
        let resolverCalls = ResolverCallCounter()

        let match = try await ClientImage.match(
            reference: configDigest,
            in: [firstAlias, secondAlias],
            containerSystemConfig: containerSystemConfig,
            configDigestResolver: { image in
                await resolverCalls.record(image.digest)
                return [configDigest]
            }
        )

        #expect(match?.reference == "example:latest")
        #expect(await resolverCalls.recordedCount() == 1)
    }

    @Test
    func testAsyncMatchRejectsAmbiguousConfigDigestAcrossImages() async throws {
        let first = Self.image(reference: "registry.local/first:latest", digest: String(repeating: "a", count: 64))
        let second = Self.image(reference: "registry.local/second:latest", digest: String(repeating: "b", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        await #expect(throws: ContainerizationError.self) {
            try await ClientImage.match(
                reference: configDigest,
                in: [first, second],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in [configDigest] }
            )
        }
    }

    @Test
    func testAsyncMatchRejectsMultiPlatformConfigDigestWithoutVariantPinning() async throws {
        let image = Self.image(reference: "registry.local/multiarch:latest", digest: String(repeating: "a", count: 64))
        let arm64ConfigDigest = "sha256:" + String(repeating: "c", count: 64)
        let amd64ConfigDigest = "sha256:" + String(repeating: "d", count: 64)

        await #expect(throws: ContainerizationError.self) {
            try await ClientImage.lookup(
                names: [amd64ConfigDigest],
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in [arm64ConfigDigest, amd64ConfigDigest] }
            )
        }
    }

    @Test
    func testAsyncMatchPropagatesUnreadableCandidateInsteadOfGuessingUniqueMatch() async throws {
        let corrupt = Self.image(reference: "registry.local/corrupt:latest", digest: String(repeating: "a", count: 64))
        let valid = Self.image(reference: "registry.local/valid:latest", digest: String(repeating: "b", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        await #expect(throws: TestResolverError.self) {
            try await ClientImage.match(
                reference: configDigest,
                in: [corrupt, valid],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { image in
                    if image.digest == corrupt.digest {
                        throw TestResolverError.corrupt
                    }
                    return [configDigest]
                }
            )
        }
    }

    @Test
    func testAsyncMatchPropagatesCancellation() async throws {
        let image = Self.image(reference: "registry.local/example:latest", digest: String(repeating: "a", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        await #expect(throws: CancellationError.self) {
            try await ClientImage.match(
                reference: configDigest,
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in throw CancellationError() }
            )
        }
    }

    @Test
    func testNamedImageLookupPropagatesCancellation() async throws {
        let image = Self.image(reference: "registry.local/example:latest", digest: String(repeating: "a", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        await #expect(throws: CancellationError.self) {
            try await ClientImage.lookup(
                names: [configDigest],
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in throw CancellationError() }
            )
        }
    }

    @Test
    func testNamedImageLookupPropagatesConfigDigestResolutionErrors() async throws {
        let image = Self.image(reference: "registry.local/example:latest", digest: String(repeating: "a", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        await #expect(throws: TestResolverError.self) {
            try await ClientImage.lookup(
                names: [configDigest],
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in throw TestResolverError.corrupt }
            )
        }
        await #expect(throws: ContainerizationError.self) {
            try await ClientImage.lookup(
                names: [configDigest],
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in
                    throw ContainerizationError(.internalError, message: "unreadable image")
                }
            )
        }
        await #expect(throws: ContainerizationError.self) {
            try await ClientImage.lookup(
                names: [configDigest],
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in
                    throw ContainerizationError(.notFound, message: "missing local image content")
                }
            )
        }
    }

    @Test
    func testAsyncMatchKeepsManifestDigestAndNamedDigestResolutionAheadOfConfigIDs() async throws {
        let manifest = Self.image(reference: "registry.local/manifest:latest", digest: String(repeating: "a", count: 64))
        let config = Self.image(reference: "registry.local/config:latest", digest: String(repeating: "b", count: 64))
        let manifestDigest = manifest.digest
        let configDigest = "sha256:" + String(repeating: "c", count: 64)
        let resolver: ClientImage.ConfigDigestResolver = { _ in throw TestResolverError.corrupt }

        let manifestMatch = try await ClientImage.match(
            reference: manifestDigest,
            in: [manifest, config],
            containerSystemConfig: containerSystemConfig,
            configDigestResolver: resolver
        )
        let namedDigestMatch = try await ClientImage.match(
            reference: "registry.local/config:latest@\(configDigest)",
            in: [config],
            containerSystemConfig: containerSystemConfig,
            configDigestResolver: resolver
        )
        let missingNamedDigest = try await ClientImage.match(
            reference: "registry.local/missing:latest@\(configDigest)",
            in: [config],
            containerSystemConfig: containerSystemConfig,
            configDigestResolver: resolver
        )

        #expect(manifestMatch?.reference == manifest.reference)
        #expect(namedDigestMatch?.reference == nil)
        #expect(missingNamedDigest?.reference == nil)
    }

    @Test
    func testAsyncMatchAcceptsOnlyFullBareSHA256ConfigIDs() async throws {
        let image = Self.image(reference: "registry.local/example:latest", digest: String(repeating: "a", count: 64))
        let configDigest = "sha256:" + String(repeating: "c", count: 64)

        let short = try await ClientImage.match(
            reference: "sha256:" + String(repeating: "c", count: 12),
            in: [image],
            containerSystemConfig: containerSystemConfig,
            configDigestResolver: { _ in [configDigest] }
        )
        await #expect(throws: ContainerizationError.self) {
            try await ClientImage.match(
                reference: String(repeating: "c", count: 64),
                in: [image],
                containerSystemConfig: containerSystemConfig,
                configDigestResolver: { _ in [configDigest] }
            )
        }

        #expect(short?.reference == nil)
        #expect(!ClientImage.shouldPullAfterNotFound(reference: configDigest))
        #expect(ClientImage.shouldPullAfterNotFound(reference: "registry.local/example:latest"))
    }

    @Test
    func testConfigDigestResolverScansPlatformManifestsAndSkipsAttestations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let arm64 = Platform(arch: "arm64", os: "linux")
        let amd64 = Platform(arch: "amd64", os: "linux")
        let indexDigest = Self.digest("a")
        let armManifestDigest = Self.digest("b")
        let amdManifestDigest = Self.digest("c")
        let attestationDigest = Self.digest("d")
        let armConfigDigest = Self.digest("f")
        let amdConfigDigest = Self.digest("1")

        let armManifestData = try JSONEncoder().encode(Self.manifest(configDigest: armConfigDigest))
        let amdManifestData = try JSONEncoder().encode(Self.manifest(configDigest: amdConfigDigest))
        let attestationData = try JSONEncoder().encode(Self.manifest(configDigest: Self.digest("2")))
        let index = Index(manifests: [
            .init(mediaType: MediaTypes.imageManifest, digest: armManifestDigest, size: Int64(armManifestData.count), platform: arm64),
            .init(mediaType: MediaTypes.imageManifest, digest: amdManifestDigest, size: Int64(amdManifestData.count), platform: amd64),
            .init(
                mediaType: MediaTypes.imageManifest,
                digest: attestationDigest,
                size: Int64(attestationData.count),
                annotations: ["vnd.docker.reference.type": "attestation-manifest"]
            ),
        ])
        let indexData = try JSONEncoder().encode(index)
        let store = try FixtureContentStore(
            directory: directory,
            contents: [
                indexDigest: indexData,
                armManifestDigest: armManifestData,
                amdManifestDigest: amdManifestData,
                attestationDigest: attestationData,
            ])
        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.local/multiarch:latest",
                descriptor: .init(mediaType: MediaTypes.index, digest: indexDigest, size: Int64(indexData.count))
            ),
            contentStore: store
        )

        #expect(try await image.configDigests() == [armConfigDigest, amdConfigDigest])
    }

    @Test
    func testConfigDigestResolverRejectsMissingPlatformManifestContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let indexDigest = Self.digest("a")
        let missingManifestDigest = Self.digest("b")
        let index = Index(manifests: [
            .init(
                mediaType: MediaTypes.imageManifest,
                digest: missingManifestDigest,
                size: 1,
                platform: Platform(arch: "arm64", os: "linux")
            )
        ])
        let indexData = try JSONEncoder().encode(index)
        let store = try FixtureContentStore(directory: directory, contents: [indexDigest: indexData])
        let image = ClientImage(
            description: ImageDescription(
                reference: "registry.local/missing:latest",
                descriptor: .init(mediaType: MediaTypes.index, digest: indexDigest, size: Int64(indexData.count))
            ),
            contentStore: store
        )

        await #expect(throws: ContainerizationError.self) {
            try await image.configDigests()
        }
    }

    private static func image(reference: String, digest: String, annotations: [String: String]? = nil) -> ClientImage {
        let descriptor = Descriptor(mediaType: MediaTypes.index, digest: "sha256:\(digest)", size: 0, annotations: annotations)
        let description = ImageDescription(reference: reference, descriptor: descriptor)
        return ClientImage(description: description)
    }

    private static func digest(_ suffix: String) -> String {
        "sha256:" + String(repeating: suffix, count: 64)
    }

    private static func manifest(configDigest: String) -> Manifest {
        Manifest(
            config: .init(mediaType: MediaTypes.imageConfig, digest: configDigest, size: 1),
            layers: []
        )
    }
}

private enum TestResolverError: Error {
    case corrupt
}

private actor ResolverCallCounter {
    private var digests: [String] = []

    func record(_ digest: String) {
        digests.append(digest)
    }

    func recordedCount() -> Int {
        digests.count
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

    func delete(digests: [String]) async throws -> ([String], UInt64) { ([], 0) }
    func delete(keeping: [String]) async throws -> ([String], UInt64) { ([], 0) }

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
