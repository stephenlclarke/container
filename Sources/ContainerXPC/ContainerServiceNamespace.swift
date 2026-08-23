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

import CryptoKit
import Foundation

/// A coherent namespace for launchd labels and Mach services owned by one
/// Container runtime installation.
///
/// The default preserves the stock per-user service names. An explicitly set
/// namespace keeps a second local runtime from replacing services that belong
/// to the default installation or another isolated runtime.
public struct ContainerServiceNamespace: Equatable, Sendable {
    public static let environmentName = "CONTAINER_SERVICE_NAMESPACE"
    public static let defaultValue = "com.apple.container"
    public static let defaultEngineLaunchdLabel = "io.github.stephenlclarke.container.engine"

    private static let failClosedValue = "invalid.container.namespace"

    public let value: String

    public init(_ value: String) throws {
        guard value.utf8.count <= 192 else {
            throw Error.invalid(value)
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard
            !components.isEmpty,
            components.allSatisfy({ component in
                !component.isEmpty && component.unicodeScalars.allSatisfy(Self.isValidLabelScalar)
            })
        else {
            throw Error.invalid(value)
        }
        self.value = value
    }

    /// Resolves the namespace from an explicit environment snapshot.
    ///
    /// Callers that start or stop services must use this throwing entry point
    /// so a malformed override cannot fall back to the default installation.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try Self(environment[environmentName] ?? defaultValue)
    }

    /// Returns the process namespace without risking a malformed override
    /// selecting the default service installation.
    public static var current: Self {
        (try? resolve()) ?? Self(unchecked: failClosedValue)
    }

    public var servicePrefix: String {
        "\(value)."
    }

    /// Limits service enumeration to this exact namespace.
    ///
    /// The legacy `--prefix` escape hatch must never widen a stop or status
    /// operation beyond the namespace selected for this process.
    public func servicePrefix(requestedPrefix: String?) throws -> String {
        guard let requestedPrefix else {
            return servicePrefix
        }
        guard requestedPrefix == servicePrefix else {
            throw Error.mismatchedServicePrefix(
                expected: servicePrefix,
                actual: requestedPrefix
            )
        }
        return servicePrefix
    }

    public var apiServerIdentifier: String {
        serviceIdentifier("apiserver")
    }

    public var machineAPIServerIdentifier: String {
        serviceIdentifier("core.machine-apiserver")
    }

    public var imagesServiceIdentifier: String {
        serviceIdentifier("core.container-core-images")
    }

    public var runtimeServicePrefix: String {
        serviceIdentifier("runtime")
    }

    public var networkServicePrefix: String {
        serviceIdentifier("network")
    }

    public var engineLaunchdLabel: String {
        value == Self.defaultValue ? Self.defaultEngineLaunchdLabel : serviceIdentifier("engine")
    }

    /// Canonical public Docker-compatible socket owned by this service namespace.
    public func enginePublicSocketPath(effectiveUserID: UInt32) -> String {
        let directoryName =
            value == Self.defaultValue
            ? "container-engine-\(effectiveUserID)"
            : "container-engine-\(effectiveUserID)-\(socketDirectorySuffix)"
        return "/tmp/\(directoryName)/docker.sock"
    }

    /// A bounded, stable socket-directory suffix for a non-default namespace.
    public var socketDirectorySuffix: String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func serviceIdentifier(_ suffix: String) -> String {
        "\(value).\(suffix)"
    }

    private init(unchecked value: String) {
        self.value = value
    }

    private static func isValidLabelScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 95:
            return true
        default:
            return false
        }
    }
}

extension ContainerServiceNamespace {
    public enum Error: LocalizedError, Equatable, Sendable {
        case invalid(String)
        case mismatchedServicePrefix(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let value):
                "invalid \(ContainerServiceNamespace.environmentName) \"\(value)\": use dot-separated launchd-label components containing only letters, digits, '-', or '_'"
            case .mismatchedServicePrefix(let expected, let actual):
                "--prefix must match \(ContainerServiceNamespace.environmentName) (\(expected)), got \(actual)"
            }
        }
    }
}
