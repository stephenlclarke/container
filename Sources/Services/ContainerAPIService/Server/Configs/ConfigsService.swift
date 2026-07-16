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
import ContainerizationExtras
import Foundation
import Logging
import SystemPackage

/// Stores immutable, non-secret configuration content and its metadata.
public actor ConfigsService {
    private static let contentFile = "content"

    private let resourceRoot: FilePath
    private let store: FilesystemEntityStore<ConfigConfiguration>
    private let log: Logger
    private let lock = AsyncLock()

    public init(resourceRoot: FilePath, log: Logger) throws {
        try FileManager.default.createDirectory(atPath: resourceRoot.string, withIntermediateDirectories: true)
        self.resourceRoot = resourceRoot
        store = try FilesystemEntityStore<ConfigConfiguration>(path: resourceRoot, type: "configs", log: log)
        self.log = log
    }

    public func create(
        name: String,
        contents: Data,
        labels: [String: String] = [:]
    ) async throws -> ConfigConfiguration {
        try await lock.withLock { _ in
            try await self._create(name: name, contents: contents, labels: labels)
        }
    }

    public func delete(name: String) async throws {
        try await lock.withLock { _ in
            try await self._delete(name: name)
        }
    }

    public func list() async throws -> [ConfigConfiguration] {
        try await store.list()
    }

    public func inspect(_ name: String) async throws -> ConfigConfiguration {
        guard ConfigStorage.isValidConfigName(name) else {
            throw ConfigError.invalidConfigName("invalid config name '\(name)': must match \(ConfigStorage.configNamePattern)")
        }
        guard let configuration = try await store.retrieve(name) else {
            throw ConfigError.configNotFound(name)
        }
        return configuration
    }

    public func read(name: String) async throws -> Data {
        _ = try await inspect(name)
        do {
            return try Data(contentsOf: try contentURL(for: name))
        } catch {
            throw ConfigError.storageError("failed to read config '\(name)': \(error.localizedDescription)")
        }
    }

    static func configPath(root: URL, name: String) throws -> URL {
        guard ConfigStorage.isValidConfigName(name), let component = FilePath.Component(name), case .regular = component.kind else {
            throw ConfigError.invalidConfigName("invalid config name '\(name)': must match \(ConfigStorage.configNamePattern)")
        }
        return root.appendingPathComponent(component.string, isDirectory: true)
    }

    private func _create(
        name: String,
        contents: Data,
        labels: [String: String]
    ) async throws -> ConfigConfiguration {
        guard ConfigStorage.isValidConfigName(name) else {
            throw ConfigError.invalidConfigName("invalid config name '\(name)': must match \(ConfigStorage.configNamePattern)")
        }
        guard try await store.retrieve(name) == nil else {
            throw ConfigError.configAlreadyExists(name)
        }

        let configuration = ConfigConfiguration(name: name, labels: labels, sizeInBytes: UInt64(contents.count))
        try await store.create(configuration)

        do {
            try contents.write(to: try contentURL(for: name), options: .atomic)
        } catch {
            try? await store.delete(name)
            throw ConfigError.storageError("failed to persist config '\(name)': \(error.localizedDescription)")
        }

        log.info("created config", metadata: ["name": "\(name)", "sizeInBytes": "\(contents.count)"])
        return configuration
    }

    private func _delete(name: String) async throws {
        guard ConfigStorage.isValidConfigName(name) else {
            throw ConfigError.invalidConfigName("invalid config name '\(name)': must match \(ConfigStorage.configNamePattern)")
        }
        guard try await store.retrieve(name) != nil else {
            throw ConfigError.configNotFound(name)
        }
        try await store.delete(name)
        log.info("deleted config", metadata: ["name": "\(name)"])
    }

    private nonisolated func contentURL(for name: String) throws -> URL {
        try Self.configPath(root: URL(filePath: resourceRoot.string), name: name)
            .appendingPathComponent(Self.contentFile, isDirectory: false)
    }
}
