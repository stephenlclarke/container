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

import ContainerEngineLogging
import ContainerizationError
import ContainerResource
import Foundation

/// Projects the authority-owned volume controller onto the Docker Engine API.
/// It never opens a Docker-specific catalog or bypasses native driver
/// resolution, so a rejected driver cannot leave a public-only allocation.
public struct ContainerDockerVolumeBackend: DockerVolumeBackend, Sendable {
    typealias CreateVolume = @Sendable (
        _ name: String,
        _ driver: String,
        _ driverOptions: [String: String],
        _ labels: [String: String]
    ) async throws -> VolumeConfiguration

    private let createVolume: CreateVolume

    public init(volumes: VolumesService) {
        createVolume = { name, driver, driverOptions, labels in
            try await volumes.create(
                name: name,
                driver: driver,
                driverOpts: driverOptions,
                labels: labels
            )
        }
    }

    init(createVolume: @escaping CreateVolume) {
        self.createVolume = createVolume
    }

    public func createVolume(
        request: DockerVolumeCreateRequest
    ) async throws -> DockerVolumeCreateResult {
        do {
            let volume = try await createVolume(
                request.name,
                request.driver ?? "local",
                request.driverOptions ?? [:],
                request.labels ?? [:]
            )
            return DockerVolumeCreateResult(
                name: volume.name,
                driver: volume.driver,
                mountpoint: volume.source,
                createdAt: Self.createdAt(volume.creationDate),
                labels: volume.labels,
                options: volume.options
            )
        } catch {
            throw Self.map(error)
        }
    }

    private static func createdAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func map(_ error: any Error) -> DockerLoggingBackendError {
        if let error = error as? DockerLoggingBackendError {
            return error
        }
        if let error = error as? VolumeError {
            switch error {
            case let .driverNotSupported(driver):
                return .volumeDriverNotFound(driver)
            case .invalidVolumeName:
                return .invalidParameter(error.localizedDescription)
            case .volumeAlreadyExists, .volumeInUse:
                return .conflict(error.localizedDescription)
            case .volumeNotFound, .storageError:
                return .server(error.localizedDescription)
            }
        }
        if let error = error as? ContainerizationError {
            switch error.code {
            case .exists, .invalidState:
                return .conflict(error.message)
            case .invalidArgument, .unsupported:
                return .invalidParameter(error.message)
            default:
                return .server("volume operation failed")
            }
        }
        return .server("volume operation failed")
    }
}
