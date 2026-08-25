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

import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

enum ConcurrentImageDiskUsageTotals {
    @concurrent
    static func run<Content: Sendable, Snapshots: Sendable>(
        content: @Sendable @escaping () async throws -> Content,
        snapshots: @Sendable @escaping () async throws -> Snapshots
    ) async throws -> (content: Content, snapshots: Snapshots) {
        async let contentSize = content()
        async let snapshotSize = snapshots()
        return try await (contentSize, snapshotSize)
    }
}

enum ConcurrentActiveImageDiskUsage {
    struct ImageUsage: Sendable {
        let contentDigests: [String]
        let snapshotSizes: [(digest: String, size: UInt64)]
    }

    struct Usage: Sendable {
        let contentSizes: [String: UInt64]
        let snapshotSizes: [String: UInt64]
    }

    private struct ContentUsage: Sendable {
        let digest: String
        let size: UInt64
    }

    private static let defaultMaximumConcurrentTasks = 8

    @concurrent
    static func run(
        images: [Containerization.Image],
        contentStore: ContentStore,
        snapshotStore: SnapshotStore
    ) async throws -> Usage {
        let imageUsage = try await boundedMap(images) { image in
            let contentDigests = try await image.referencedDigests()
            try Task.checkCancellation()
            let snapshotSizes = try await snapshotStore.getSnapshotSizes(for: image)
            return ImageUsage(contentDigests: contentDigests, snapshotSizes: snapshotSizes)
        }
        let references = reduce(imageUsage)
        let contentUsage = try await boundedMap(references.contentDigests.sorted()) { digest -> ContentUsage? in
            try Task.checkCancellation()
            guard let content: Content = try await contentStore.get(digest: digest) else {
                return nil
            }
            try Task.checkCancellation()
            return ContentUsage(digest: digest, size: try contentDiskSize(content))
        }

        return Usage(
            contentSizes: Dictionary(
                uniqueKeysWithValues: contentUsage.compactMap { usage in
                    usage.map { ($0.digest, $0.size) }
                }),
            snapshotSizes: references.snapshotSizes
        )
    }

    static func reduce(_ imageUsage: [ImageUsage]) -> (contentDigests: Set<String>, snapshotSizes: [String: UInt64]) {
        var contentDigests = Set<String>()
        var snapshotSizes: [String: UInt64] = [:]

        for usage in imageUsage {
            contentDigests.formUnion(usage.contentDigests)
            for snapshot in usage.snapshotSizes {
                snapshotSizes[snapshot.digest] = max(snapshotSizes[snapshot.digest] ?? 0, snapshot.size)
            }
        }
        return (contentDigests, snapshotSizes)
    }

    @concurrent
    static func boundedMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int = defaultMaximumConcurrentTasks,
        operation: @Sendable @escaping (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(maximumConcurrentTasks > 0)

        return try await withThrowingTaskGroup(of: Output.self) { group in
            var iterator = inputs.makeIterator()
            for _ in 0..<min(maximumConcurrentTasks, inputs.count) {
                guard let input = iterator.next() else { break }
                group.addTask {
                    try await operation(input)
                }
            }

            var output: [Output] = []
            output.reserveCapacity(inputs.count)
            while let result = try await group.next() {
                output.append(result)
                if let input = iterator.next() {
                    group.addTask {
                        try await operation(input)
                    }
                }
            }
            return output
        }
    }

    private static func contentDiskSize(_ content: Content) throws -> UInt64 {
        let values = try? content.path.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        if let allocatedSize = values?.totalFileAllocatedSize {
            return UInt64(allocatedSize)
        }
        return try content.size()
    }
}

