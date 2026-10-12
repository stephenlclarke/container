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

import Containerization
import ContainerizationError
import Darwin
import Foundation

public struct Bundle: Sendable {
    private static let initfsFilename = "initfs.ext4"
    private static let kernelFilename = "kernel.json"
    private static let kernelBinaryFilename = "kernel.bin"
    private static let containerRootFsBlockFilename = "rootfs.ext4"
    private static let containerRootFsFilename = "rootfs.json"

    static let containerConfigFilename = "config.json"

    /// The path to the bundle.
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public var bootlog: URL {
        self.path.appendingPathComponent("vminitd.log")
    }

    public var containerRootfsBlock: URL {
        self.path.appendingPathComponent(Self.containerRootFsBlockFilename)
    }

    private var containerRootfsConfig: URL {
        self.path.appendingPathComponent(Self.containerRootFsFilename)
    }

    public var containerRootfs: Filesystem {
        get throws {
            let data = try Data(contentsOf: containerRootfsConfig)
            let fs = try JSONDecoder().decode(Filesystem.self, from: data)
            return fs
        }
    }

    /// Return the initial filesystem for a sandbox.
    public var initialFilesystem: Filesystem {
        .block(
            format: "ext4",
            source: self.path.appendingPathComponent(Self.initfsFilename).path,
            destination: "/",
            options: ["ro"]
        )
    }

    public var kernel: Kernel {
        get throws {
            try load(path: self.path.appendingPathComponent(Self.kernelFilename))
        }
    }

    public var configuration: ContainerConfiguration {
        get throws {
            try load(path: self.path.appendingPathComponent(Self.containerConfigFilename))
        }
    }
}

extension Bundle {
    public static func create(
        path: URL,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        containerConfiguration: ContainerConfiguration? = nil,
        containerRootFilesystem: Filesystem? = nil,
        options: ContainerCreateOptions? = nil
    ) throws -> Bundle {
        try prepare(
            path: path, initialFilesystem: initialFilesystem, kernel: kernel,
            containerConfiguration: containerConfiguration,
            containerRootFilesystem: containerRootFilesystem, options: options,
            didPublish: { _ in }
        )
    }

    /// The configuration is the readiness marker consumed by RuntimeLinux.
    public var isPrepared: Bool {
        get throws {
            do {
                _ = try configuration
                let kernel = try self.kernel
                guard kernel.path.standardizedFileURL == path.appendingPathComponent(Self.kernelBinaryFilename).standardizedFileURL,
                    Self.regularFileExists(kernel.path), Self.regularFileExists(URL(fileURLWithPath: initialFilesystem.source))
                else { return false }
                return try Self.filesystemExists(containerRootfs)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return false
            }
        }
    }

    /// Lifecycle serialization belongs to the caller. An interrupted attempt can
    /// replace only these unpublished resources; committed container state survives.
    static func prepare(
        path: URL, initialFilesystem: Filesystem, kernel: Kernel,
        containerConfiguration: ContainerConfiguration?, containerRootFilesystem: Filesystem?,
        options: ContainerCreateOptions?, didPublish: (String) throws -> Void
    ) throws -> Bundle {
        let bundle = Bundle(path: path)
        guard try !bundle.isPrepared else { throw POSIXError(.EEXIST) }
        // Legacy versions wrote config before rootfs preparation. Keep an already
        // materialized rootfs (and its copied data) when repairing other resources.
        let existingConfiguration = try? bundle.configuration
        let existingRootfs = try? bundle.containerRootfs
        let preserveRootfs = existingRootfs.map(Self.filesystemExists) ?? false
        if existingConfiguration != nil, existingRootfs == nil, Self.regularFileExists(bundle.containerRootfsBlock) {
            // Without its descriptor an old image may contain copied data. Do not
            // guess its provenance or erase it while repairing legacy readiness.
            throw POSIXError(.ENOTRECOVERABLE)
        }
        guard case .block(let format, _, _) = initialFilesystem.type, format == "ext4" else {
            throw POSIXError(.EINVAL)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        let stage = path.appendingPathComponent(".bundle-preparation", isDirectory: true)
        let resourceNames = [
            kernelBinaryFilename, kernelFilename, initfsFilename,
            containerRootFsBlockFilename, containerRootFsFilename, "options.json",
        ]
        // A fixed, private stage makes a crash retry bounded. Unknown contents
        // are never removed, nor are lifecycle, logging or runtime configuration.
        try removePreparationStage(stage, allowedNames: resourceNames)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? removePreparationStage(stage, allowedNames: resourceNames) }
        let staged = Bundle(path: stage)
        try fm.copyItem(at: kernel.path, to: stage.appendingPathComponent(kernelBinaryFilename))
        var finalKernel = kernel
        finalKernel.path = path.appendingPathComponent(kernelBinaryFilename)
        try JSONEncoder().encode(finalKernel).write(to: stage.appendingPathComponent(kernelFilename))
        _ = try initialFilesystem.clone(to: stage.appendingPathComponent(initfsFilename).path)

        if preserveRootfs {
            // Its descriptor and backing image already belong to this container.
        } else if let override = options?.rootFsOverride {
            try JSONEncoder().encode(override).write(to: staged.containerRootfsConfig)
        } else if let rootfs = containerRootFilesystem {
            var finalRootfs = try rootfs.clone(to: staged.containerRootfsBlock.path)
            // Metadata must name the final bundle, never the staging directory.
            finalRootfs.source = bundle.containerRootfsBlock.path
            if (existingConfiguration ?? containerConfiguration)?.readOnly == true, !finalRootfs.options.contains("ro") {
                finalRootfs.options.append("ro")
            }
            try JSONEncoder().encode(finalRootfs).write(to: staged.containerRootfsConfig)
        }
        if let options {
            try JSONEncoder().encode(options).write(to: stage.appendingPathComponent("options.json"))
        }
        try didPublish("staged")
        for name in resourceNames where fm.fileExists(atPath: stage.appendingPathComponent(name).path) {
            let source = stage.appendingPathComponent(name)
            try syncResource(source, directory: false)
            guard Darwin.rename(source.path, path.appendingPathComponent(name).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try didPublish(name)
        }
        try syncResource(path, directory: true)
        if let configuration = existingConfiguration ?? containerConfiguration {
            // No observer can mistake a partial preparation for a ready bundle.
            try bundle.setDurably(configuration: configuration)
        }
        return bundle
    }

    private static func regularFileExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
    }

