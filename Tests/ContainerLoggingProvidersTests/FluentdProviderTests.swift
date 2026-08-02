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

struct FluentdProviderTests {
    @Test func descriptorPublishesCompleteMaintainedContract() {
        let descriptor = FluentdLogDriverContract.descriptor(
            providerGeneration: 9
        )

        #expect(descriptor.driver == "fluentd")
        #expect(
            descriptor.providerIdentity
                == FluentdLogDriverContract.providerIdentity
        )
        #expect(descriptor.providerGeneration == 9)
        #expect(descriptor.placement == .macOSHost)
        #expect(descriptor.trust == .signed)
        #expect(descriptor.acceptsUnknownOptions == false)
        #expect(descriptor.capabilities.nativeRead == false)
        #expect(descriptor.capabilities.supportsDualCache)
        #expect(descriptor.capabilities.requiresDeliverySession)
        #expect(
            Set(descriptor.options.map(\.name))
                == FluentdDriverConfiguration.knownOptionNames
        )
        #expect(
            descriptor.options.first {
                $0.name == "fluentd-max-retries"
            }?.valueKind == .string
        )
        #expect(
            descriptor.options.first {
                $0.name == "fluentd-async"
            }?.valueKind == .string
        )
        #expect(descriptor.createValidationProfile == .dockerFluentd29_2_1)
    }

    @Test func replayReconcileFenceAndCloseUseOneEffectReceipt() async throws {
        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let request = try fluentdStartRequest()
        let resolver = FixedFluentdConfigurationResolver(
            try fluentdBinding(for: request)
        )
        let provider = FluentdLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            chunkIDGenerator: FixedFluentdChunkIDGenerator(chunkID: "chunk"),
            clock: FluentdTestClock(),
            tokenGenerator: FixedFluentdTokenGenerator(
                bytes: Data(repeating: 0xa5, count: 32)
            )
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
            Issue.record("identical fluentd start did not reconcile")
        }

        let call = try fluentdSessionCall(
            request: request,
            token: first.receipt.effectTokenMaterial
        )
        #expect(try await provider.reconcileSession(call).observation == .active)
        let fenced = try await provider.fenceSession(call)
        #expect(fenced.observation == .writerFenced)
        #expect(fenced.writerFenceReceiptDigest?.hasPrefix("sha256:") == true)
        #expect(
            try await provider.fenceSession(call).writerFenceReceiptDigest
                == fenced.writerFenceReceiptDigest
        )

        #expect(try await provider.closeSession(call).observation == .closed)
        #expect(try await provider.reconcileSession(call).observation == .closed)
        #expect(await transport.closeCallCount == 1)
        #expect(try await provider.fenceSession(call).observation == .closed)
    }

    @Test func rejectsBindingTokenAndFenceSubstitutionBeforeEffects() async throws {
        let request = try fluentdStartRequest()
        let validBinding = try fluentdBinding(for: request)
        let invalidBinding = FluentdConfigurationBinding(
            semanticRequestDigest: "sha256:substituted",
            containerID: validBinding.containerID,
            leaseGeneration: validBinding.leaseGeneration,
            providerID: validBinding.providerID,
            providerGeneration: validBinding.providerGeneration,
            configuration: validBinding.configuration
        )
        let untouchedFactory = ScriptedFluentdTransportFactory([])
        let invalidProvider = FluentdLogDriverProvider(
            configurationResolver: FixedFluentdConfigurationResolver(
                invalidBinding
            ),
            transportFactory: untouchedFactory,
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1]))
        )
        await #expect(throws: FluentdProviderError.invalidProviderIdentity) {
            try await invalidProvider.start(request)
        }
        #expect(await untouchedFactory.connectCallCount == 0)

        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let provider = FluentdLogDriverProvider(
            configurationResolver: FixedFluentdConfigurationResolver(
                validBinding
            ),
            transportFactory: factory,
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1, 2, 3]))
        )
        let started = try await provider.start(request)
        let wrongToken = try fluentdSessionCall(
            request: request,
            token: LogDriverOpaqueEffectTokenV1(
                validating: Data([9, 9, 9])
            )
        )
        await #expect(throws: FluentdProviderError.invalidEffectToken) {
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
        await #expect(throws: FluentdProviderError.invalidSessionFence) {
            try await provider.closeSession(wrongFence)
        }
        #expect(await transport.closeCallCount == 0)
    }

    @Test func eagerConnectFailureIsAbsentAndIdenticalRetryCanPrepare() async throws {
        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([
            .failure(.connect),
            .transport(transport),
        ])
        let request = try fluentdStartRequest()
        let resolver = FixedFluentdConfigurationResolver(
            try fluentdBinding(for: request)
        )
        let provider = FluentdLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1]))
        )

        await #expect(throws: FluentdTestFailure.connect) {
            try await provider.start(request)
        }
        switch try await provider.reconcileStart(request) {
        case .absent: break
        default: Issue.record("failed eager connect left a fluentd effect")
        }

        _ = try await provider.start(request)
        #expect(await factory.connectCallCount == 2)
        #expect(await resolver.callCount == 2)
    }

    @Test func sameScopeConflictDoesNotOpenASecondConnection() async throws {
        let transport = RecordingFluentdTransport()
        let factory = ScriptedFluentdTransportFactory([.transport(transport)])
        let request = try fluentdStartRequest()
        let resolver = FixedFluentdConfigurationResolver(
            try fluentdBinding(for: request)
        )
        let provider = FluentdLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1]))
        )
        _ = try await provider.start(request)

        let conflict = try fluentdStartRequest(
            semanticRequestDigest: "sha256:changed",
            sessionID: "other-session"
        )
        await #expect(throws: FluentdProviderError.idempotencyConflict) {
            try await provider.start(conflict)
        }
        #expect(await factory.connectCallCount == 1)
        #expect(await resolver.callCount == 1)
    }

    @Test func terminalSessionsUseBoundedReplayTombstones() async throws {
        let transports = (0..<3).map { _ in RecordingFluentdTransport() }
        let factory = ScriptedFluentdTransportFactory(
            transports.map(FluentdTestConnectOutcome.transport)
        )
        let provider = FluentdLogDriverProvider(
            configurationResolver: EchoFluentdConfigurationResolver(),
            transportFactory: factory,
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1])),
            maximumReplayTombstones: 2
        )
        var requests = [LogDriverStartRequestV1]()

        for generation in 1...3 {
            let request = try fluentdStartRequest(
                operationGeneration: UInt64(generation),
                idempotencyKey: "start-key-\(generation)",
                semanticRequestDigest: "sha256:request-\(generation)",
                sessionID: "fluentd-session-\(generation)"
            )
            requests.append(request)
            let started = try await provider.start(request)
            let call = try fluentdSessionCall(
                request: request,
                token: started.receipt.effectTokenMaterial
            )
            #expect(try await provider.fenceSession(call).observation == .writerFenced)
        }

        #expect(await factory.connectCallCount == 3)
        switch try await provider.reconcileStart(requests[0]) {
        case .absent: break
        default: Issue.record("evicted fluentd tombstone remained replayable")
        }
        for request in requests.dropFirst() {
            switch try await provider.reconcileStart(request) {
            case .prepared(let replay):
                await #expect(throws: FluentdProviderError.transportClosed) {
                    try await replay.session.write(
                        fluentdRecord(payload: Data("late".utf8))
                    )
                }
            default:
                Issue.record("retained fluentd tombstone did not replay")
            }
        }
    }

    @Test func replaySessionCloseUpgradesTombstoneObservation() async throws {
        let request = try fluentdStartRequest()
        let provider = FluentdLogDriverProvider(
            configurationResolver: EchoFluentdConfigurationResolver(),
            transportFactory: ScriptedFluentdTransportFactory([
                .transport(RecordingFluentdTransport())
            ]),
            tokenGenerator: FixedFluentdTokenGenerator(bytes: Data([1]))
        )
        let started = try await provider.start(request)
        let call = try fluentdSessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        _ = try await provider.fenceSession(call)

        guard case .prepared(let replay) = try await provider.reconcileStart(request) else {
            Issue.record("terminal fluentd session did not replay")
            return
        }
        try await replay.session.close(deadline: ContinuousClock().now + .seconds(1))
        #expect(try await provider.reconcileSession(call).observation == .closed)
    }
}

