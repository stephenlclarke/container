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

struct GELFProviderTests {
    @Test func replayReconcileFenceAndCloseUseOneEffectReceipt() async throws {
        let transport = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let request = try gelfStartRequest()
        let resolver = FixedGELFConfigurationResolver(
            try gelfBinding(for: request)
        )
        let provider = GELFLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            chunkIDGenerator: FixedGELFChunkIDGenerator(
                bytes: Data(repeating: 0xa5, count: 8)
            ),
            clock: GELFTestClock(),
            tokenGenerator: FixedGELFTokenGenerator(
                bytes: Data(repeating: 0x5a, count: 32)
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
            Issue.record("identical GELF start did not reconcile")
        }

        let call = try gelfSessionCall(
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

    @Test func rejectsBindingTokenFenceAndProviderSubstitutionBeforeEffects() async throws {
        let request = try gelfStartRequest()
        let validBinding = try gelfBinding(for: request)
        let invalidBinding = GELFConfigurationBinding(
            semanticRequestDigest: "sha256:substituted",
            containerID: validBinding.containerID,
            leaseGeneration: validBinding.leaseGeneration,
            providerID: validBinding.providerID,
            providerGeneration: validBinding.providerGeneration,
            configuration: validBinding.configuration
        )
        let untouchedFactory = ScriptedGELFTransportFactory([])
        let invalidProvider = GELFLogDriverProvider(
            configurationResolver: FixedGELFConfigurationResolver(invalidBinding),
            transportFactory: untouchedFactory,
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1]))
        )
        await #expect(throws: GELFProviderError.invalidProviderIdentity) {
            try await invalidProvider.start(request)
        }
        #expect(await untouchedFactory.connectCallCount == 0)

        let wrongProviderRequest = try LogDriverStartRequestV1(
            operationGeneration: request.operationGeneration,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: request.semanticRequestDigest,
            sessionID: request.sessionID,
            containerID: request.containerID,
            leaseGeneration: request.leaseGeneration,
            candidateProcessGeneration: request.candidateProcessGeneration,
            providerID: "wrong.provider",
            providerGeneration: request.providerGeneration,
            candidateSandboxGeneration: request.candidateSandboxGeneration
        )
        await #expect(throws: GELFProviderError.invalidProviderIdentity) {
            try await invalidProvider.start(wrongProviderRequest)
        }
        #expect(await untouchedFactory.connectCallCount == 0)

        let transport = RecordingGELFTransport()
        let provider = GELFLogDriverProvider(
            configurationResolver: FixedGELFConfigurationResolver(validBinding),
            transportFactory: ScriptedGELFTransportFactory([.transport(transport)]),
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1, 2, 3]))
        )
        let started = try await provider.start(request)
        let wrongToken = try gelfSessionCall(
            request: request,
            token: LogDriverOpaqueEffectTokenV1(validating: Data([9, 9, 9]))
        )
        await #expect(throws: GELFProviderError.invalidEffectToken) {
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
        await #expect(throws: GELFProviderError.invalidSessionFence) {
            try await provider.closeSession(wrongFence)
        }
        #expect(await transport.closeCallCount == 0)
    }

    @Test func eagerConnectFailureIsAbsentAndIdenticalRetryCanPrepare() async throws {
        let transport = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([
            .failure(.connect),
            .transport(transport),
        ])
        let request = try gelfStartRequest()
        let resolver = FixedGELFConfigurationResolver(
            try gelfBinding(for: request)
        )
        let provider = GELFLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1]))
        )

        await #expect(throws: GELFTestFailure.connect) {
            try await provider.start(request)
        }
        switch try await provider.reconcileStart(request) {
        case .absent: break
        default: Issue.record("failed eager connect left a GELF effect")
        }

        _ = try await provider.start(request)
        #expect(await factory.connectCallCount == 2)
        #expect(await resolver.callCount == 2)
    }

    @Test func sameScopeConflictDoesNotResolveOrConnectAgain() async throws {
        let transport = RecordingGELFTransport()
        let factory = ScriptedGELFTransportFactory([.transport(transport)])
        let request = try gelfStartRequest()
        let resolver = FixedGELFConfigurationResolver(
            try gelfBinding(for: request)
        )
        let provider = GELFLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: factory,
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1]))
        )
        _ = try await provider.start(request)

        let conflict = try gelfStartRequest(
            semanticRequestDigest: "sha256:changed",
            sessionID: "other-session"
        )
        await #expect(throws: GELFProviderError.idempotencyConflict) {
            try await provider.start(conflict)
        }
        #expect(await factory.connectCallCount == 1)
        #expect(await resolver.callCount == 1)
    }

    @Test func plaintextTCPWarningIsRedactionSafeAndDeduplicatedOnReplay() async throws {
        let request = try gelfStartRequest()
        let warnings = RecordingGELFSecurityWarningEmitter()
        let resolver = FixedGELFConfigurationResolver(
            try gelfBinding(
                for: request,
                configuration: gelfTestConfiguration(
                    endpoint: .tcp(
                        GELFNetworkAddress(
                            host: "sensitive.example",
                            port: "12201"
                        )
                    )
                )
            )
        )
        let provider = GELFLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: ScriptedGELFTransportFactory([
                .transport(RecordingGELFTransport())
            ]),
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1])),
            securityWarningEmitter: warnings
        )

        _ = try await provider.start(request)
        _ = try await provider.start(request)

        #expect(await warnings.warnings == [.plaintextTCP])
        #expect(String(describing: GELFSecurityWarning.plaintextTCP) == "plaintextTCP")
        #expect(!String(describing: GELFSecurityWarning.plaintextTCP).contains("sensitive"))
        #expect(await resolver.callCount == 1)
    }

    @Test func UDPAndFailedTCPStartsDoNotEmitPlaintextWarning() async throws {
        let udpRequest = try gelfStartRequest(sessionID: "udp-session")
        let udpWarnings = RecordingGELFSecurityWarningEmitter()
        let udpProvider = GELFLogDriverProvider(
            configurationResolver: FixedGELFConfigurationResolver(
                try gelfBinding(for: udpRequest)
            ),
            transportFactory: ScriptedGELFTransportFactory([
                .transport(RecordingGELFTransport())
            ]),
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1])),
            securityWarningEmitter: udpWarnings
        )
        _ = try await udpProvider.start(udpRequest)
        #expect(await udpWarnings.warnings.isEmpty)

        let tcpRequest = try gelfStartRequest(sessionID: "tcp-session")
        let tcpWarnings = RecordingGELFSecurityWarningEmitter()
        let tcpProvider = GELFLogDriverProvider(
            configurationResolver: FixedGELFConfigurationResolver(
                try gelfBinding(
                    for: tcpRequest,
                    configuration: gelfTestConfiguration(
                        endpoint: .tcp(
                            GELFNetworkAddress(host: "collector", port: "12201")
                        )
                    )
                )
            ),
            transportFactory: ScriptedGELFTransportFactory([.failure(.connect)]),
            tokenGenerator: FixedGELFTokenGenerator(bytes: Data([1])),
            securityWarningEmitter: tcpWarnings
        )
        await #expect(throws: GELFTestFailure.connect) {
            try await tcpProvider.start(tcpRequest)
        }
        #expect(await tcpWarnings.warnings.isEmpty)
    }

    @Test func installedProviderSetRoutesTCPGELFThroughInjectedLinuxService() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let transport = RecordingGELFTransport()
        let service = ProviderSetGELFTCPService(transport: transport)
        do {
            let providers = try await BuiltinRemoteLogDriverProviderSet.install(
                eventLoopGroup: group,
                awsLogsClientFactory: FixedAWSLogsClientFactory(
                    client: RecordingAWSLogsClient()
                ),
                gelfTCPService: service
            )
            let request = try gelfStartRequest(sessionID: "gelf-linux-service")
            let address = GELFNetworkAddress(
                host: "host.docker.internal",
                port: "12201"
            )
            let configuration = try gelfTestConfiguration(
                endpoint: .tcp(address)
            )
            try await providers.configurations.register(
                try gelfBinding(for: request, configuration: configuration),
                for: request
            )

            let started = try await providers.gelf.start(request)
            #expect(await service.addresses == [address])
            #expect(await transport.closeCallCount == 0)

            let call = try gelfSessionCall(
                request: request,
                token: started.receipt.effectTokenMaterial
            )
            #expect(try await providers.gelf.closeSession(call).observation == .closed)
            #expect(await transport.closeCallCount == 1)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private actor ProviderSetGELFTCPService: GELFTCPService {
    private let transport: RecordingGELFTransport
    private(set) var addresses = [GELFNetworkAddress]()

    init(transport: RecordingGELFTransport) {
        self.transport = transport
    }

    func connect(
        to address: GELFNetworkAddress,
        timeout: Duration
    ) async throws -> any GELFTransport {
        _ = timeout
        addresses.append(address)
        return transport
    }
}

