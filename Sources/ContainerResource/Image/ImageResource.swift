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

import ContainerizationOCI
import Foundation

/// An image resource, representing an OCI image managed by the system.
///
/// `ImageResource` conforms to `ManagedResource` and wraps the image's
/// ``ImageDescription`` (its reference and index descriptor) alongside the
/// resolved index descriptor and the per-platform variants that make up the
/// image.
public struct ImageResource: ManagedResource {
    /// Docker image healthcheck metadata stored in OCI image config.
    ///
    /// Docker encodes durations as nanoseconds in the image config JSON.
    public struct HealthCheck: Sendable, Codable, Equatable {
        enum CodingKeys: String, CodingKey {
            case test = "Test"
            case intervalInNanoseconds = "Interval"
            case timeoutInNanoseconds = "Timeout"
            case startPeriodInNanoseconds = "StartPeriod"
            case startIntervalInNanoseconds = "StartInterval"
            case retries = "Retries"
        }

        /// Probe command encoded by Docker as `NONE`, `CMD`, or `CMD-SHELL`.
        public let test: [String]?
        /// Delay between health probes, in nanoseconds.
        public let intervalInNanoseconds: Int64?
        /// Maximum probe runtime, in nanoseconds.
        public let timeoutInNanoseconds: Int64?
        /// Grace period before failures count, in nanoseconds.
        public let startPeriodInNanoseconds: Int64?
        /// Delay between probes during the start period, in nanoseconds.
        public let startIntervalInNanoseconds: Int64?
        /// Number of consecutive failures before the container is unhealthy.
        public let retries: Int?

        public init(
            test: [String]? = nil,
            intervalInNanoseconds: Int64? = nil,
            timeoutInNanoseconds: Int64? = nil,
            startPeriodInNanoseconds: Int64? = nil,
            startIntervalInNanoseconds: Int64? = nil,
            retries: Int? = nil
        ) {
            self.test = test
            self.intervalInNanoseconds = intervalInNanoseconds
            self.timeoutInNanoseconds = timeoutInNanoseconds
            self.startPeriodInNanoseconds = startPeriodInNanoseconds
            self.startIntervalInNanoseconds = startIntervalInNanoseconds
            self.retries = retries
        }
    }

    /// A single platform-specific variant of an image.
    public struct Variant: Sendable, Codable {
        /// The platform this variant targets.
        public let platform: Platform
        /// The digest of this variant's manifest.
        public let digest: String
        /// The total size of this variant in bytes.
        public let size: Int64
        /// The OCI image config for this variant.
        public let config: ContainerizationOCI.Image
        /// Optional healthcheck metadata inherited from the image config.
        public let healthCheck: HealthCheck?

        public init(
            platform: Platform,
            digest: String,
            size: Int64,
            config: ContainerizationOCI.Image,
            healthCheck: HealthCheck? = nil
        ) {
            self.platform = platform
            self.digest = digest
            self.size = size
            self.config = config
            self.healthCheck = healthCheck
        }

        /// Docker image config labels for this platform variant.
        public var imageConfigLabels: [String: String] {
            config.config?.labels ?? [:]
        }

        /// Docker image config exposed ports for this platform variant.
        public var exposedPorts: [String] {
            Array((config.config?.exposedPorts ?? [:]).keys).sorted()
        }
    }

    public struct ImageConfiguration: Sendable, Codable {
        public let creationDate: Date
        public var name: String
        public var descriptor: Descriptor

        public init(description: ImageDescription, creationDate: Date) {
            self.creationDate = creationDate
            self.name = description.reference
            self.descriptor = description.descriptor
        }
    }

    /// The image's description — its reference and index descriptor.
    public let configuration: ImageConfiguration

    /// The platform-specific variants contained in the image.
    public let variants: [Variant]

    /// The reference to show in human-facing listings, with default-registry
    /// information removed (e.g. `alpine` rather than `docker.io/library/alpine`).
    /// Computed by the caller, which has access to the system configuration.
    /// Defaults to the full ``name`` when not supplied.
    public let displayReference: String

    // MARK: ManagedResource

    /// The scheme-specific value of `configuration.descriptor.digest` (the hex portion
    /// after the algorithm prefix). The fully-qualified digest — needed for content-store
    /// lookups and XPC transport — is always recoverable as `configuration.descriptor.digest`.
    public var id: String {
        let digest = configuration.descriptor.digest
        guard let colonIndex = digest.firstIndex(of: ":") else { return digest }
        return String(digest[digest.index(after: colonIndex)...])
    }

    /// The user-facing reference (`name:tag`) for this image.
    public var name: String { configuration.name }

    /// The time at which the image was created, resolved from the OCI image
    /// config. Falls back to the Unix epoch when no creation date is recorded.
    public var creationDate: Date { configuration.creationDate }

    /// Key-value labels for this image, derived from the index descriptor's
    /// annotations. Returns an empty label set if the annotations fail
    /// ``ResourceLabels`` validation.
    public var labels: ResourceLabels {
        (try? ResourceLabels(configuration.descriptor.annotations ?? [:])) ?? ResourceLabels()
    }

    // MARK: Initialization
    public init(configuration: ImageConfiguration, variants: [Variant], displayReference: String? = nil) {
        self.configuration = configuration
        self.variants = variants
        self.displayReference = displayReference ?? configuration.name
    }
}

extension ImageResource {
    /// Returns `true` if `name` is a syntactically valid image reference.
    public static func nameValid(_ name: String) -> Bool {
        (try? Reference.parse(name)) != nil
    }
}

// MARK: - Codable

extension ImageResource {
    enum CodingKeys: String, CodingKey {
        case id
        case configuration
        case variants
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(variants, forKey: .variants)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.configuration = try container.decode(ImageConfiguration.self, forKey: .configuration)
        self.variants = try container.decode([Variant].self, forKey: .variants)
        // `displayReference` is a display-only value and is not serialized.
        self.displayReference = self.configuration.name
    }
}
