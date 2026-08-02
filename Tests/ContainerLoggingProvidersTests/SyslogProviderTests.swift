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
import Testing

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct SyslogProviderTests {
    @Test func descriptorPublishesTheCompleteFirstPartyContract() {
        let descriptor = SyslogLogDriverContract.descriptor(providerGeneration: 7)

        #expect(descriptor.driver == "syslog")
        #expect(descriptor.providerIdentity == SyslogLogDriverContract.providerIdentity)
        #expect(descriptor.providerGeneration == 7)
        #expect(descriptor.placement == .macOSHost)
        #expect(descriptor.trust == .signed)
        #expect(descriptor.acceptsUnknownOptions == false)
        #expect(descriptor.capabilities.nativeRead == false)
        #expect(descriptor.capabilities.supportsDualCache == true)
        #expect(descriptor.capabilities.requiresDeliverySession == true)
        #expect(Set(descriptor.options.map(\.name)) == SyslogDriverConfiguration.knownOptionNames)
        #expect(
            descriptor.options.first(where: { $0.name == "syslog-tls-key" })?.isSecret
                == true
        )
        #expect(
            descriptor.options.first(where: { $0.name == "syslog-tls-skip-verify" })?.valueKind
                == .string
        )
        for name in [
            "cache-compress", "cache-max-file", "cache-max-size", "env", "env-regex", "labels",
            "labels-regex",
        ] {
            #expect(
                descriptor.options.first(where: { $0.name == name })?.valueKind
                    == .string
            )
        }
    }

    @Test func startReplayReconcileFenceAndCloseUseOneGenerationFencedEffect() async throws {
        let transport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([.transport(transport)])
        let request = try syslogStartRequest()
        let resolver = FixedSyslogConfigurationResolver(
            try syslogBinding(for: request)
        )
        let provider = SyslogLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            clock: SyslogTestClock(),
            tokenGenerator: FixedSyslogTokenGenerator(bytes: Data(repeating: 0xa5, count: 32))
        )

        let first = try await provider.start(request)
        let replay = try await provider.start(request)
        #expect(
            first.receipt.effectTokenMaterial.isByteIdentical(
                to: replay.receipt.effectTokenMaterial
            )
        )
        #expect(await resolver.callCount == 1)
        #expect(await factory.connectCallCount == 1)

        switch try await provider.reconcileStart(request) {
        case .prepared(let reconciled):
            #expect(
                first.receipt.effectTokenMaterial.isByteIdentical(
                    to: reconciled.receipt.effectTokenMaterial
                )
            )
        default:
            Issue.record("identical start did not reconcile as prepared")
        }

        let call = try syslogSessionCall(
            request: request,
            token: first.receipt.effectTokenMaterial
        )
        #expect(try await provider.reconcileSession(call).observation == .active)

        let fenced = try await provider.fenceSession(call)
        #expect(fenced.observation == .writerFenced)
        #expect(fenced.writerFenceReceiptDigest?.hasPrefix("sha256:") == true)
        let repeatedFence = try await provider.fenceSession(call)
        #expect(repeatedFence.writerFenceReceiptDigest == fenced.writerFenceReceiptDigest)

        let closed = try await provider.closeSession(call)
        #expect(closed.observation == .closed)
        #expect(try await provider.reconcileSession(call).observation == .closed)
        #expect(await transport.closeCallCount == 1)

        // A closed effect is never downgraded back to a fence observation.
        #expect(try await provider.fenceSession(call).observation == .closed)
    }

    @Test func rejectsEveryBindingSubstitutionBeforeOpeningATransport() async throws {
        let request = try syslogStartRequest()
        let valid = try syslogBinding(for: request)
        let substitutions = [
            SyslogConfigurationBinding(
                semanticRequestDigest: "sha256:substituted",
                containerID: valid.containerID,
                leaseGeneration: valid.leaseGeneration,
                providerID: valid.providerID,
                providerGeneration: valid.providerGeneration,
                configuration: valid.configuration
            ),
            SyslogConfigurationBinding(
                semanticRequestDigest: valid.semanticRequestDigest,
                containerID: "other-container",
                leaseGeneration: valid.leaseGeneration,
                providerID: valid.providerID,
                providerGeneration: valid.providerGeneration,
                configuration: valid.configuration
            ),
            SyslogConfigurationBinding(
                semanticRequestDigest: valid.semanticRequestDigest,
                containerID: valid.containerID,
                leaseGeneration: valid.leaseGeneration + 1,
                providerID: valid.providerID,
                providerGeneration: valid.providerGeneration,
                configuration: valid.configuration
            ),
            SyslogConfigurationBinding(
                semanticRequestDigest: valid.semanticRequestDigest,
                containerID: valid.containerID,
                leaseGeneration: valid.leaseGeneration,
                providerID: "other-provider",
                providerGeneration: valid.providerGeneration,
                configuration: valid.configuration
            ),
            SyslogConfigurationBinding(
                semanticRequestDigest: valid.semanticRequestDigest,
                containerID: valid.containerID,
                leaseGeneration: valid.leaseGeneration,
                providerID: valid.providerID,
                providerGeneration: valid.providerGeneration + 1,
                configuration: valid.configuration
            ),
        ]

        for binding in substitutions {
            let factory = ScriptedSyslogTransportFactory([])
            let provider = SyslogLogDriverProvider(
                configurationResolver: FixedSyslogConfigurationResolver(binding),
                transportFactory: factory,
                tokenGenerator: FixedSyslogTokenGenerator(bytes: Data([1]))
            )
            await #expect(throws: SyslogProviderError.invalidProviderIdentity) {
                try await provider.start(request)
            }
            #expect(await factory.connectCallCount == 0)
        }
    }

    @Test func rejectsWrongProviderTokenAndGenerationWithoutMutatingTheSession() async throws {
        let transport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([.transport(transport)])
        let request = try syslogStartRequest()
        let resolver = FixedSyslogConfigurationResolver(try syslogBinding(for: request))
        let provider = SyslogLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedSyslogTokenGenerator(bytes: Data([1, 2, 3]))
        )
        let started = try await provider.start(request)

        let wrongToken = try syslogSessionCall(
            request: request,
            token: LogDriverOpaqueEffectTokenV1(validating: Data([9, 9, 9]))
        )
        await #expect(throws: SyslogProviderError.invalidEffectToken) {
            try await provider.closeSession(wrongToken)
        }

        let wrongFence = try LogDriverSessionCallV1(
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            providerID: request.providerID,
            providerGeneration: request.providerGeneration,
            fence: LogDriverSessionFenceV1(
                activeProcessGeneration: request.candidateProcessGeneration + 1,
                sandboxGeneration: nil
            ),
            effectTokenMaterial: started.receipt.effectTokenMaterial
        )
        await #expect(throws: SyslogProviderError.invalidSessionFence) {
            try await provider.closeSession(wrongFence)
        }

        let valid = try syslogSessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        #expect(try await provider.reconcileSession(valid).observation == .active)
        #expect(await transport.closeCallCount == 0)
    }

    @Test func rejectsIdempotencyConflictsAndSessionIDReuseWithoutLeakingEffects() async throws {
        let firstTransport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([.transport(firstTransport)])
        let request = try syslogStartRequest()
        let resolver = FixedSyslogConfigurationResolver(try syslogBinding(for: request))
        let provider = SyslogLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedSyslogTokenGenerator(bytes: Data([1]))
        )
        _ = try await provider.start(request)

        let sameScopeConflict = try syslogStartRequest(
            semanticRequestDigest: "sha256:changed",
            sessionID: "other-session"
        )
        await #expect(throws: SyslogProviderError.idempotencyConflict) {
            try await provider.start(sameScopeConflict)
        }

        let reusedSessionID = try syslogStartRequest(
            operationGeneration: 2,
            idempotencyKey: "other-operation",
            sessionID: request.sessionID
        )
        await #expect(throws: SyslogProviderError.idempotencyConflict) {
            try await provider.start(reusedSessionID)
        }

        #expect(await factory.connectCallCount == 1)
        #expect(await resolver.callCount == 1)
        #expect(await firstTransport.closeCallCount == 0)
    }

    @Test func failedEagerConnectLeavesStartAbsentAndAllowsAnIdenticalRetry() async throws {
        let transport = RecordingSyslogTransport()
        let factory = ScriptedSyslogTransportFactory([
            .failure(.connect),
            .transport(transport),
        ])
        let request = try syslogStartRequest()
        let resolver = FixedSyslogConfigurationResolver(try syslogBinding(for: request))
        let provider = SyslogLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedSyslogTokenGenerator(bytes: Data([1]))
        )

        await #expect(throws: SyslogTestFailure.connect) {
            try await provider.start(request)
        }
        switch try await provider.reconcileStart(request) {
        case .absent: break
        default: Issue.record("failed connect unexpectedly left a prepared start")
        }

        _ = try await provider.start(request)
        #expect(await factory.connectCallCount == 2)
        #expect(await resolver.callCount == 2)
    }
}

