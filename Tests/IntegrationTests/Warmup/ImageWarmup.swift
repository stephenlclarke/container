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

import ContainerTestSupport
import Foundation
import Testing

/// Pulls each image in ``WarmupImage`` in parallel before concurrent
/// integration tests run. The Makefile's warmup pass runs this suite first
/// so that ``ContainerFixture/copyWarmupImage(_:)`` can tag from a
/// pre-populated store rather than pulling on demand, and so that
/// ``ContainerFixture/restoreWarmupImage(_:)`` has a cached tar archive to
/// reload from after a serial test wipes the image store.
///
/// When `CLITEST_CA_BUNDLE` names a readable PEM bundle, Alpine warmup images
/// are rebuilt locally with those additional certificates. This keeps HTTPS
/// integration tests deterministic on networks that terminate TLS.
@Suite
struct ImageWarmup {
    @Test(arguments: WarmupImage.allCases)
    func pull(image: WarmupImage) async throws {
        try await ContainerFixture.with { f in
            try f.run(["image", "pull", image.rawValue]).check("failed to pull \(image.rawValue)")
            try installAdditionalCertificates(in: image, fixture: f)
            try f.cacheWarmupImage(image)
        }
    }

    private func installAdditionalCertificates(
        in image: WarmupImage,
        fixture: ContainerFixture
    ) throws {
        switch image {
        case .alpine318, .alpine320:
            break
        case .busybox136, .kindestNodeV1_35_5:
            return
        }

        guard let bundlePath = ProcessInfo.processInfo.environment["CLITEST_CA_BUNDLE"],
            !bundlePath.isEmpty
        else {
            return
        }

        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw CommandError.executionFailed(
                "CLITEST_CA_BUNDLE is not readable at \(bundleURL.path)")
        }

        let contextURL = URL(fileURLWithPath: fixture.testDir.string, isDirectory: true)
        let bundledCertificates = contextURL.appendingPathComponent("clitest-ca-bundle.pem")
        let dockerfile = contextURL.appendingPathComponent("Dockerfile")
        try Data(contentsOf: bundleURL).write(to: bundledCertificates)
        try """
        FROM \(image.rawValue)
        COPY clitest-ca-bundle.pem /tmp/clitest-ca-bundle.pem
        RUN cat /tmp/clitest-ca-bundle.pem >> /etc/ssl/certs/ca-certificates.crt \\
            && rm /tmp/clitest-ca-bundle.pem
        """.write(to: dockerfile, atomically: true, encoding: .utf8)

        try fixture.run(["build", "-t", image.preparedReference, fixture.testDir.string])
            .check("failed to install additional certificates in \(image.preparedReference)")
    }
}
