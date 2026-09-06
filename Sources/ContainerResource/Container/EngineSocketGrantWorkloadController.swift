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
import CryptoKit
import Foundation

/// Grants one shared workload access to the Engine API socket.
///
/// The shared-sandbox workload ledger is the durable authority. This
/// controller deliberately reports an interrupted apply as unknown after an
/// authority restart: only the ledger may promote a successfully acknowledged
/// reservation to an active grant.
public actor EngineSocketGrantWorkloadControllerV1:
    WorkloadEffectControllerV1
{
    public nonisolated let domain = EngineWorkloadEffectDomainV1.engineSocket

    private let grant: EngineSocketGrantRecordV1
    private var appliedEffectIDs = Set<String>()

    public init(
        containerID: String,
        intent: InboundUnixSocketIntentV1
    ) throws {
        grant = try EngineSocketGrantRecordV1.prepare(
            containerID: containerID,
            intent: intent
        )
    }

    public func reservation(
        for context: WorkloadStartContextV1
    ) throws -> EngineWorkloadEffectV1 {
        guard context.containerID == grant.containerID else {
            throw EngineSocketGrantError.invalidContainerID
        }
        return try Self.effect(grant: grant, context: context)
    }

    public func apply(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) throws -> WorkloadEffectReceiptV1 {
        let expected = try Self.effect(grant: grant, context: context)
        guard Self.matches(effect, expected) else {
            throw EngineSocketGrantError.staleGeneration
        }
        appliedEffectIDs.insert(effect.effectID)
        return Self.receipt(effect)
    }

    public func observe(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) -> WorkloadEffectObservationV1 {
        guard let expected = try? Self.effect(grant: grant, context: context),
            Self.matches(effect, expected)
        else {
            return .unknown
        }
        guard appliedEffectIDs.contains(effect.effectID) else {
            return .unknown
        }
        return .applied(Self.receipt(effect))
    }

    public func compensate(
        _ effect: EngineWorkloadEffectV1,
        context: WorkloadStartContextV1
    ) throws -> WorkloadEffectReceiptV1 {
        let expected = try Self.effect(grant: grant, context: context)
        guard Self.matches(effect, expected) else {
            throw EngineSocketGrantError.staleGeneration
        }
        appliedEffectIDs.remove(effect.effectID)
        return Self.receipt(effect)
    }

    private nonisolated static func effect(
        grant: EngineSocketGrantRecordV1,
        context: WorkloadStartContextV1
    ) throws -> EngineWorkloadEffectV1 {
        let material = [
            "container.engine-socket-effect.v1",
            grant.grantID,
            context.containerID,
            String(context.candidateProcessGeneration),
            String(context.sandboxGeneration),
            grant.guestPath.value,
            String(grant.guestMode),
            String(grant.guestUID),
            String(grant.guestGID),
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return try EngineWorkloadEffectV1(
            domain: .engineSocket,
            leaseID: grant.grantID,
            leaseGeneration: context.candidateProcessGeneration,
            effectID:
                "\(grant.grantID)-\(context.candidateProcessGeneration)-\(context.sandboxGeneration)",
            integrityDigest: "sha256:\(digest)"
        )
    }

    private nonisolated static func receipt(
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

    private nonisolated static func matches(
        _ effect: EngineWorkloadEffectV1,
        _ expected: EngineWorkloadEffectV1
    ) -> Bool {
        effect.domain == expected.domain
            && effect.leaseID == expected.leaseID
            && effect.leaseGeneration == expected.leaseGeneration
            && effect.effectID == expected.effectID
            && effect.integrityDigest == expected.integrityDigest
    }

}