    private static func filesystemExists(_ filesystem: Filesystem) -> Bool {
        switch filesystem.type {
        case .block, .volume:
            return regularFileExists(URL(fileURLWithPath: filesystem.source))
        case .virtiofs:
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: filesystem.source, isDirectory: &directory) && directory.boolValue
        case .tmpfs:
            return true
        }
    }

    private static func removePreparationStage(_ stage: URL, allowedNames: [String]) throws {
        var status = stat()
        if lstat(stage.path, &status) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            throw POSIXError(.EPERM)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        guard Set(names).isSubset(of: Set(allowedNames)) else { throw POSIXError(.EPERM) }
        for name in names {
            guard Darwin.unlink(stage.appendingPathComponent(name).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard Darwin.rmdir(stage.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func syncResource(_ path: URL, directory: Bool) throws {
        let fd = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

extension Bundle {
    /// Set the value of the configuration for the Bundle.
    public func set(configuration: ContainerConfiguration) throws {
        try write(filename: Self.containerConfigFilename, value: configuration)
    }

    /// Atomically publishes and fsyncs a configuration transaction before
    /// returning. Provider-generation migration uses this stronger boundary
    /// so registry activation cannot outrun durable container ownership.
    public func setDurably(configuration: ContainerConfiguration) throws {
        try Self.writeDurably(
            path.appendingPathComponent(Self.containerConfigFilename),
            value: configuration
        )
    }

    /// Atomically publishes and fsyncs a named bundle resource.
    public func writeDurably(filename: String, value: Encodable) throws {
        try Self.writeDurably(path.appendingPathComponent(filename), value: value)
    }

    /// Return the full filepath for a named resource in the Bundle.
    public func filePath(for name: String) -> URL {
        path.appendingPathComponent(name)
    }

    public func setContainerRootFs(fs: Filesystem) throws {
        let fsData = try JSONEncoder().encode(fs)
        try fsData.write(to: self.containerRootfsConfig, options: .atomic)
    }

    public func cloneContainerRootFs(cloning fs: Filesystem, readonly: Bool = false) throws {
        var mutableFs = fs
        if readonly && !mutableFs.options.contains("ro") {
            mutableFs.options.append("ro")
        }
        let cloned = try mutableFs.clone(to: self.containerRootfsBlock.absolutePath())
        try setContainerRootFs(fs: cloned)
    }

    /// Delete the bundle and all of the resources contained inside.
    public func delete() throws {
        try FileManager.default.removeItem(at: self.path)
    }

    public func write(filename: String, value: Encodable) throws {
        try Self.write(self.path.appendingPathComponent(filename), value: value)
    }

    private static func write(_ path: URL, value: Encodable) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: path, options: .atomic)
    }

    private static func writeDurably(_ path: URL, value: Encodable) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: path, options: .atomic)

        let fileDescriptor = Darwin.open(
            path.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fileDescriptor) }
        var status = stat()
        guard
            Darwin.fstat(fileDescriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            Darwin.fsync(fileDescriptor) == 0
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let directoryDescriptor = Darwin.open(
            path.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func load<T>(filename: String) throws -> T where T: Decodable {
        try load(path: self.path.appendingPathComponent(filename))
    }

    private func load<T>(path: URL) throws -> T where T: Decodable {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
