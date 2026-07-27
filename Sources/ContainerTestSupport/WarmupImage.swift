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

/// Images preloaded by the ``ImageWarmup`` suite before concurrent tests run.
/// Add new commonly-used images here; the warmup pass pulls them in parallel.
public enum WarmupImage: String, CaseIterable, Sendable {
    case alpine320 = "ghcr.io/linuxcontainers/alpine:3.20"
    case alpine318 = "ghcr.io/linuxcontainers/alpine:3.18"
    case busybox136 = "ghcr.io/containerd/busybox:1.36"

    /// The locally prepared image used by integration tests.
    ///
    /// Alpine images use a distinct reference when the warmup adds certificates,
    /// preserving every platform variant under the canonical pulled reference.
    public var preparedReference: String {
        guard let bundlePath = ProcessInfo.processInfo.environment["CLITEST_CA_BUNDLE"],
            !bundlePath.isEmpty
        else {
            return rawValue
        }

        switch self {
        case .alpine320:
            return "registry.local/clitest-alpine:3.20-ca"
        case .alpine318:
            return "registry.local/clitest-alpine:3.18-ca"
        case .busybox136:
            return rawValue
        }
    }
}
