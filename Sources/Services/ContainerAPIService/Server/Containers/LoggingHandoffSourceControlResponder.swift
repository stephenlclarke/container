//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import Foundation

enum LoggingHandoffSourceControlResponderError:
    Error,
    Equatable,
    Sendable
{
    case invalidContribution
    case invalidGatewayIdentity
    case invalidManifest
    case invalidRequest
    case unsupportedOperation
}

/// Production source endpoint for logging part export and final source
/// manifest signing.
///
/// Export verifies destination key possession against the exact archived trust
/// registry, captures quiesced authority state, seals the payload and lineage
/// key directly to those destination keys, publishes an immutable source
/// object, and durably freezes the unsigned contribution. Signing is separate:
/// the source reloads that contribution and signs only an exact complete
/// manifest that contains it.
struct LoggingHandoffSourceControlResponder:
    ContainerEngineProviderHandoffControlResponder,
    Sendable
{
    typealias ExportContainers =
        @Sendable (ProviderHandoffPartExportRequestV1) async throws
            -> [LoggingHandoffExportContainerV1]

    private struct ValidatedExport: Sendable {
        let proofDigests: [String]
    }

    private static let requiredCapability =
        "engine.handoff.part.logging.v1"

    private let objectStore: ProviderHandoffBundleObjectStore
    private let contributionStore: ProviderHandoffSourceContributionStore
    private let lineageKeyStore: ProviderHandoffLineageKeyStore
    private let trustRegistryStore: ProviderHandoffTrustRegistryStore
    private let providerIdentity: ProviderHandoffProviderIdentityV1
    private let exportContainers: ExportContainers
    private let nowUnixSeconds: @Sendable () throws -> UInt64
    private let downstream: any ContainerEngineProviderHandoffControlResponder

    init(
        objectStore: ProviderHandoffBundleObjectStore,
        contributionStore: ProviderHandoffSourceContributionStore,
        lineageKeyStore: ProviderHandoffLineageKeyStore,
        trustRegistryStore: ProviderHandoffTrustRegistryStore,
        providerIdentity: ProviderHandoffProviderIdentityV1,
        exportContainers: @escaping ExportContainers,
        nowUnixSeconds: @escaping @Sendable () throws -> UInt64 = {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw LoggingHandoffSourceControlResponderError.invalidRequest
            }
            return UInt64(value.rounded(.down))
        },
        downstream: any ContainerEngineProviderHandoffControlResponder
    ) {
        self.objectStore = objectStore
        self.contributionStore = contributionStore
        self.lineageKeyStore = lineageKeyStore
        self.trustRegistryStore = trustRegistryStore
        self.providerIdentity = providerIdentity
        self.exportContainers = exportContainers
        self.nowUnixSeconds = nowUnixSeconds
        self.downstream = downstream
    }

    func respond(
        to request: ContainerEngineProviderHandoffControlRequestV1,
        body: Data,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async -> ContainerEngineProviderHandoffControlResultV1 {
        guard
            request.operation == .partExport
            || request.operation == .sourceSignManifest
        else {
            return await downstream.respond(
                to: request,
                body: body,
                context: context
            )
        }
        do {
            switch request.operation {
            case .partExport:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffSourceControlCodec.exportRequestMediaType
                )
                let contribution = try await export(
                    ProviderHandoffSourceControlCodec
                        .decodeExportRequest(body),
                    context: context
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body: ProviderHandoffSourceControlCodec
                        .encodeContribution(contribution),
                    mediaType:
                    ProviderHandoffSourceControlCodec.contributionMediaType
                )
            case .sourceSignManifest:
                try Self.requireMediaType(
                    request.bodyMediaType,
                    ProviderHandoffSourceControlCodec.signRequestMediaType
                )
                let receipt = try sign(
                    ProviderHandoffSourceControlCodec.decodeSignRequest(body),
                    context: context
                )
                return try Self.completed(
                    requestID: request.requestID,
                    body: ProviderHandoffSourceControlCodec
                        .encodeSignReceipt(receipt),
                    mediaType:
                    ProviderHandoffSourceControlCodec.signReceiptMediaType
                )
            case .destinationKeyPossession, .destinationKeySnapshot,
                 .objectAppend, .objectDeclare, .objectRead, .objectVerify,
                 .partActivate, .partCompensate, .partPromote, .partStage,
                 .rootApply, .rootPrepare, .rootRelease, .rootSnapshot:
                throw LoggingHandoffSourceControlResponderError
                    .unsupportedOperation
            }
        } catch {
            return Self.failure(
                requestID: request.requestID,
                disposition: Self.disposition(for: error),
                message: Self.message(for: error)
            )
        }
    }

    private func export(
        _ request: ProviderHandoffPartExportRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) async throws -> ProviderHandoffSourceContributionV1 {
        let validated = try validateExport(request, context: context)
        let exportRequestDigest = try ProviderHandoffSourceControlCodec
            .exportRequestDigest(request)
        do {
            let existing = try contributionStore.load(
                tokenID: request.tokenID,
                manifestID: request.manifestID,
                partKind: .logging
            )
            guard
                existing.exportRequestDigestSHA256 == exportRequestDigest
            else {
                throw LoggingHandoffSourceControlResponderError
                    .invalidContribution
            }
            return existing
        } catch ProviderHandoffSourceContributionStoreError.notFound {
            // First export continues below.
        }

        let lineageKey = try lineageKeyStore.loadOrCreate(
            binding: ProviderHandoffLineageKeyBindingV1(
                providerFingerprint: request.sourceProviderFingerprint,
                sourceStateRootUUID: request.sourceStateRootUUID,
                authorityLineageUUID: request.authorityLineageUUID,
                keyVersion: request.lineageDigestKeyVersion
            )
        )
        let containers = try await exportContainers(request)
        let payload = try LoggingHandoffPayloadCodec.prepareSealed(
            containers: containers,
            tokenID: request.tokenID,
            manifestID: request.manifestID,
            sourceStateRootUUID: request.sourceStateRootUUID,
            sourceAuthorityLineageUUID: request.authorityLineageUUID,
            sourceLineageKeyVersion: request.lineageDigestKeyVersion,
            sourceLineageHMACSHA256Key: lineageKey.rawHMACSHA256Key,
            destinationProviderFingerprint:
            request.destinationProviderFingerprint,
            destinationStateRootUUID: request.destinationStateRootUUID,
            destinationKeyID: request.destinationPayloadEncryptionKey.keyID,
            destinationPublicKey:
            request.destinationPayloadEncryptionKey.rawPublicKey,
            nonce: Self.derivedBytes(
                domain: "logging-payload-nonce-v1",
                requestDigest: exportRequestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 24
            ),
            ephemeralPrivateKey: Self.derivedBytes(
                domain: "logging-payload-ephemeral-v1",
                requestDigest: exportRequestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 32
            )
        )
        let objectRecord = try publish(payload)
        let lineageEnvelope = try providerIdentity.sealLineageKey(
            ProviderHandoffEnvelopeLineageKeyV1(
                sourceStateRootUUID: request.sourceStateRootUUID,
                authorityLineageUUID: request.authorityLineageUUID,
                keyVersion: request.lineageDigestKeyVersion,
                rawHMACSHA256Key: lineageKey.rawHMACSHA256Key
            ),
            envelopeID: "lineage:\(request.sourceStateRootUUID)",
            tokenID: request.tokenID,
            manifestID: request.manifestID,
            destinationProviderFingerprint:
            request.destinationProviderFingerprint,
            destinationStateRootUUID: request.destinationStateRootUUID,
            destinationKeyID:
            request.destinationLineageKeyEncryptionKey.keyID,
            destinationPublicKey:
            request.destinationLineageKeyEncryptionKey.rawPublicKey,
            nonce: Self.derivedBytes(
                domain: "logging-lineage-nonce-v1",
                requestDigest: exportRequestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 24
            ),
            trustRegistryRevision: request.trustRegistryRevision,
            ephemeralPrivateKey: Self.derivedBytes(
                domain: "logging-lineage-ephemeral-v1",
                requestDigest: exportRequestDigest,
                key: lineageKey.rawHMACSHA256Key,
                count: 32
            )
        )
        let part = ProviderHandoffPartV1(
            kind: .logging,
            schemaVersion: 1,
            disposition: .included,
            sourceStateRootUUIDs: [request.sourceStateRootUUID],
            requiredCapabilities: [Self.requiredCapability],
            payload: payload.descriptor
        )
        let contribution = try ProviderHandoffSourceControlCodec
            .finalizeContribution(
                ProviderHandoffSourceContributionV1(
                    partKind: .logging,
                    tokenID: request.tokenID,
                    manifestID: request.manifestID,
                    trustRegistryRevision: request.trustRegistryRevision,
                    exportRequestDigestSHA256: exportRequestDigest,
                    sourceProviderFingerprint:
                    request.sourceProviderFingerprint,
                    sourceStateRootUUID: request.sourceStateRootUUID,
                    authorityLineageUUID: request.authorityLineageUUID,
                    lineageDigestKeyVersion:
                    request.lineageDigestKeyVersion,
                    sourcePreCommitExpectation:
                    request.sourcePreCommitExpectation,
                    destinationProviderFingerprint:
                    request.destinationProviderFingerprint,
                    destinationStateRootUUID:
                    request.destinationStateRootUUID,
                    destinationPreCommitExpectation:
                    request.destinationPreCommitExpectation,
                    destinationKeyPossessionProofDigestsSHA256:
                    validated.proofDigests,
                    resultingAuthorityLineageUUID:
                    request.resultingAuthorityLineageUUID,
                    resultingLineageDigestKeyVersion:
                    request.resultingLineageDigestKeyVersion,
                    destinationSealedLineageKeyEnvelope: lineageEnvelope,
                    part: part,
                    sourceObjectRecord: objectRecord
                )
            )
        return try contributionStore.store(contribution)
    }

    private func sign(
        _ request: ProviderHandoffSourceManifestSignRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws -> ProviderHandoffSourceManifestSignReceiptV1 {
        let manifest = request.candidateManifest
        try validateGateway(
            bootstrap: request.bootstrap,
            context: context
        )
        let contribution = try contributionStore.load(
            tokenID: manifest.tokenID,
            manifestID: manifest.manifestID,
            partKind: request.partKind
        )
        guard
            request.partKind == .logging,
            request.contributionDigestSHA256
            == contribution.contributionDigestSHA256,
            manifest.trustRegistryRevision
            == contribution.trustRegistryRevision,
            manifest.destinationProviderFingerprint
            == contribution.destinationProviderFingerprint,
            manifest.destinationStateRootUUID
            == contribution.destinationStateRootUUID,
            manifest.destinationPreCommitExpectation
            == contribution.destinationPreCommitExpectation,
            manifest.destinationKeyPossessionProofDigestsSHA256
            == contribution
            .destinationKeyPossessionProofDigestsSHA256,
            manifest.resultingAuthorityLineageUUID
            == contribution.resultingAuthorityLineageUUID,
            manifest.resultingLineageDigestKeyVersion
            == contribution.resultingLineageDigestKeyVersion,
            manifest.parts.filter({ $0.kind == .logging })
            == [contribution.part],
            manifest.destinationSealedLineageKeyEnvelopes.filter({
                $0.sourceStateRootUUID == contribution.sourceStateRootUUID
            }) == [contribution.destinationSealedLineageKeyEnvelope],
            let source = manifest.sources.first(where: {
                $0.stateRootUUID == contribution.sourceStateRootUUID
            }),
            source.providerFingerprint
            == contribution.sourceProviderFingerprint,
            source.authorityLineageUUID
            == contribution.authorityLineageUUID,
            source.lineageDigestKeyVersion
            == contribution.lineageDigestKeyVersion,
            source.preCommitExpectation
            == contribution.sourcePreCommitExpectation
        else {
            throw LoggingHandoffSourceControlResponderError.invalidManifest
        }

        let now = try nowUnixSeconds()
        let trustRegistry = try trustRegistryStore.loadRevision(
            manifest.trustRegistryRevision,
            bootstrap: request.bootstrap
        )
        let signingKey = try providerIdentity.trustKey(
            for: .sourceManifestSigning
        )
        guard
            try trustRegistry.key(
                identifier: signingKey.keyID,
                purpose: .sourceManifestSigning,
                role: .sourceProvider,
                providerFingerprint:
                providerIdentity.context.providerFingerprint,
                stateRootUUID: providerIdentity.context.stateRootUUID,
                atUnixSeconds: now
            ) == signingKey
        else {
            throw LoggingHandoffSourceControlResponderError.invalidManifest
        }
        let digest = try ProviderHandoffProjections.sourceManifestDigest(
            source: source,
            manifest: manifest
        )
        let signature = try providerIdentity.sign(
            projectionDigestSHA256: digest,
            purpose: .sourceManifestSigning,
            trustRegistryRevision: manifest.trustRegistryRevision
        )
        return ProviderHandoffSourceManifestSignReceiptV1(
            partKind: .logging,
            tokenID: manifest.tokenID,
            manifestID: manifest.manifestID,
            sourceStateRootUUID: contribution.sourceStateRootUUID,
            contributionDigestSHA256:
            contribution.contributionDigestSHA256,
            sourceProjectionDigestSHA256: digest,
            sourceSignature: signature
        )
    }

    private func validateExport(
        _ request: ProviderHandoffPartExportRequestV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws -> ValidatedExport {
        try validateGateway(bootstrap: request.bootstrap, context: context)
        guard
            request.partKind == .logging,
            request.sourceProviderFingerprint
            == providerIdentity.context.providerFingerprint,
            request.sourceStateRootUUID
            == providerIdentity.context.stateRootUUID
        else {
            throw LoggingHandoffSourceControlResponderError.invalidRequest
        }
        let now = try nowUnixSeconds()
        let trustRegistry = try trustRegistryStore.loadRevision(
            request.trustRegistryRevision,
            bootstrap: request.bootstrap
        )
        for purpose in [
            ProviderHandoffKeyPurposeV1.sourceManifestSigning,
            .lineageKeyEnvelopeSigning,
        ] {
            let key = try providerIdentity.trustKey(for: purpose)
            guard
                try trustRegistry.key(
                    identifier: key.keyID,
                    purpose: purpose,
                    role: .sourceProvider,
                    providerFingerprint:
                    providerIdentity.context.providerFingerprint,
                    stateRootUUID: providerIdentity.context.stateRootUUID,
                    atUnixSeconds: now
                ) == key
            else {
                throw LoggingHandoffSourceControlResponderError.invalidRequest
            }
        }
        for key in [
            request.destinationPayloadEncryptionKey,
            request.destinationLineageKeyEncryptionKey,
        ] {
            guard
                try trustRegistry.key(
                    identifier: key.keyID,
                    purpose: key.purpose,
                    role: .destinationProvider,
                    providerFingerprint:
                    request.destinationProviderFingerprint,
                    stateRootUUID: request.destinationStateRootUUID,
                    atUnixSeconds: now
                ) == key
            else {
                throw LoggingHandoffSourceControlResponderError.invalidRequest
            }
        }
        let proofs = try request.destinationKeyPossessionProofs.map {
            try ProviderHandoffPossessionProofCodec.validateDestinationReceipt(
                $0,
                trustRegistry: trustRegistry,
                atUnixSeconds: now
            )
        }
        let proofDigests = proofs.map(\.proofRecordDigestSHA256).sorted()
        guard
            Set(proofs.map(\.proof.destinationKeyID))
            == Set([
                request.destinationPayloadEncryptionKey.keyID,
                request.destinationLineageKeyEncryptionKey.keyID,
            ])
        else {
            throw LoggingHandoffSourceControlResponderError.invalidRequest
        }
        return ValidatedExport(
            proofDigests: proofDigests
        )
    }

    private func validateGateway(
        bootstrap: ProviderHandoffPinnedBootstrapKeyV1,
        context: ContainerEngineProviderHandoffControlContextV1
    ) throws {
        guard
            bootstrap.codeRequirementDigestSHA256
            == context.authenticatedGatewayCodeIdentity
            .designatedRequirementDigestSHA256,
            context.providerFingerprint.digest
            == providerIdentity.context.providerFingerprint,
            context.providerFingerprint.stateRootUUID.uuidString.lowercased()
            == providerIdentity.context.stateRootUUID
        else {
            throw LoggingHandoffSourceControlResponderError
                .invalidGatewayIdentity
        }
    }

    private func publish(
        _ payload: ProviderHandoffPreparedPayloadV1
    ) throws -> ProviderHandoffBundleObjectRecordV1 {
        var record = try objectStore.declare(
            bundleObjectID: payload.descriptor.bundleObjectID,
            transportByteLength: payload.descriptor.transportByteLength,
            transportDigestSHA256:
            payload.descriptor.transportDigestSHA256
        )
        while record.state != .verified,
              record.receivedByteCount < payload.descriptor.transportByteLength
        {
            guard record.receivedByteCount <= UInt64(Int.max) else {
                throw LoggingHandoffSourceControlResponderError
                    .invalidContribution
            }
            let lower = Int(record.receivedByteCount)
            let upper = min(
                payload.transportBytes.count,
                lower + ProviderHandoffBundleObjectStore.maximumChunkBytes
            )
            guard lower < upper else {
                throw LoggingHandoffSourceControlResponderError
                    .invalidContribution
            }
            let lowerIndex = payload.transportBytes.index(
                payload.transportBytes.startIndex,
                offsetBy: lower
            )
            let upperIndex = payload.transportBytes.index(
                payload.transportBytes.startIndex,
                offsetBy: upper
            )
            record = try objectStore.append(
                bundleObjectID: payload.descriptor.bundleObjectID,
                offset: record.receivedByteCount,
                bytes: Data(payload.transportBytes[lowerIndex ..< upperIndex]),
                expectedObjectRevision: record.objectRevision
            )
        }
        if record.state != .verified {
            record = try objectStore.verify(
                bundleObjectID: payload.descriptor.bundleObjectID,
                expectedObjectRevision: record.objectRevision
            )
        }
        return record
    }

    private static func derivedBytes(
        domain: String,
        requestDigest: String,
        key: Data,
        count: Int
    ) throws -> Data {
        let authentication = ProviderHandoffDigest.hmacSHA256(
            key: key,
            data: Data("\(domain)\u{0}\(requestDigest)".utf8)
        )
        return try Data(
            ProviderHandoffDigest.parseSHA256(authentication).prefix(count)
        )
    }

    private static func requireMediaType(
        _ actual: String,
        _ expected: String
    ) throws {
        guard actual == expected else {
            throw LoggingHandoffSourceControlResponderError.invalidRequest
        }
    }

    private static func completed(
        requestID: String,
        body: Data,
        mediaType: String
    ) throws -> ContainerEngineProviderHandoffControlResultV1 {
        try ContainerEngineProviderHandoffControlResultV1(
            response: ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: .completed,
                bodyMediaType: mediaType,
                body: body
            ),
            body: body
        )
    }

    private static func failure(
        requestID: String,
        disposition: ContainerEngineProviderHandoffDispositionV1,
        message: String
    ) -> ContainerEngineProviderHandoffControlResultV1 {
        let body = Data()
        guard
            let response = try? ContainerEngineProviderHandoffControlResponseV1(
                requestID: requestID,
                disposition: disposition,
                bodyMediaType:
                "application/vnd.io.github.stephenlclarke.container.handoff-error.v1+json",
                body: body,
                message: String(
                    decoding: message.utf8.prefix(1024),
                    as: UTF8.self
                )
            )
        else {
            preconditionFailure(
                "validated provider request produced an invalid response"
            )
        }
        return ContainerEngineProviderHandoffControlResultV1(
            response: response,
            body: body
        )
    }

    private static func disposition(
        for error: any Error
    ) -> ContainerEngineProviderHandoffDispositionV1 {
        switch error {
        case ProviderHandoffSourceContributionStoreError.conflict,
             ProviderHandoffBundleObjectStoreError.conflictingChunk,
             ProviderHandoffBundleObjectStoreError.identityMismatch,
             ProviderHandoffBundleObjectStoreError.revisionMismatch:
            .conflict
        case ProviderHandoffBundleObjectStoreError.ioFailure,
             ProviderHandoffSourceContributionStoreError.ioFailure:
            .retryableFailure
        case ProviderHandoffBundleObjectStoreError.integrityMismatch,
             ProviderHandoffBundleObjectStoreError.invalidMetadata,
             ProviderHandoffSourceContributionStoreError.invalidMetadata:
            .recoveryRequired
        default:
            .rejected
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case let value as ProviderHandoffBundleObjectStoreError:
            value.description
        case let value as ProviderHandoffSourceContributionStoreError:
            value.description
        case LoggingHandoffSourceControlResponderError.invalidGatewayIdentity:
            "logging handoff source rejected the gateway identity"
        case LoggingHandoffSourceControlResponderError.invalidContribution:
            "logging handoff source contribution is invalid"
        case LoggingHandoffSourceControlResponderError.invalidManifest:
            "logging handoff source manifest does not match the durable contribution"
        default:
            "logging handoff source control request is invalid"
        }
    }
}
