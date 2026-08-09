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
import ContainerEngineLogging
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension ContainerDockerLoggingBackend: DockerImageMutationBackend {
    public func pullImage(
        request: DockerImagePullRequest
    ) async throws -> DockerImagePullResult {
        do {
            return try await imagePullProvider(request)
        } catch {
            throw Self.mapImage(error, name: request.fromImage)
        }
    }

    public func tagImage(
        name: String,
        request: DockerImageTagRequest
    ) async throws {
        do {
            try await imageTagProvider(name, request)
        } catch {
            throw Self.mapImage(error, name: name)
        }
    }

    public func deleteImage(
        name: String,
        request: DockerImageDeleteRequest
    ) async throws -> [DockerImageDeleteResult] {
        do {
            return try await imageDeleteProvider(name, request)
        } catch {
            throw Self.mapImage(error, name: name)
        }
    }

    static func pullImage(
        request: DockerImagePullRequest,
        containerSystemConfig: ContainerSystemConfig
    ) async throws -> DockerImagePullResult {
        try validatePublicRegistryAuth(request.registryAuth)
        let sourceReference =
            request.tag.map {
                "\(request.fromImage):\($0)"
            } ?? request.fromImage
        let normalized = try ClientImage.normalizeReference(
            sourceReference,
            containerSystemConfig: containerSystemConfig
        )
        let previousDigest = try await ClientImage.list()
            .first { $0.reference == normalized }?
            .digest
        let platform =
            try request.platform.map(Platform.init(from:))
            ?? Platform.current
        let image = try await ClientImage.pull(
            reference: sourceReference,
            platform: platform,
            containerSystemConfig: containerSystemConfig
        )
        try await image.unpack(platform: platform)
        return try DockerImagePullResult(
            displayReference: ClientImage.denormalizeReference(
                image.reference,
                containerSystemConfig: containerSystemConfig
            ),
            digest: image.digest,
            upToDate: previousDigest == image.digest
        )
    }

    static func tagImage(
        name: String,
        request: DockerImageTagRequest,
        containerSystemConfig: ContainerSystemConfig
    ) async throws {
        let image = try await ClientImage.get(
            reference: name,
            containerSystemConfig: containerSystemConfig
        )
        let target = try ClientImage.normalizeReference(
            "\(request.repository):\(request.tag)",
            containerSystemConfig: containerSystemConfig
        )
        try await image.tag(new: target)
    }

    static func deleteImage(
        name: String,
        request: DockerImageDeleteRequest,
        containerSystemConfig: ContainerSystemConfig
    ) async throws -> [DockerImageDeleteResult] {
        let selected = try await ClientImage.get(
            reference: name,
            containerSystemConfig: containerSystemConfig
        )
        let images = try await ClientImage.list()

        let digestMatches = images.filter { $0.digest == selected.digest }
        let removesByDigest = isDigestSelector(name)
        if removesByDigest, digestMatches.count > 1, !request.force {
            let shortDigest = selected.digest
                .replacingOccurrences(of: "sha256:", with: "")
                .prefix(12)
            throw DockerLoggingBackendError.conflict(
                "conflict: unable to delete \(shortDigest) (must be forced) - image is referenced in multiple repositories"
            )
        }

        let removed =
            removesByDigest && request.force
            ? digestMatches
            : [selected]
        var results = [DockerImageDeleteResult]()
        for image in removed {
            try await ClientImage.delete(
                reference: image.reference,
                garbageCollect: request.prune
            )
            try results.append(
                DockerImageDeleteResult(
                    untagged: ClientImage.denormalizeReference(
                        image.reference,
                        containerSystemConfig: containerSystemConfig
                    )
                )
            )
        }
        if removed.count == digestMatches.count {
            results.append(DockerImageDeleteResult(deleted: selected.digest))
        }
        return results
    }

    static func validatePublicRegistryAuth(_ encoded: String?) throws {
        guard let encoded, !encoded.isEmpty else {
            return
        }
        guard
            let data = Data(base64Encoded: encoded),
            let object = try? JSONSerialization.jsonObject(with: data),
            let values = object as? [String: Any]
        else {
            throw DockerLoggingBackendError.invalidParameter(
                "invalid X-Registry-Auth header"
            )
        }
        let credentialKeys = [
            "auth", "identitytoken", "password", "registrytoken", "username",
        ]
        let hasCredentials = credentialKeys.contains { key in
            guard let value = values[key] as? String else {
                return false
            }
            return !value.isEmpty
        }
        if hasCredentials {
            throw DockerLoggingBackendError.invalidParameter(
                "registry authentication is not implemented by the selected provider"
            )
        }
    }

    static func isDigestSelector(_ value: String) -> Bool {
        let candidate: Substring
        if value.hasPrefix("sha256:") {
            candidate = value.dropFirst("sha256:".count)
        } else {
            candidate = value[...]
        }
        return candidate.count >= 12 && candidate.allSatisfy(\.isHexDigit)
    }

    static func mapImage(
        _ error: any Error,
        name: String
    ) -> DockerLoggingBackendError {
        if let error = error as? DockerLoggingBackendError {
            return error
        }
        if let error = error as? ContainerizationError {
            switch error.code {
            case .notFound:
                return .imageNotFound(name)
            case .exists, .invalidState:
                return .conflict(error.message)
            case .invalidArgument, .unsupported:
                return .invalidParameter(error.message)
            default:
                return .server("image operation failed")
            }
        }
        return .server("image operation failed")
    }
}
