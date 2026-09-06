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

import ContainerEngineRuntimeSPI
import Foundation
import Testing

@testable import ContainerResource

struct EngineSocketGrantTests {
    @Test
    func prepareIsDeterministicInactiveAndContainsNoBrokerPath() throws {
        let first = try EngineSocketGrantRecordV1.prepare(
            containerID: "container-a",
            intent: .engineAPI()
        )
        let repeated = try EngineSocketGrantRecordV1.prepare(
            containerID: "container-a",
            intent: .engineAPI()
        )

        #expect(first == repeated)
        #expect(first.state == .inactive)
        #expect(first.leaseGeneration == 0)
        #expect(first.activeProcessGeneration == nil)
        #expect(first.activeSandboxGeneration == nil)
        #expect(first.guestPath.value == "/var/run/docker.sock")
        #expect(first.guestMode == 0o660)
        #expect(first.guestUID == 0)
        #expect(first.guestGID == 991)
        #expect(!String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("/tmp/"))
    }

    @Test
    func stagesAndActivatesOnlyTheExactGenerationTuple() throws {
        var grant = try makeGrant()
        try grant.stage(
            leaseGeneration: 1,
            processGeneration: 3,
            sandboxGeneration: 5
        )
        let staged = grant

        try grant.stage(
            leaseGeneration: 1,
            processGeneration: 3,
            sandboxGeneration: 5
        )
        #expect(grant == staged)
        #expect(throws: EngineSocketGrantError.staleGeneration) {
            try grant.activate(
                leaseGeneration: 1,
                processGeneration: 4,
                sandboxGeneration: 5
            )
        }

