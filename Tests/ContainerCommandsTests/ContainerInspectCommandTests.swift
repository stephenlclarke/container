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
import ContainerizationError
import Testing

@testable import ContainerCommands

struct ContainerInspectCommandTests {
    @Test
    func inspectResolvesEveryStableLifecycleIdentity() throws {
        let lifecycle = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "renamed-api",
            immutableBundleKey: "demo-api-1",
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(state: .running)
        )

        let bundleKeys = try Application.ContainerInspect.resolveBundleKeys(
            identifiers: [
                lifecycle.containerID,
                lifecycle.canonicalName,
                lifecycle.immutableBundleKey,
                lifecycle.containerID,
            ],
            lifecycles: [lifecycle]
        )

        #expect(bundleKeys == [lifecycle.immutableBundleKey])
    }

    @Test
    func inspectRejectsUnknownLifecycleIdentity() {
        let lifecycle = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: "api",
            immutableBundleKey: "demo-api-1",
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(state: .running)
        )

        #expect(throws: ContainerizationError.self) {
            try Application.ContainerInspect.resolveBundleKeys(
                identifiers: ["missing"],
                lifecycles: [lifecycle]
            )
        }
    }
}