public actor ImagesService {
    private let log: Logger
    private let contentStore: ContentStore
    private let imageStore: ImageStore
    private let snapshotStore: SnapshotStore

    public init(
        contentStore: ContentStore,
        imageStore: ImageStore,
        snapshotStore: SnapshotStore,
        log: Logger
    ) throws {
        self.contentStore = contentStore
        self.imageStore = imageStore
        self.snapshotStore = snapshotStore
        self.log = log
    }

    private func _list() async throws -> [Containerization.Image] {
        try await imageStore.list()
    }

    private func _get(_ reference: String) async throws -> Containerization.Image {
        try await imageStore.get(reference: reference)
    }

    private func _get(_ description: ImageDescription) async throws -> Containerization.Image {
        let exists = try await self._get(description.reference)
        guard exists.descriptor == description.descriptor else {
            throw ContainerizationError(.invalidState, message: "descriptor mismatch: expected \(description.descriptor), got \(exists.descriptor)")
        }
        return exists
    }

    public func list() async throws -> [ImageDescription] {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        return try await imageStore.list().map { $0.description.fromCZ }
    }

    public func pull(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?, maxConcurrentDownloads: Int = 3) async throws
        -> ImageDescription
    {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
                "maxConcurrentDownloads": "\(maxConcurrentDownloads)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.pull(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: ContainerizationProgressAdapter.handler(from: progressUpdate),
                maxConcurrentDownloads: maxConcurrentDownloads)
        }
        guard let img else {
            throw ContainerizationError(.internalError, message: "failed to pull image \(reference)")
        }
        return img.description.fromCZ
    }

    public func push(reference: String, platform: Platform?, insecure: Bool, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
                "platform": "\(String(describing: platform))",
                "insecure": "\(insecure)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        try await Self.withAuthentication(ref: reference) { auth in
            try await self.imageStore.push(
                reference: reference, platform: platform, insecure: insecure, auth: auth, progress: ContainerizationProgressAdapter.handler(from: progressUpdate))
        }
    }

    public func tag(old: String, new: String) async throws -> ImageDescription {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "old": "\(old)",
                "new": "\(new)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "old": "\(old)",
                    "new": "\(new)",
                ]
            )
        }

        let img = try await self.imageStore.tag(existing: old, new: new)
        return img.description.fromCZ
    }

    public func delete(reference: String, garbageCollect: Bool) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "ref": "\(reference)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "ref": "\(reference)",
                ]
            )
        }

        try await self.imageStore.delete(reference: reference, performCleanup: garbageCollect)
    }

    public func save(references: [String], out: URL, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(references)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(references)",
                ]
            )
        }

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await self.imageStore.save(references: references, out: tempDir, platform: platform)
        try await ConcurrentImageArchiveIO.writeDirectory(tempDir, to: out)
    }

    public func load(from tarFile: URL, force: Bool) async throws -> ([ImageDescription], [String]) {
        let archivePathname = tarFile.absolutePath()
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "archivePath": "\(archivePathname)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "archivePath": "\(archivePathname)",
                ]
            )
        }

        let tempDir = FileManager.default.uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let rejectedMembers = try await ConcurrentImageArchiveIO.extract(tarFile, to: tempDir)
        guard rejectedMembers.isEmpty || force else {
            throw ContainerizationError(.invalidArgument, message: "cannot load tar image with rejected paths: \(rejectedMembers)")
        }

        let loaded = try await self.imageStore.load(from: tempDir)
        var images: [ImageDescription] = []
        for image in loaded {
            images.append(image.description.fromCZ)
        }
        return (images, rejectedMembers)
    }

    public func cleanUpOrphanedBlobs() async throws -> ([String], UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let images = try await self._list()
        let freedSnapshotBytes = try await self.snapshotStore.clean(keepingSnapshotsFor: images)
        let (deleted, freedContentBytes) = try await self.imageStore.cleanUpOrphanedBlobs()
        return (deleted, freedContentBytes + freedSnapshotBytes)
    }

    /// Calculate disk usage for images
    /// - Parameter activeReferences: Set of image references currently in use by containers
    public func calculateDiskUsage(activeReferences: Set<String>) async throws -> (totalCount: Int, activeCount: Int, totalSize: UInt64, reclaimableSize: UInt64) {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "references": "\(activeReferences)",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "references": "\(activeReferences)",
                ]
            )
        }

        let images = try await self._list()
        let contentStore = self.contentStore
        let snapshotStore = self.snapshotStore
        async let diskTotals = ConcurrentImageDiskUsageTotals.run(
            content: {
                try await contentStore.totalAllocatedSize()
            },
            snapshots: {
                await snapshotStore.totalAllocatedSize()
            }
        )
        let activeImages = images.filter { activeReferences.contains($0.reference) }
        var uniqueActiveImages: [Containerization.Image] = []
        uniqueActiveImages.reserveCapacity(activeImages.count)
        var processedDigests = Set<String>()
        for image in activeImages {
            let imageDigest = image.digest.trimmingDigestPrefix
            if processedDigests.insert(imageDigest).inserted {
                uniqueActiveImages.append(image)
            }
        }
        async let activeDiskUsage = ConcurrentActiveImageDiskUsage.run(
            images: uniqueActiveImages,
            contentStore: contentStore,
            snapshotStore: snapshotStore
        )

        let (totals, activeUsage) = try await (diskTotals, activeDiskUsage)
        let totalOnDisk = totals.content + totals.snapshots
        let activeContentSize = activeUsage.contentSizes.values.reduce(0, +)
        let activeSnapshotSize = activeUsage.snapshotSizes.values.reduce(0, +)
        let activeSize = activeContentSize + activeSnapshotSize
        let reclaimable = totalOnDisk > activeSize ? totalOnDisk - activeSize : 0

        return (images.count, activeImages.count, totalOnDisk, reclaimable)
    }
}

