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

struct ContainerLifecycleStateV2Tests {
    @Test
    func migrationProducesStableImmutableIdentity() {
        let legacy = ContainerLifecycleStateV1(
            startedDate: Date(timeIntervalSince1970: 10),
            exitCode: 17,
            exitedDate: Date(timeIntervalSince1970: 20)
        )
        let first = ContainerLifecycleRecordV2.migrate(
            bundleKey: "bundle-key",
            canonicalName: "api",
            selectedProviderFingerprint: "provider-a",
            legacy: legacy
        )
        let renamed = ContainerLifecycleRecordV2.migrate(
            bundleKey: "bundle-key",
            canonicalName: "renamed-api",
            selectedProviderFingerprint: "provider-a",
            legacy: legacy
        )

        #expect(first.containerID.count == 64)
        #expect(first.containerID == renamed.containerID)
        #expect(first.canonicalName != renamed.canonicalName)
        #expect(first.snapshot.state == .exited)
        #expect(first.snapshot.exitCode == 17)
    }

    @Test
    func durableRecordRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "container-lifecycle-v2-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = ContainerResource.Bundle(path: directory)
        let record = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "api",
            immutableBundleKey: "bundle-key",
            selectedProviderFingerprint: "provider-a",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .paused,
                running: true,
                paused: true,
                oomKilled: true,
                oomKillCountBaseline: 4,
                processGeneration: 2,
                transitionRevision: 9,
                operationGeneration: 11
            )
        )

        try bundle.setDurably(lifecycleRecordV2: record)

        #expect(try bundle.lifecycleRecordV2 == record)
    }

    @Test
    func recordsWithoutRestartFailureStateRemainDecodable() throws {
        let record = ContainerLifecycleRecordV2.migrate(
            bundleKey: "legacy-v2",
            canonicalName: "legacy-v2",
            selectedProviderFingerprint: "provider-a",
            legacy: nil
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var snapshot = try #require(object["snapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "restartConsecutiveFailureCount")
        object["snapshot"] = snapshot

        let decoded = try JSONDecoder().decode(
            ContainerLifecycleRecordV2.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.snapshot.restartConsecutiveFailureCount == nil)
    }
}