private func syslogStartRequest(
    operationGeneration: UInt64 = 1,
    idempotencyKey: String = "start-key",
    semanticRequestDigest: String = "sha256:request",
    sessionID: String = "syslog-session"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: operationGeneration,
        idempotencyKey: idempotencyKey,
        semanticRequestDigest: semanticRequestDigest,
        sessionID: sessionID,
        containerID: "container-id",
        leaseGeneration: 3,
        candidateProcessGeneration: 4,
        providerID: SyslogLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: nil
    )
}

private func syslogBinding(
    for request: LogDriverStartRequestV1
) throws -> SyslogConfigurationBinding {
    SyslogConfigurationBinding(
        semanticRequestDigest: request.semanticRequestDigest,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        configuration: try syslogTestConfiguration()
    )
}

private func syslogSessionCall(
    request: LogDriverStartRequestV1,
    token: LogDriverOpaqueEffectTokenV1
) throws -> LogDriverSessionCallV1 {
    try LogDriverSessionCallV1(
        sessionID: request.sessionID,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        fence: LogDriverSessionFenceV1(
            activeProcessGeneration: request.candidateProcessGeneration,
            sandboxGeneration: request.candidateSandboxGeneration
        ),
        effectTokenMaterial: token
    )
}

private actor FixedSyslogConfigurationResolver: SyslogConfigurationResolving {
    let binding: SyslogConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: SyslogConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> SyslogConfigurationBinding {
        callCount += 1
        return binding
    }
}

private struct FixedSyslogTokenGenerator: SyslogEffectTokenGenerating {
    let bytes: Data

    func makeEffectToken() throws -> Data {
        bytes
    }
}