// MARK: Image Snapshot Methods

extension ImagesService {
    public func unpack(description: ImageDescription, platform: Platform?, progressUpdate: ProgressUpdateHandler?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.unpack(image: img, platform: platform, progressUpdate: progressUpdate)
    }

    public func deleteImageSnapshot(description: ImageDescription, platform: Platform?) async throws {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        try await self.snapshotStore.delete(for: img, platform: platform)
    }

    public func getImageSnapshot(description: ImageDescription, platform: Platform) async throws -> Filesystem {
        self.log.debug(
            "ImagesService: enter",
            metadata: [
                "func": "\(#function)",
                "description": "\(description)",
                "platform": "\(String(describing: platform))",
            ]
        )
        defer {
            self.log.debug(
                "ImagesService: exit",
                metadata: [
                    "func": "\(#function)",
                    "description": "\(description)",
                    "platform": "\(String(describing: platform))",
                ]
            )
        }

        let img = try await self._get(description)
        return try await self.snapshotStore.get(for: img, platform: platform)
    }
}

// MARK: Static Methods

extension ImagesService {
    enum RegistryAuthenticationMode: Equatable {
        case environment
        case anonymous
        case keychain
    }

    private static func withAuthentication<T>(
        ref: String, _ body: @Sendable @escaping (_ auth: Authentication?) async throws -> T?
    ) async throws -> T? {
        var authentication: Authentication?
        let ref = try Reference.parse(ref)
        guard let host = ref.resolvedDomain else {
            throw ContainerizationError(.invalidArgument, message: "no host specified in image reference: \(ref)")
        }
        let environment = ProcessInfo.processInfo.environment
        switch Self.authenticationMode(host: host, environment: environment) {
        case .environment:
            authentication = Self.authenticationFromEnv(host: host, environment: environment)
            return try await body(authentication)
        case .anonymous:
            break
        case .keychain:
            let keychain = KeychainHelper(securityDomain: Constants.keychainID)
            do {
                authentication = try keychain.lookup(hostname: host)
            } catch let err as KeychainHelper.Error {
                guard case .keyNotFound = err else {
                    throw ContainerizationError(.internalError, message: "error querying keychain for \(host)", cause: err)
                }
            }
        }
        do {
            return try await body(authentication)
        } catch let err as RegistryClient.Error {
            guard case .invalidStatus(_, let status, _) = err else {
                throw err
            }
            guard status == .unauthorized || status == .forbidden else {
                throw err
            }
            guard authentication != nil else {
                throw ContainerizationError(.internalError, message: "\(String(describing: err)), no credentials found for host \(host)")
            }
            throw err
        }
    }

    static func authenticationMode(
        host: String,
        environment: [String: String]
    ) -> RegistryAuthenticationMode {
        if environment["CONTAINER_REGISTRY_HOST"] == host,
            environment["CONTAINER_REGISTRY_USER"] != nil,
            environment["CONTAINER_REGISTRY_TOKEN"] != nil
        {
            return .environment
        }

        let normalizedHost = host.lowercased()
        let anonymousHosts =
            environment["CONTAINER_REGISTRY_ANONYMOUS_HOSTS"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? []
        if anonymousHosts.contains(normalizedHost) {
            return .anonymous
        }
        return .keychain
    }

    private static func authenticationFromEnv(
        host: String,
        environment: [String: String]
    ) -> Authentication? {
        guard environment["CONTAINER_REGISTRY_HOST"] == host else {
            return nil
        }
        guard let user = environment["CONTAINER_REGISTRY_USER"],
            let password = environment["CONTAINER_REGISTRY_TOKEN"]
        else {
            return nil
        }
        return BasicAuthentication(username: user, password: password)
    }
}

extension ImageDescription {
    public var toCZ: Containerization.Image.Description {
        .init(reference: self.reference, descriptor: self.descriptor)
    }
}

extension Containerization.Image.Description {
    public var fromCZ: ImageDescription {
        .init(
            reference: self.reference,
            descriptor: self.descriptor
        )
    }
}
