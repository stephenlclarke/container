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
import ContainerResource
import Foundation
import Testing

@testable import ContainerAPIService

struct LoggingHandoffBundleHistoryPublisherTests {
    @Test
    func `publishes exact immutable history and replays without mutation`() throws {
        try withBundle { bundle in
            let active = segment(
                entryID: "active",
                rotationIndex: 0,
                bytes: Data("active-history".utf8)
            )
            let rotated = segment(
                entryID: "rotated",
                rotationIndex: 1,
                compressed: true,
                bytes: Data("compressed-history".utf8)
            )
            let segments = [rotated, active]

            try LoggingHandoffBundleHistoryPublisher.publish(
                bundle: bundle,
                segments: segments,
                transactionID: "token:manifest:container"
            )
            try LoggingHandoffBundleHistoryPublisher.publish(
                bundle: bundle,
                segments: segments,
                transactionID: "token:manifest:container"
            )

            let activeURL = bundle.containerNativeLocalLog
            let rotatedURL = bundle.containerNativeLocalLogDirectory
                .appendingPathComponent("local.bin.1.gz")
            #expect(try Data(contentsOf: activeURL) == active.bytes)
            #expect(try Data(contentsOf: rotatedURL) == rotated.bytes)
            #expect(try permissions(bundle.containerLoggingV2) == 0o700)
            #expect(
                try permissions(bundle.containerNativeLocalLogDirectory)
                    == 0o700
            )
            #expect(try permissions(activeURL) == 0o600)
            #expect(try permissions(rotatedURL) == 0o600)
            #expect(
                try Set(
                    FileManager.default.contentsOfDirectory(
                        atPath: bundle.containerLoggingV2.path
                    )
                ) == ["local"]
            )
        }
    }

    @Test
    func `refuses a different history for an already published target`() throws {
        try withBundle { bundle in
            let original = segment(
                entryID: "active",
                rotationIndex: 0,
                bytes: Data("original".utf8)
            )
            try LoggingHandoffBundleHistoryPublisher.publish(
                bundle: bundle,
                segments: [original],
                transactionID: "transaction-one"
            )
            let conflicting = segment(
                entryID: "active",
                rotationIndex: 0,
                bytes: Data("different".utf8)
            )

            #expect(
                throws: LoggingHandoffBundleHistoryPublisherError.collision
            ) {
                try LoggingHandoffBundleHistoryPublisher.publish(
                    bundle: bundle,
                    segments: [conflicting],
                    transactionID: "transaction-two"
                )
            }
            #expect(
                try Data(contentsOf: bundle.containerNativeLocalLog)
                    == original.bytes
            )
        }
    }

    @Test
    func `rejects mixed local store kinds before creating effects`() throws {
        try withBundle { bundle in
            let local = segment(
                entryID: "local",
                rotationIndex: 0,
                bytes: Data("local".utf8)
            )
            let cache = segment(
                entryID: "cache",
                kind: .dualCache,
                rotationIndex: 0,
                bytes: Data("cache".utf8)
            )

            #expect(
                throws: LoggingHandoffBundleHistoryPublisherError.invalidHistory
            ) {
                try LoggingHandoffBundleHistoryPublisher.publish(
                    bundle: bundle,
                    segments: [local, cache],
                    transactionID: "mixed"
                )
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: bundle.containerLoggingV2.path
                )
            )
        }
    }

    private func segment(
        entryID: String,
        kind: LoggingHandoffHistoryKindV1 = .nativeLocal,
        rotationIndex: UInt64,
        compressed: Bool = false,
        bytes: Data
    ) -> LoggingHandoffPromotedHistorySegmentV1 {
        LoggingHandoffPromotedHistorySegmentV1(
            entryID: entryID,
            storeID: "store-\(entryID)",
            kind: kind,
            rotationIndex: rotationIndex,
            compressed: compressed,
            terminalHistoryEpoch: 12,
            maximumInternalSequence: 99,
            contentDigestSHA256: ProviderHandoffDigest.sha256(bytes),
            bytes: bytes
        )
    }

    private func withBundle<Result>(
        _ body: (ContainerResource.Bundle) throws -> Result
    ) throws -> Result {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "logging-handoff-publisher-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "container",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        return try body(ContainerResource.Bundle(path: bundleURL))
    }

    private func permissions(_ url: URL) throws -> Int {
        let value =
            try FileManager.default.attributesOfItem(
                atPath: url.path
            )[.posixPermissions] as? NSNumber
        return try #require(value?.intValue)
    }
}