        try grant.activate(
            leaseGeneration: 1,
            processGeneration: 3,
            sandboxGeneration: 5
        )
        let active = grant
        try grant.activate(
            leaseGeneration: 1,
            processGeneration: 3,
            sandboxGeneration: 5
        )
        #expect(grant == active)
        #expect(grant.state == .active)
    }

    @Test
    func failedStartCompensationRetainsIntentAndFencesStaleFinalizer() throws {
        var grant = try makeGrant()
        try grant.stage(
            leaseGeneration: 1,
            processGeneration: 1,
            sandboxGeneration: 7
        )
        try grant.deactivate(
            leaseGeneration: 1,
            processGeneration: 1,
            sandboxGeneration: 7
        )
        #expect(grant.state == .inactive)
        #expect(grant.activeProcessGeneration == nil)
        #expect(grant.activeSandboxGeneration == nil)

        try grant.stage(
            leaseGeneration: 2,
            processGeneration: 2,
            sandboxGeneration: 8
        )
        #expect(throws: EngineSocketGrantError.staleGeneration) {
            try grant.deactivate(
                leaseGeneration: 1,
                processGeneration: 1,
                sandboxGeneration: 7
            )
        }
        #expect(grant.state == .staged)
        #expect(grant.leaseGeneration == 2)
    }

    @Test
    func recoveryReactivatesOnlyAnExactRunningTuple() throws {
        var exact = try activeGrant()
        exact.reconcile(
            runningProcessGeneration: 9,
            runningSandboxGeneration: 11
        )
        #expect(exact.state == .active)

        var stale = try activeGrant()
        stale.reconcile(
            runningProcessGeneration: 10,
            runningSandboxGeneration: 11
        )
        #expect(stale.state == .inactive)
        #expect(stale.activeProcessGeneration == nil)
        #expect(stale.activeSandboxGeneration == nil)

        var unknown = try activeGrant()
        unknown.reconcile(
            runningProcessGeneration: nil,
            runningSandboxGeneration: nil
        )
        #expect(unknown.state == .inactive)
    }

    @Test
    func revokeRequiresInactiveCurrentLeaseAndIsIdempotent() throws {
        var grant = try makeGrant()
        try grant.revoke(expectedLeaseGeneration: 0)
        try grant.revoke(expectedLeaseGeneration: 0)
        #expect(grant.state == .revoked)

        var active = try activeGrant()
        #expect(
            throws: EngineSocketGrantError.invalidTransition(
                expected: .inactive,
                actual: .active
            )
        ) {
            try active.revoke(expectedLeaseGeneration: 1)
        }
    }

    @Test
    func lifecycleRecordRoundTripsGrantAndDecodesLegacyRecordWithoutIt() throws {
        let grant = try makeGrant()
        let record = ContainerLifecycleRecordV2(
            containerID: "container-a",
            canonicalName: "container-a",
            immutableBundleKey: "container-a",
            selectedProviderFingerprint: "container-runtime-linux",
            engineSocketGrant: grant,
            snapshot: .init(state: .created)
        )
        let encoded = try JSONEncoder().encode(record)
        #expect(
            try JSONDecoder().decode(
                ContainerLifecycleRecordV2.self,
                from: encoded
            ) == record
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "engineSocketGrant")
        let legacy: ContainerResource.ContainerLifecycleRecordV2 = try JSONDecoder().decode(
            ContainerResource.ContainerLifecycleRecordV2.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.engineSocketGrant == nil)
    }

    @Test
    func workloadControllerUsesExactDurableEffectIdentity() async throws {
        let context = WorkloadStartContextV1(
            containerID: "container-a",
            operationGeneration: 4,
            candidateProcessGeneration: 3,
            sandboxGeneration: 2,
            requestDigest: "sha256:start"
        )
        let controller = try EngineSocketGrantWorkloadControllerV1(
            containerID: context.containerID,
            intent: .engineAPI()
        )
        let effect = try await controller.reservation(for: context)

        #expect(effect.domain == .engineSocket)
        #expect(effect.leaseGeneration == context.candidateProcessGeneration)
        #expect(effect.state == .reserved)
        #expect(
            try await controller.apply(effect, context: context)
                == receipt(effect)
        )
        #expect(
            await controller.observe(effect, context: context)
                == .applied(receipt(effect))
        )
        #expect(
            try await controller.compensate(effect, context: context)
                == receipt(effect)
        )

        let stale = try EngineWorkloadEffectV1(
            domain: effect.domain,
            leaseID: effect.leaseID,
            leaseGeneration: effect.leaseGeneration,
            effectID: effect.effectID + "-stale",
            integrityDigest: effect.integrityDigest
        )
        #expect(await controller.observe(stale, context: context) == .unknown)
        await #expect(throws: EngineSocketGrantError.staleGeneration) {
            try await controller.compensate(stale, context: context)
        }
    }

    @Test
    func recoveredControllerDoesNotInventInterruptedApplyOutcome() async throws {
        let context = WorkloadStartContextV1(
            containerID: "container-a",
            operationGeneration: 4,
            candidateProcessGeneration: 3,
            sandboxGeneration: 2,
            requestDigest: "sha256:start"
        )
        let original = try EngineSocketGrantWorkloadControllerV1(
            containerID: context.containerID,
            intent: .engineAPI()
        )
        let effect = try await original.reservation(for: context)
        let recovered = try EngineSocketGrantWorkloadControllerV1(
            containerID: context.containerID,
            intent: .engineAPI()
        )

        #expect(
            await recovered.observe(effect, context: context) == .unknown
        )
        #expect(
            try await recovered.compensate(effect, context: context)
                == receipt(effect)
        )
    }

    private func makeGrant() throws -> EngineSocketGrantRecordV1 {
        try .prepare(containerID: "container-a", intent: .engineAPI())
    }

    private func activeGrant() throws -> EngineSocketGrantRecordV1 {
        var grant = try makeGrant()
        try grant.stage(
            leaseGeneration: 1,
            processGeneration: 9,
            sandboxGeneration: 11
        )
        try grant.activate(
            leaseGeneration: 1,
            processGeneration: 9,
            sandboxGeneration: 11
        )
        return grant
    }

    private func receipt(
        _ effect: EngineWorkloadEffectV1
    ) -> WorkloadEffectReceiptV1 {
        WorkloadEffectReceiptV1(
            domain: effect.domain,
            leaseID: effect.leaseID,
            leaseGeneration: effect.leaseGeneration,
            effectID: effect.effectID,
            integrityDigest: effect.integrityDigest
        )
    }
}
