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

@testable import ContainerResource

struct ContainerLogProviderLifecycleTests {
    @Test func opaqueEffectTokensAreBoundedComparableAndNeverGenerallyEncoded() throws {
        let secret = "opaque-provider-secret"
        let token = try LogDriverOpaqueEffectTokenV1(validating: Data(secret.utf8))
        let same = try LogDriverOpaqueEffectTokenV1(validating: Data(secret.utf8))
        let different = try LogDriverOpaqueEffectTokenV1(validating: Data("different".utf8))

        #expect(token.isByteIdentical(to: same))
        #expect(!token.isByteIdentical(to: different))
        #expect(!String(describing: token).contains(secret))
        #expect(!String(reflecting: token).contains(secret))
        #expect(!isEncodable(token))

        #expect(throws: LogDriverLifecycleContractError.effectTokenTooLarge(maximumBytes: 65_536)) {
            try LogDriverOpaqueEffectTokenV1(
                validating: Data(
                    repeating: 0x41,
                    count: LogDriverLifecycleLimitsV1.maximumOpaqueEffectTokenBytes + 1
                )
            )
        }
    }

    @Test func writerStartRequestIsStrictVersionedBoundedAndReplayAware() throws {
        let request = try makeStartRequest()
        let data = try JSONEncoder().encode(request)

        #expect(data.count <= LogDriverStartRequestV1.maximumEncodedTransportBytes)
        #expect(try JSONDecoder().decode(LogDriverStartRequestV1.self, from: data) == request)
        #expect(request.idempotencyComparison(to: request) == .identicalReplay)

        let digestConflict = try makeStartRequest(semanticRequestDigest: "sha256:changed")
        #expect(request.idempotencyComparison(to: digestConflict) == .conflict)

        let sessionConflict = try makeStartRequest(sessionID: "writer-session-2")
        #expect(request.idempotencyComparison(to: sessionConflict) == .conflict)

        let distinctScope = try makeStartRequest(operationGeneration: 10)
        #expect(request.idempotencyComparison(to: distinctScope) == .distinctScope)

        let object = try jsonObject(data)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                LogDriverStartRequestV1.self,
                from: encoded(object.merging(["future": true]) { _, new in new })
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                LogDriverStartRequestV1.self,
                from: encoded(object.merging(["schemaVersion": 2]) { _, new in new })
            )
        }

        #expect(throws: LogDriverLifecycleContractError.zeroGeneration("providerGeneration")) {
            try makeStartRequest(providerGeneration: 0)
        }
        #expect(
            throws: LogDriverLifecycleContractError.fieldExceedsUTF8Limit(
                field: "idempotencyKey",
                maximumBytes: LogDriverLifecycleLimitsV1.maximumIdempotencyKeyUTF8Bytes
            )
        ) {
            try makeStartRequest(
                idempotencyKey: String(
                    repeating: "x",
                    count: LogDriverLifecycleLimitsV1.maximumIdempotencyKeyUTF8Bytes + 1
                )
            )
        }
        #expect(
            throws: LogDriverLifecycleContractError.fieldExceedsUTF8Limit(
                field: "semanticRequestDigest",
                maximumBytes: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes
            )
        ) {
            try makeStartRequest(
                semanticRequestDigest: String(
                    repeating: "d",
                    count: LogDriverLifecycleLimitsV1.maximumDigestUTF8Bytes + 1
                )
            )
        }
    }

    @Test func writerFenceEncodingIsExplicitAndRejectsCrossVariantSubstitution() throws {
        let candidate = try LogDriverSessionFenceV1(
            candidateOperationGeneration: 7,
            processGeneration: 11,
            sandboxGeneration: 13
        )
        let active = try LogDriverSessionFenceV1(
            activeProcessGeneration: 11,
            sandboxGeneration: 13
        )

        #expect(try roundTrip(candidate) == candidate)
        #expect(try roundTrip(active) == active)

        var object = try jsonObject(JSONEncoder().encode(active))
        object["operationGeneration"] = 7
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LogDriverSessionFenceV1.self, from: encoded(object))
        }

        object = try jsonObject(JSONEncoder().encode(candidate))
        object["future"] = "unsupported"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LogDriverSessionFenceV1.self, from: encoded(object))
        }
    }

    @Test func writerCallsAndAcknowledgementsEchoCompleteIdentityAndRedactTokens() throws {
        let tokenSecret = "writer-token-secret"
        let token = try LogDriverOpaqueEffectTokenV1(validating: Data(tokenSecret.utf8))
        let fence = try LogDriverSessionFenceV1(
            activeProcessGeneration: 11,
            sandboxGeneration: 13
        )
        let call = try LogDriverSessionCallV1(
            sessionID: "writer-session",
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: "provider-id",
            providerGeneration: 5,
            fence: fence,
            effectTokenMaterial: token
        )
        let acknowledgement = try LogDriverSessionAcknowledgementV1(
            call: call,
            observation: .writerFenced,
            writerFenceReceiptDigest: "sha256:fence"
        )

        #expect(acknowledgement.call.identity == call.identity)
        #expect(!String(describing: call).contains(tokenSecret))
        #expect(!String(reflecting: call).contains(tokenSecret))
        #expect(!String(describing: acknowledgement).contains(tokenSecret))
        #expect(!isEncodable(call))
        #expect(!isEncodable(acknowledgement))

        #expect(
            throws: LogDriverLifecycleContractError.invalidAcknowledgement(
                "writer fence observation and receipt digest must be present together"
            )
        ) {
            try LogDriverSessionAcknowledgementV1(
                call: call,
                observation: .writerFenced,
                writerFenceReceiptDigest: nil
            )
        }
        #expect(
            throws: LogDriverLifecycleContractError.invalidAcknowledgement(
                "writer fence observation and receipt digest must be present together"
            )
        ) {
            try LogDriverSessionAcknowledgementV1(
                call: call,
                observation: .closed,
                writerFenceReceiptDigest: "sha256:unexpected"
            )
        }
    }

    @Test func startReceiptsKeepRawMaterialOutOfTextAndEncoding() throws {
        let secret = "start-receipt-token"
        let receipt = LogDriverStartReceiptV1(
            request: try makeStartRequest(),
            effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(validating: Data(secret.utf8))
        )

        #expect(!String(describing: receipt).contains(secret))
        #expect(!String(reflecting: receipt).contains(secret))
        #expect(!isEncodable(receipt))
    }

    @Test func readRequestAndReaderOpenAreStrictBoundedAndReplayAware() throws {
        let read = try ContainerLogReadRequest(
            stdout: true,
            stderr: false,
            follow: true,
            tail: 100,
            since: Date(timeIntervalSince1970: 10),
            until: Date(timeIntervalSince1970: 20),
            timestamps: true,
            details: true
        )
        let request = try makeReaderOpenRequest(read: read)
        let data = try JSONEncoder().encode(request)

        #expect(data.count <= LogDriverReaderOpenRequestV1.maximumEncodedTransportBytes)
        #expect(try JSONDecoder().decode(LogDriverReaderOpenRequestV1.self, from: data) == request)
        #expect(request.idempotencyComparison(to: request) == .identicalReplay)
        #expect(
            request.idempotencyComparison(
                to: try makeReaderOpenRequest(semanticRequestDigest: "sha256:changed", read: read)
            ) == .conflict
        )
        #expect(
            request.idempotencyComparison(
                to: try makeReaderOpenRequest(operationGeneration: 9, read: read)
            ) == .distinctScope
        )

        var object = try jsonObject(data)
        var nestedRead = try #require(object["read"] as? [String: Any])
        nestedRead["future"] = true
        object["read"] = nestedRead
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LogDriverReaderOpenRequestV1.self, from: encoded(object))
        }

        #expect(
            throws: LogDriverLifecycleContractError.invalidReadRequest(
                "tail must be between zero and \(ContainerLogReadRequest.maximumTail)"
            )
        ) {
            try ContainerLogReadRequest(tail: -1)
        }
        #expect(
            throws: LogDriverLifecycleContractError.invalidReadRequest(
                "tail must be between zero and \(ContainerLogReadRequest.maximumTail)"
            )
        ) {
            try ContainerLogReadRequest(tail: ContainerLogReadRequest.maximumTail + 1)
        }
        #expect(throws: LogDriverLifecycleContractError.invalidReadRequest("since must be finite")) {
            try ContainerLogReadRequest(since: Date(timeIntervalSinceReferenceDate: .infinity))
        }
    }

    @Test func readerCallsAndAcknowledgementsEchoIdentityAndEnforceTerminalDigest() throws {
        let secret = "reader-token-secret"
        let token = try LogDriverOpaqueEffectTokenV1(validating: Data(secret.utf8))
        let source = try activeReaderSource()
        let call = try LogDriverReaderCallV1(
            readerSessionID: "reader-session",
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: "reader-provider",
            providerGeneration: 7,
            source: source,
            effectTokenMaterial: token
        )
        let acknowledgement = try LogDriverReaderAcknowledgementV1(
            call: call,
            observation: .closed,
            terminalOutcomeDigest: "sha256:closed"
        )

        #expect(acknowledgement.call.identity == call.identity)
        #expect(!String(describing: call).contains(secret))
        #expect(!String(reflecting: call).contains(secret))
        #expect(!String(describing: acknowledgement).contains(secret))
        #expect(!isEncodable(call))
        #expect(!isEncodable(acknowledgement))

        #expect(
            throws: LogDriverLifecycleContractError.invalidAcknowledgement(
                "closed reader observation requires a terminal outcome digest"
            )
        ) {
            try LogDriverReaderAcknowledgementV1(
                call: call,
                observation: .closed,
                terminalOutcomeDigest: nil
            )
        }
        #expect(
            throws: LogDriverLifecycleContractError.invalidAcknowledgement(
                "nonterminal reader observation cannot carry a terminal outcome digest"
            )
        ) {
            try LogDriverReaderAcknowledgementV1(
                call: call,
                observation: .active,
                terminalOutcomeDigest: "sha256:unexpected"
            )
        }
    }

    @Test func readerReceiptsKeepRawMaterialOutOfTextAndEncoding() throws {
        let secret = "reader-receipt-token"
        let receipt = LogDriverReaderOpenReceiptV1(
            request: try makeReaderOpenRequest(),
            effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(validating: Data(secret.utf8))
        )

        #expect(!String(describing: receipt).contains(secret))
        #expect(!String(reflecting: receipt).contains(secret))
        #expect(!isEncodable(receipt))
    }

    @Test func readRecordsPreservePresentationBytesAndEnforceBounds() throws {
        let timestamp = try ContainerLogTimestamp(secondsSinceUnixEpoch: 12, nanoseconds: 34)
        let presentation = Data([0x00, 0xff, UInt8(ascii: "\n")])
        let record = try ContainerLogReadRecordV1(
            stream: .stderr,
            timestamp: timestamp,
            data: presentation,
            attributes: ["label": "value"],
            sequence: 7,
            processGeneration: 9
        )

        #expect(record.data == presentation)
        #expect(record.stream == ContainerLogStream.stderr)
        #expect(record.timestamp == timestamp)
        #expect(record.attributes == ["label": "value"])
        #expect(record.sequence == 7)
        #expect(record.processGeneration == 9)
        #expect(ContainerLogReaderEventV1.record(record) == .record(record))

        #expect(
            throws: ContainerLogReadRecordError.dataTooLarge(
                maximumBytes: ContainerLogReadRecordV1.maximumDataBytes
            )
        ) {
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: timestamp,
                data: Data(
                    repeating: 0x41,
                    count: ContainerLogReadRecordV1.maximumDataBytes + 1
                ),
                sequence: 1
            )
        }
        #expect(throws: ContainerLogReadRecordError.invalidSequence) {
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: timestamp,
                data: Data(),
                sequence: 0
            )
        }
        #expect(throws: ContainerLogReadRecordError.invalidProcessGeneration) {
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: timestamp,
                data: Data(),
                sequence: 1,
                processGeneration: 0
            )
        }
        #expect(throws: ContainerLogReadRecordError.tooManyAttributes) {
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: timestamp,
                data: Data(),
                attributes: Dictionary(
                    uniqueKeysWithValues: (0...ContainerLogRecordV2.maximumAttributeCount)
                        .map { ("key-\($0)", "value") }
                ),
                sequence: 1
            )
        }
        #expect(throws: ContainerLogReadRecordError.attributesTooLarge) {
            try ContainerLogReadRecordV1(
                stream: .stdout,
                timestamp: timestamp,
                data: Data(),
                attributes: [
                    "key": String(
                        repeating: "x",
                        count: ContainerLogRecordV2.maximumAttributeUTF8Bytes
                    )
                ],
                sequence: 1
            )
        }
    }

    @Test func neutralSessionReaderAndProviderProtocolsAreUsable() async throws {
        let provider = FakeProvider()
        let request = try makeStartRequest()
        let started = try await provider.start(request)
        #expect(started.receipt.request == request)
        try await started.session.flush(deadline: .now)
        try await started.session.close(deadline: .now)

        let readerRequest = try makeReaderOpenRequest()
        let opened = try await provider.openReader(readerRequest)
        #expect(opened.receipt.request == readerRequest)
        #expect(try await opened.reader.next() == .endOfStream)
    }

    private func makeStartRequest(
        operationGeneration: UInt64 = 7,
        idempotencyKey: String = "start-operation-key",
        semanticRequestDigest: String = "sha256:start-request",
        sessionID: String = "writer-session",
        providerGeneration: UInt64 = 5
    ) throws -> LogDriverStartRequestV1 {
        try LogDriverStartRequestV1(
            operationGeneration: operationGeneration,
            idempotencyKey: idempotencyKey,
            semanticRequestDigest: semanticRequestDigest,
            sessionID: sessionID,
            containerID: "container-id",
            leaseGeneration: 3,
            candidateProcessGeneration: 11,
            providerID: "provider-id",
            providerGeneration: providerGeneration,
            candidateSandboxGeneration: 13
        )
    }

    private func makeReaderOpenRequest(
        operationGeneration: UInt64 = 8,
        semanticRequestDigest: String = "sha256:reader-request",
        read: ContainerLogReadRequest? = nil
    ) throws -> LogDriverReaderOpenRequestV1 {
        try LogDriverReaderOpenRequestV1(
            operationGeneration: operationGeneration,
            idempotencyKey: "reader-operation-key",
            semanticRequestDigest: semanticRequestDigest,
            readerSessionID: "reader-session",
            containerID: "container-id",
            leaseGeneration: 3,
            providerID: "reader-provider",
            providerGeneration: 7,
            source: activeReaderSource(),
            read: read ?? ContainerLogReadRequest()
        )
    }

    private func activeReaderSource() throws -> LoggingReaderSourceV1 {
        try LoggingReaderSourceV1(
            activeWriterSessionID: "writer-session",
            writerProviderID: "writer-provider",
            writerProviderGeneration: 5,
            activeProcessGeneration: 11,
            activeSandboxGeneration: 13
        )
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func isEncodable(_ value: Any) -> Bool {
        value is any Encodable
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private actor FakeSession: ContainerLogDriverSession {
    func write(_ record: ContainerLogRecordV2) async throws {}

    func flush(deadline: ContinuousClock.Instant) async throws {}

    func close(deadline: ContinuousClock.Instant) async throws {}
}

private actor FakeReader: ContainerLogReader {
    func next() async throws -> ContainerLogReaderEventV1 {
        .endOfStream
    }

    func cancel() async {}
}

private actor FakeProvider: ContainerLogDriverProvider {
    var descriptor: LogDriverDescriptor {
        get async throws {
            BuiltinLogDriverDescriptors.jsonFile
        }
    }

    func start(_ request: LogDriverStartRequestV1) async throws -> StartedLogDriverSessionV1 {
        StartedLogDriverSessionV1(
            receipt: LogDriverStartReceiptV1(
                request: request,
                effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(validating: Data())
            ),
            session: FakeSession()
        )
    }

    func reconcileStart(_ request: LogDriverStartRequestV1) async throws -> LogDriverStartReconciliationV1 {
        .absent
    }

    func reconcileSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .active,
            writerFenceReceiptDigest: nil
        )
    }

    func fenceSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .writerFenced,
            writerFenceReceiptDigest: "sha256:fence"
        )
    }

    func closeSession(
        _ request: LogDriverSessionCallV1
    ) async throws -> LogDriverSessionAcknowledgementV1 {
        try LogDriverSessionAcknowledgementV1(
            call: request,
            observation: .closed,
            writerFenceReceiptDigest: nil
        )
    }

    func openReader(_ request: LogDriverReaderOpenRequestV1) async throws -> StartedLogDriverReaderV1 {
        StartedLogDriverReaderV1(
            receipt: LogDriverReaderOpenReceiptV1(
                request: request,
                effectTokenMaterial: try LogDriverOpaqueEffectTokenV1(validating: Data())
            ),
            reader: FakeReader()
        )
    }

    func reconcileReaderOpen(
        _ request: LogDriverReaderOpenRequestV1
    ) async throws -> LogDriverReaderOpenReconciliationV1 {
        .absent
    }

    func reconcileReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: .active,
            terminalOutcomeDigest: nil
        )
    }

    func closeReader(
        _ request: LogDriverReaderCallV1
    ) async throws -> LogDriverReaderAcknowledgementV1 {
        try LogDriverReaderAcknowledgementV1(
            call: request,
            observation: .closed,
            terminalOutcomeDigest: "sha256:closed"
        )
    }
}
