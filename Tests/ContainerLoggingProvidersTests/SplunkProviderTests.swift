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
import Testing

@testable import ContainerLoggingProviders

struct SplunkProviderTests {
    @Test func startReplayReconcileFenceAndCloseUseOneProtectedEffect() async throws {
        let request = try splunkStartRequest()
        let resolver = FixedSplunkConfigurationResolver(
            try splunkBinding(for: request)
        )
        let transport = RecordingSplunkTransport()
        let provider = SplunkLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: FixedSplunkTransportFactory(
                transport: transport
            ),
            tokenGenerator: FixedSplunkTokenGenerator(bytes: Data([1]))
        )
        let started = try await provider.start(request)
        let replay = try await provider.start(request)
        #expect(await resolver.callCount == 1)
        #expect(
            replay.receipt.effectTokenMaterial.isByteIdentical(
                to: started.receipt.effectTokenMaterial
            )
        )
        switch try await provider.reconcileStart(request) {
        case .prepared(let reconciled):
            #expect(
                reconciled.receipt.effectTokenMaterial.isByteIdentical(
                    to: started.receipt.effectTokenMaterial
                )
            )
        default:
            Issue.record("expected prepared reconciliation")
        }

        let call = try splunkSessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        #expect(
            try await provider.reconcileSession(call).observation == .active
        )
        let fenced = try await provider.fenceSession(call)
        #expect(fenced.observation == .writerFenced)
        #expect(fenced.writerFenceReceiptDigest != nil)
        #expect(
            try await provider.closeSession(call).observation
                == .closed
        )
        #expect(await transport.closeCount == 1)
    }

    @Test func rejectsIdentityBindingTokenAndIdempotencySubstitution() async throws {
        let request = try splunkStartRequest()
        let resolver = FixedSplunkConfigurationResolver(
            try splunkBinding(for: request)
        )
        let provider = SplunkLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: FixedSplunkTransportFactory(
                transport: RecordingSplunkTransport()
            ),
            tokenGenerator: FixedSplunkTokenGenerator(bytes: Data([1]))
        )
        let started = try await provider.start(request)
        let conflict = try splunkStartRequest(
            operationGeneration: 1,
            idempotencyKey: request.idempotencyKey,
            semanticRequestDigest: "sha256:changed",
            sessionID: request.sessionID
        )
        await #expect(throws: SplunkProviderError.idempotencyConflict) {
            try await provider.start(conflict)
        }

        let wrongToken = try splunkSessionCall(
            request: request,
            token: LogDriverOpaqueEffectTokenV1(validating: Data([2]))
        )
        await #expect(throws: SplunkProviderError.invalidEffectToken) {
            try await provider.reconcileSession(wrongToken)
        }
        let valid = try splunkSessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        #expect(
            try await provider.reconcileSession(valid).observation == .active
        )
        _ = try await provider.closeSession(valid)
    }

    @Test func failedConnectionVerificationLeavesStartAbsentForRetry() async throws {
        let request = try splunkStartRequest()
        let configuration = try splunkTestConfiguration(
            verifyConnection: true
        )
        let resolver = FixedSplunkConfigurationResolver(
            try splunkBinding(for: request, configuration: configuration)
        )
        let provider = SplunkLogDriverProvider(
            configurationResolver: resolver,
            transportFactory: FixedSplunkTransportFactory(
                transport: RecordingSplunkTransport([
                    .success(
                        SplunkHTTPResponse(
                            statusCode: 503,
                            body: Data("secret remote body".utf8)
                        )
                    )
                ])
            )
        )
        await #expect(
            throws: SplunkProviderError.verificationFailed(statusCode: 503)
        ) {
            try await provider.start(request)
        }
        switch try await provider.reconcileStart(request) {
        case .absent:
            break
        default:
            Issue.record("failed verification must leave start absent")
        }
    }
}