private func fluentdStartRequest(
    operationGeneration: UInt64 = 1,
    idempotencyKey: String = "start-key",
    semanticRequestDigest: String = "sha256:request",
    sessionID: String = "fluentd-session"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: operationGeneration,
        idempotencyKey: idempotencyKey,
        semanticRequestDigest: semanticRequestDigest,
        sessionID: sessionID,
        containerID: "container-id",
        leaseGeneration: 3,
        candidateProcessGeneration: 4,
        providerID: FluentdLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: nil
    )
}

private func fluentdBinding(
    for request: LogDriverStartRequestV1
) throws -> FluentdConfigurationBinding {
    FluentdConfigurationBinding(
        semanticRequestDigest: request.semanticRequestDigest,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        configuration: try fluentdTestConfiguration(maximumRetries: 1)
    )
}

private func fluentdSessionCall(
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

private actor FixedFluentdConfigurationResolver: FluentdConfigurationResolving {
    let binding: FluentdConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: FluentdConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> FluentdConfigurationBinding {
        callCount += 1
        return binding
    }
}

private actor EchoFluentdConfigurationResolver: FluentdConfigurationResolving {
    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> FluentdConfigurationBinding {
        try fluentdBinding(for: request)
    }
}

private struct FixedFluentdTokenGenerator: FluentdEffectTokenGenerating {
    let bytes: Data

    func makeEffectToken() throws -> Data {
        bytes
    }
}
