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
import Foundation

enum LoggingProtectedOptionsBindingError: Error, Equatable, Sendable {
    case incompleteConfiguration
}

/// Canonical authority context authenticated with one protected logging object.
///
/// The binding deliberately excludes the protected reference itself so it can
/// be derived before publication and reconstructed from durable configuration
/// at start. It includes every other frozen semantic field, including the
/// container owner, so a valid object/reference pair cannot be substituted
/// into another container or another logging lease.
struct LoggingProtectedOptionsBinding: Encodable, Equatable, Sendable {
    static let currentSchemaVersion: UInt32 = 1

    let schemaVersion: UInt32
    let containerID: String
    let leaseGeneration: UInt64
    let requestedDriver: String?
    let requestedSafeOptions: [String: String]
    let requestedProtectedOptionNames: [String]
    let resolvedDriver: String
    let resolvedSafeOptions: [String: String]
    let resolvedProtectedOptionNames: [String]
    let delivery: LogDeliveryConfiguration
    let readPolicy: LogReadPolicy
    let providerIdentity: LogDriverProviderIdentity
    let providerGeneration: UInt64
    let contractDigest: String

    init(
        containerID: String,
        prepared: PreparedContainerLogResolution,
        leaseGeneration: UInt64
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.containerID = containerID
        self.leaseGeneration = leaseGeneration
        self.requestedDriver = prepared.requestedDriver
        self.requestedSafeOptions = prepared.requestedSafeOptions
        self.requestedProtectedOptionNames = prepared.requestedProtectedOptionNames.sorted()
        self.resolvedDriver = prepared.descriptor.driver
        self.resolvedSafeOptions = prepared.safeOptions
        self.resolvedProtectedOptionNames = prepared.protectedOptions.names
        self.delivery = prepared.delivery
        self.readPolicy = prepared.readPolicy
        self.providerIdentity = prepared.descriptor.providerIdentity
        self.providerGeneration = prepared.descriptor.providerGeneration
        self.contractDigest = prepared.descriptor.optionContractDigest
    }

    init(containerID: String, configuration: ContainerLogConfiguration) throws {
        guard
            !configuration.isLegacy,
            let requested = configuration.requested,
            let resolved = configuration.resolved
        else {
            throw LoggingProtectedOptionsBindingError.incompleteConfiguration
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.containerID = containerID
        self.leaseGeneration = resolved.leaseGeneration
        self.requestedDriver = requested.driver
        self.requestedSafeOptions = requested.safeOptions
        self.requestedProtectedOptionNames = requested.protectedOptionNames.sorted()
        self.resolvedDriver = resolved.driver
        self.resolvedSafeOptions = resolved.safeOptions
        self.resolvedProtectedOptionNames = resolved.protectedOptionNames.sorted()
        self.delivery = resolved.delivery
        self.readPolicy = resolved.readPolicy
        self.providerIdentity = resolved.providerIdentity
        self.providerGeneration = resolved.providerGenerationAtResolution
        self.contractDigest = resolved.contractDigest
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