private func gelfStartRequest(
    operationGeneration: UInt64 = 1,
    idempotencyKey: String = "start-key",
    semanticRequestDigest: String = "sha256:request",
    sessionID: String = "gelf-session"
) throws -> LogDriverStartRequestV1 {
    try LogDriverStartRequestV1(
        operationGeneration: operationGeneration,
        idempotencyKey: idempotencyKey,
        semanticRequestDigest: semanticRequestDigest,
        sessionID: sessionID,
        containerID: "container-id",
        leaseGeneration: 3,
        candidateProcessGeneration: 4,
        providerID: GELFLogDriverContract.providerIdentity.id,
        providerGeneration: 1,
        candidateSandboxGeneration: nil
    )
}

private func gelfBinding(
    for request: LogDriverStartRequestV1,
    configuration: GELFDriverConfiguration? = nil
) throws -> GELFConfigurationBinding {
    GELFConfigurationBinding(
        semanticRequestDigest: request.semanticRequestDigest,
        containerID: request.containerID,
        leaseGeneration: request.leaseGeneration,
        providerID: request.providerID,
        providerGeneration: request.providerGeneration,
        configuration: try configuration ?? gelfTestConfiguration()
    )
}

private func gelfSessionCall(
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

private actor FixedGELFConfigurationResolver: GELFConfigurationResolving {
    let binding: GELFConfigurationBinding
    private(set) var callCount = 0

    init(_ binding: GELFConfigurationBinding) {
        self.binding = binding
    }

    func configuration(
        for request: LogDriverStartRequestV1
    ) async throws -> GELFConfigurationBinding {
        callCount += 1
        return binding
    }
}

private struct FixedGELFTokenGenerator: GELFEffectTokenGenerating {
    let bytes: Data

    func makeEffectToken() throws -> Data {
        bytes
    }
}

private actor RecordingGELFSecurityWarningEmitter: GELFSecurityWarningEmitting {
    private(set) var warnings = [GELFSecurityWarning]()

    func emit(_ warning: GELFSecurityWarning) {
        warnings.append(warning)
    }
}
