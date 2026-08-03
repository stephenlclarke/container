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

struct AWSLogsProviderTests {
    @Test func startReplayReconcileFenceAndCloseAreGenerationFenced() async throws {
        let request = try awsLogsStartRequest()
        let resolver = FixedAWSLogsConfigurationResolver(
            try awsLogsBinding(for: request)
        )
        let client = RecordingAWSLogsClient()
        let tokenBytes = Data(repeating: 7, count: 32)
        let provider = AWSLogsLogDriverProvider(
            configurationResolver: resolver,
            clientFactory: FixedAWSLogsClientFactory(client: client),
            clock: SuspendedAWSLogsClock(),
            tokenGenerator: FixedAWSLogsTokenGenerator(bytes: tokenBytes)
        )

        let started = try await provider.start(request)
        let replay = try await provider.start(request)
        #expect(
            replay.receipt.effectTokenMaterial.isByteIdentical(
                to: started.receipt.effectTokenMaterial
            )
        )
        #expect(await resolver.callCount == 1)
        guard
            case .prepared(let reconciled) =
                try await provider.reconcileStart(request)
        else {
            Issue.record("expected prepared reconciliation")
            return
        }
        #expect(
            reconciled.receipt.effectTokenMaterial.isByteIdentical(
                to: started.receipt.effectTokenMaterial
            )
        )

        let call = try awsLogsSessionCall(
            request: request,
            token: started.receipt.effectTokenMaterial
        )
        #expect(
            try await provider.reconcileSession(call).observation == .active
        )
        #expect(
            try await provider.fenceSession(call).observation == .writerFenced
        )
        #expect(
            try await provider.closeSession(call).observation == .closed
        )
    }

    @Test func rejectsConflictingReplayAndWrongToken() async throws {
        let request = try awsLogsStartRequest()
        let resolver = FixedAWSLogsConfigurationResolver(
            try awsLogsBinding(for: request)
        )
        let provider = AWSLogsLogDriverProvider(
            configurationResolver: resolver,
            clientFactory: FixedAWSLogsClientFactory(
                client: RecordingAWSLogsClient()
            ),
            clock: SuspendedAWSLogsClock(),
            tokenGenerator: FixedAWSLogsTokenGenerator(
                bytes: Data(repeating: 8, count: 32)
            )
        )
        let started = try await provider.start(request)
        let conflict = try awsLogsStartRequest(
            operationGeneration: 2,
            idempotencyKey: request.idempotencyKey
        )
        await #expect(throws: AWSLogsProviderError.idempotencyConflict) {
            try await provider.start(conflict)
        }
        let wrong = try LogDriverOpaqueEffectTokenV1(
            validating: Data(repeating: 9, count: 32)
        )
        await #expect(throws: AWSLogsProviderError.invalidEffectToken) {
            try await provider.reconcileSession(
                awsLogsSessionCall(request: request, token: wrong)
            )
        }
        _ = try await provider.closeSession(
            awsLogsSessionCall(
                request: request,
                token: started.receipt.effectTokenMaterial
            )
        )
    }
}
