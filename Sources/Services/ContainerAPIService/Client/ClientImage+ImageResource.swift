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
import ContainerizationOCI
import Foundation

extension ClientImage {
    /// Resolves, from the content store, the index descriptor and per-variant
    /// manifest content needed to build an ``ImageResource``.
    ///
    /// Manifests without a platform, or whose config/manifest cannot be
    /// fetched, are skipped.
    public func toImageResource(containerSystemConfig: ContainerSystemConfig) async throws -> ImageResource {
        var variants: [ImageResource.Variant] = []
        var earliest: Date?

        for desc in try await self.index().manifests {
            guard let platform = desc.platform else {
                continue
            }
            let config: ContainerizationOCI.Image
            let manifest: ContainerizationOCI.Manifest
            let healthCheck: ImageResource.HealthCheck?
            do {
                manifest = try await self.manifest(for: platform)
                let content = try await self.configContent(from: manifest)
                config = try content.decode()
                healthCheck = Self.healthCheck(from: content)
            } catch {
                continue
            }
            let size =
                desc.size + manifest.config.size
                + manifest.layers.reduce(0) { $0 + $1.size }

            variants.append(
                .init(
                    platform: platform,
                    digest: desc.digest,
                    size: size,
                    config: config,
                    healthCheck: healthCheck
                )
            )

            // Use the earliest variant's creation timestamp as the image's date.
            if let date = config.created.flatMap(Self.parseCreated) {
                earliest = min(earliest ?? date, date)
            }
        }

        let created = earliest ?? Date(timeIntervalSince1970: 0)
        let displayName = try Self.denormalizeReference(self.description.reference, containerSystemConfig: containerSystemConfig)
        let configuration = ImageResource.ImageConfiguration(description: self.description, creationDate: created)
        return ImageResource(configuration: configuration, variants: variants, displayReference: displayName)
    }

    private static func parseCreated(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func healthCheck(from content: Content) -> ImageResource.HealthCheck? {
        guard let config: ImageConfigHealthCheck = try? content.decode() else {
            return nil
        }
        return config.config?.healthCheck
    }
}

private struct ImageConfigHealthCheck: Decodable {
    struct Config: Decodable {
        enum CodingKeys: String, CodingKey {
            case healthCheck = "Healthcheck"
        }

        let healthCheck: ImageResource.HealthCheck?
    }

    let config: Config?
}
