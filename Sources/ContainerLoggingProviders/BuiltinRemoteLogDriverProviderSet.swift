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
import NIOCore

public enum BuiltinRemoteLogDriverConfigurationError: Error, Equatable,
    Sendable
{
    case contextNotFound(String)
    case contextConflict(String)
    case contextDriverMismatch(expected: String, actual: String)
    case requestIdentityMismatch(String)
}

/// Ephemeral authority-to-provider configuration registry.
///
/// Resolved safe and protected options are converted into a typed driver
/// configuration by the authority immediately before start. This registry
/// retains that typed value only for the exact start request. It deliberately
/// has no persistence or generic option-map API, so protected option values
/// cannot enter the provider lifecycle ledger or ordinary configuration.
public actor BuiltinRemoteLogDriverConfigurationRegistry:
    SyslogConfigurationResolving, FluentdConfigurationResolving,
    GELFConfigurationResolving
{
    private enum Entry: Sendable {
        case syslog(
            request: LogDriverStartRequestV1,
            binding: SyslogConfigurationBinding
        )
        case fluentd(
            request: LogDriverStartRequestV1,
            binding: FluentdConfigurationBinding
        )
        case gelf(
            request: LogDriverStartRequestV1,
            binding: GELFConfigurationBinding
        )

        var request: LogDriverStartRequestV1 {
            switch self {
            case .syslog(let request, _), .fluentd(let request, _),
                .gelf(let request, _):
                request
            }
        }

        var driver: String {
            switch self {
            case .syslog: "syslog"
            case .fluentd: "fluentd"
            case .gelf: "gelf"
            }
        }
    }

    private var entries = [String: Entry]()

    public init() {}

    public func register(
        _ binding: SyslogConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.syslog(request: request, binding: binding))
    }

    public func register(
        _ binding: FluentdConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.fluentd(request: request, binding: binding))
    }

    public func register(
        _ binding: GELFConfigurationBinding,
        for request: LogDriverStartRequestV1
    ) throws {
        try register(.gelf(request: request, binding: binding))
    }

    /// Removes only the exact request identity. A stale cleanup cannot erase a
    /// later session which happens to reuse the same externally supplied ID.
    @discardableResult
    public func unregister(
        _ request: LogDriverStartRequestV1
    ) throws -> Bool {
        guard let entry = entries[request.sessionID] else {
            return false
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        }
        entries.removeValue(forKey: request.sessionID)
        return true
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> SyslogConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .syslog(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "syslog",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> FluentdConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .fluentd(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "fluentd",
                    actual: entry.driver
                )
        }
        return binding
    }

    public func configuration(
        for request: LogDriverStartRequestV1
    ) throws -> GELFConfigurationBinding {
        let entry = try exactEntry(for: request)
        guard case .gelf(_, let binding) = entry else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(
                    expected: "gelf",
                    actual: entry.driver
                )
        }
        return binding
    }

    package var registeredContextCount: Int {
        entries.count
    }

    private func register(_ entry: Entry) throws {
        let sessionID = entry.request.sessionID
        if let existing = entries[sessionID] {
            guard Self.isIdentical(existing, entry) else {
                throw
                    BuiltinRemoteLogDriverConfigurationError
                    .contextConflict(sessionID)
            }
            return
        }
        entries[sessionID] = entry
    }

    private func exactEntry(
        for request: LogDriverStartRequestV1
    ) throws -> Entry {
        guard let entry = entries[request.sessionID] else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .contextNotFound(request.sessionID)
        }
        guard entry.request == request else {
            throw
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        }
        return entry
    }

    private static func isIdentical(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs, rhs) {
        case (.syslog(let leftRequest, let left), .syslog(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        case (.fluentd(let leftRequest, let left), .fluentd(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        case (.gelf(let leftRequest, let left), .gelf(let rightRequest, let right)):
            leftRequest == rightRequest && left == right
        default:
            false
        }
    }
}

/// The maintained first-party remote provider generation installed as one
/// immutable production unit.
///
/// All transports share the caller-owned event-loop group. The authority
/// retains the configuration registry and registers one exact typed context
/// before invoking the lifecycle controller; providers cannot start from a
/// catalog lookup alone.
public struct BuiltinRemoteLogDriverProviderSet: Sendable {
    public let registry: LogDriverProviderRegistry
    public let configurations: BuiltinRemoteLogDriverConfigurationRegistry
    public let syslog: SyslogLogDriverProvider
    public let fluentd: FluentdLogDriverProvider
    public let gelf: GELFLogDriverProvider

    private init(
        registry: LogDriverProviderRegistry,
        configurations: BuiltinRemoteLogDriverConfigurationRegistry,
        syslog: SyslogLogDriverProvider,
        fluentd: FluentdLogDriverProvider,
        gelf: GELFLogDriverProvider
    ) {
        self.registry = registry
        self.configurations = configurations
        self.syslog = syslog
        self.fluentd = fluentd
        self.gelf = gelf
    }

    public static func install(
        eventLoopGroup: any EventLoopGroup,
        providerGeneration: UInt64 = 1,
        baseCatalog: LogDriverCatalog = BuiltinLogDriverDescriptors.current
    ) async throws -> Self {
        let configurations = BuiltinRemoteLogDriverConfigurationRegistry()
        let syslog = SyslogLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOSyslogTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let fluentd = FluentdLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOFluentdTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let gelf = GELFLogDriverProvider(
            providerGeneration: providerGeneration,
            configurationResolver: configurations,
            transportFactory: NIOGELFTransportFactory(
                eventLoopGroup: eventLoopGroup
            )
        )
        let registry = LogDriverProviderRegistry(baseCatalog: baseCatalog)
        try await registry.install(syslog)
        try await registry.install(fluentd)
        try await registry.install(gelf)
        return Self(
            registry: registry,
            configurations: configurations,
            syslog: syslog,
            fluentd: fluentd,
            gelf: gelf
        )
    }
}
