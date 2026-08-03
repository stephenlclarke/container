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

import ContainerResource
import Containerization
import ContainerizationError
import Foundation

/// Durable launch configuration for the single Engine-owned Linux sandbox.
public struct EngineLinuxSandboxRuntimeConfigurationV1: Codable, Sendable {
    public static let filename = "engine-linux-sandbox-configuration-v1.json"

    public let path: URL
    public let sandboxID: String
    public let initialFilesystem: Filesystem
    public let kernel: Kernel
    public let cpus: Int
    public let memoryInBytes: UInt64
    public let nestedVirtualization: Bool
    public let rosetta: Bool

    public init(
        path: URL,
        sandboxID: String,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        cpus: Int,
        memoryInBytes: UInt64,
        nestedVirtualization: Bool = false,
        rosetta: Bool = false
    ) {
        self.path = path
        self.sandboxID = sandboxID
        self.initialFilesystem = initialFilesystem
        self.kernel = kernel
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.nestedVirtualization = nestedVirtualization
        self.rosetta = rosetta
    }

    public var configurationURL: URL {
        path.appendingPathComponent(Self.filename)
    }

    public func write() throws {
        try validate()
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    public static func read(from path: URL) throws -> Self {
        let url = path.appendingPathComponent(filename)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ContainerizationError(
                .notFound,
                message: "Engine Linux sandbox configuration not found at \(url.path)",
                cause: error
            )
        }
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        try configuration.validate(expectedPath: path)
        return configuration
    }

    public func validate(expectedPath: URL? = nil) throws {
        guard path.isFileURL, !sandboxID.isEmpty, sandboxID.utf8.count <= 64 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Engine Linux sandbox path or identifier"
            )
        }
        if let expectedPath {
            let configuredPath = path.resolvingSymlinksInPath().standardizedFileURL.path
            let launchPath = expectedPath.resolvingSymlinksInPath().standardizedFileURL.path
            guard configuredPath == launchPath else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Engine Linux sandbox configuration path \(configuredPath) does not match launch root \(launchPath)"
                )
            }
        }
        guard cpus > 0, memoryInBytes > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Engine Linux sandbox capacity must be positive"
            )
        }
    }
}
