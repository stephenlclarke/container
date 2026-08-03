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

import Foundation
import NIOPosix
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct BuiltinRemoteLogDriverProviderSetTests {
    @Test func productionSetAtomicallyPublishesEveryMaintainedRemoteDriver() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let providers = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                providerGeneration: 7
            )
            let catalog = try await providers.registry.logDriverCatalog()

            #expect(
                Set(catalog.registeredNames) == [
                    "none", "json-file", "local", "syslog", "fluentd", "gelf",
                    "splunk",
                ])
            for driver in ["syslog", "fluentd", "gelf", "splunk"] {
                let descriptor = try #require(
                    catalog.descriptor(named: driver)
                )
                #expect(descriptor.providerGeneration == 7)
                #expect(descriptor.providerIdentity.kind == .native)
                #expect(descriptor.placement == .macOSHost)
                #expect(descriptor.trust == .signed)
            }
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test func configurationRegistryIsExactReplaySafeAndGenerationFenced() async throws {
        let registry = BuiltinRemoteLogDriverConfigurationRegistry()
        let request = try Self.request()
        let binding = try Self.syslogBinding(request: request)

        try await registry.register(binding, for: request)
        try await registry.register(binding, for: request)
        let resolved: SyslogConfigurationBinding = try await registry.configuration(
            for: request
        )
        #expect(resolved == binding)
        #expect(await registry.registeredContextCount == 1)

        let conflicting = try SyslogConfigurationBinding(
            semanticRequestDigest: binding.semanticRequestDigest,
            containerID: binding.containerID,
            leaseGeneration: binding.leaseGeneration,
            providerID: binding.providerID,
            providerGeneration: binding.providerGeneration,
            configuration: Self.syslogConfiguration(hostname: "changed")
        )
        await #expect(
            throws: BuiltinRemoteLogDriverConfigurationError.contextConflict(
                request.sessionID
            )
        ) {
            try await registry.register(conflicting, for: request)
        }

        let stale = try Self.request(providerGeneration: 8)
        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        ) {
            let _: SyslogConfigurationBinding = try await registry.configuration(
                for: stale
            )
        }
        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .requestIdentityMismatch(request.sessionID)
        ) {
            try await registry.unregister(stale)
        }
        #expect(try await registry.unregister(request))
        #expect(try await !registry.unregister(request))
    }

    @Test func configurationRegistryRejectsCrossDriverResolution() async throws {
        let registry = BuiltinRemoteLogDriverConfigurationRegistry()
        let request = try Self.request()
        try await registry.register(
            Self.syslogBinding(request: request),
            for: request
        )

        await #expect(
            throws:
                BuiltinRemoteLogDriverConfigurationError
                .contextDriverMismatch(expected: "fluentd", actual: "syslog")
        ) {
            let _: FluentdConfigurationBinding = try await registry.configuration(
                for: request
            )
        }
    }

    private static func request(
        providerGeneration: UInt64 = 7
    ) throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: 1,
            idempotencyKey: "start:container:1",
            semanticRequestDigest: "sha256:request",
            sessionID: "session-1",
            containerID: "container-1",
            leaseGeneration: 1,
            candidateProcessGeneration: 1,
            providerID: SyslogLogDriverContract.providerIdentity.id,
            providerGeneration: providerGeneration,
            candidateSandboxGeneration: nil
        )
    }

    private static func syslogBinding(
        request: LogDriverStartRequestV1
    ) throws -> SyslogConfigurationBinding {
        try SyslogConfigurationBinding(
            semanticRequestDigest: request.semanticRequestDigest,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            configuration: syslogConfiguration(hostname: "host")
        )
    }

    private static func syslogConfiguration(
        hostname: String
    ) throws -> SyslogDriverConfiguration {
        try SyslogDriverConfiguration(
            endpoint: .udp(
                SyslogNetworkAddress(host: "127.0.0.1", port: 514)
            ),
            facility: SyslogFacility(number: 1),
            format: .rfc5424,
            tag: Data("container".utf8),
            hostname: hostname,
            processID: 1,
            tls: nil,
            policy: .dockerCompatible
        )
    }
}
