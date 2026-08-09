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

@testable import DockerSemanticHelper

@Suite("Docker semantic helper client", .serialized)
struct DockerSemanticHelperClientTests {
    @Test("verified helper performs pinned Go semantics")
    func verifiedHelperPerformsPinnedSemantics() throws {
        let client = try makeClient(generation: 1)

        #expect(client.manifest.goVersion == "go1.25.6")
        #expect(
            client.manifest.mobyCommit
                == "6bc6209b88a7a834c91f77d848e025c79e0227a1"
        )
        #expect(
            client.manifest.mobyGCPLoggingSHA256
                == "07e3f6d88058802bb5c28fe40905c0ff8e458c4df47e0d6303eeedb26c23b659"
        )
        #expect(
            try client.matchRegularExpression(
                pattern: Data("^(?:foo|bar)[0-9]+$".utf8),
                candidates: [
                    Data("foo12".utf8),
                    Data("bar".utf8),
                    Data("bar9".utf8),
                ]
            ) == [true, false, true]
        )

        let info = templateInfo()
        #expect(
            try client.renderLogTemplate(
                template: Data(),
                info: info,
                configuration: []
            ) == Data("0123456789ab".utf8)
        )
        #expect(
            try client.renderLogTemplate(
                template: Data(
                    "{{.Name}}|{{.Command}}|{{.ImageID}}|{{.Hostname}}".utf8
                ),
                info: info,
                configuration: []
            ) == Data("alpha|/bin/sh -c echo ok|abcdef012345|engine-host".utf8)
        )
    }

    @Test("address and URL operations retain Go results")
    func addressAndURLSemantics() throws {
        let client = try makeClient(generation: 2)

        #expect(
            try client.parseFluentdAddress(Data("localhost:1234".utf8))
                == DockerFluentdAddress(
                    networkProtocol: Data("tcp".utf8),
                    host: Data("localhost".utf8),
                    port: 1234,
                    path: Data()
                )
        )
        #expect(
            try client.parseGELFAddress(Data("udp://127.0.0.1:12201".utf8))
                == DockerGELFAddress(
                    scheme: Data("udp".utf8),
                    address: Data("127.0.0.1:12201".utf8),
                    host: Data("127.0.0.1".utf8),
                    port: 12_201
                )
        )
        #expect(
            try client.parseSyslogAddress(Data("tcp+tls://[::1]:1514".utf8))
                == DockerSyslogAddress(
                    networkProtocol: Data("tcp+tls".utf8),
                    address: Data("[::1]:1514".utf8),
                    host: Data("::1".utf8),
                    port: 1_514
                )
        )
        #expect(throws: DockerSemanticHelperRemoteError.self) {
            try client.parseSyslogAddress(Data("tcp+tls://[::1]".utf8))
        }

        let parsed = try client.parseURL(
            Data("tcp://user:p%40ss@[::1]:24224/a%2Fb?x=1#f".utf8)
        )
        #expect(parsed.scheme == Data("tcp".utf8))
        #expect(parsed.username == Data("user".utf8))
        #expect(parsed.password == Data("p@ss".utf8))
        #expect(parsed.passwordIsSet)
        #expect(parsed.host == Data("[::1]:24224".utf8))
        #expect(parsed.path == Data("/a/b".utf8))
        #expect(parsed.rawPath == Data("/a%2Fb".utf8))
        #expect(parsed.hostname == Data("::1".utf8))
        #expect(parsed.port == Data("24224".utf8))
    }

    @Test("Go failures stay typed and do not fence a healthy generation")
    func remoteFailuresDoNotFenceGeneration() throws {
        let client = try makeClient(generation: 3)

        do {
            _ = try client.matchRegularExpression(
                pattern: Data("a(?=b)".utf8),
                candidates: []
            )
            Issue.record("lookahead unexpectedly compiled")
        } catch let error as DockerSemanticHelperRemoteError {
            #expect(error.category == .parse)
            #expect(!error.messageBytes.isEmpty)
            #expect(!error.description.contains(String(decoding: error.messageBytes, as: UTF8.self)))
        }

        #expect(
            try client.matchRegularExpression(
                pattern: Data(".".utf8),
                candidates: [Data([0xff])]
            ) == [true]
        )

        do {
            _ = try client.renderLogTemplate(
                template: Data(#"{{printf "%2097153s" "x"}}"#.utf8),
                info: templateInfo(),
                configuration: []
            )
            Issue.record("oversized output unexpectedly rendered")
        } catch let error as DockerSemanticHelperRemoteError {
            #expect(error.category == .outputLimit)
        }
    }

    @Test("shared processes are generation scoped and retirement is permanent")
    func generationScopedPoolAndRetirement() throws {
        let launch = try DockerSemanticHelperLaunchConfiguration.discover()
        let firstGeneration = DockerSemanticHelperGeneration(
            providerID: "test.pool",
            providerGeneration: 1
        )
        let nextGeneration = DockerSemanticHelperGeneration(
            providerID: "test.pool",
            providerGeneration: 2
        )

        let first = try DockerSemanticHelperClient.shared(
            for: firstGeneration,
            launchConfiguration: launch
        )
        let repeated = try DockerSemanticHelperClient.shared(
            for: firstGeneration,
            launchConfiguration: launch
        )
        let next = try DockerSemanticHelperClient.shared(
            for: nextGeneration,
            launchConfiguration: launch
        )

        #expect(first === repeated)
        #expect(first !== next)
        DockerSemanticHelperClient.retireSharedGeneration(firstGeneration)
        #expect(throws: DockerSemanticHelperError.generationFenced) {
            try first.parseURL(Data("tcp://localhost:1".utf8))
        }
        #expect(throws: DockerSemanticHelperError.generationFenced) {
            try DockerSemanticHelperClient.shared(
                for: firstGeneration,
                launchConfiguration: launch
            )
        }
        #expect(
            try next.parseURL(Data("tcp://localhost:2".utf8)).port
                == Data("2".utf8)
        )

        DockerSemanticHelperClient.retireSharedGeneration(nextGeneration)
        #expect(throws: DockerSemanticHelperError.generationFenced) {
            try DockerSemanticHelperClient.shared(
                for: nextGeneration,
                launchConfiguration: launch
            )
        }
    }

    @Test("fencing terminates the helper and rejects later work")
    func explicitFenceIsPermanent() throws {
        let client = try makeClient(generation: 4)
        client.cancelAndFenceGeneration()

        #expect(throws: DockerSemanticHelperError.generationFenced) {
            try client.matchRegularExpression(
                pattern: Data(".".utf8),
                candidates: []
            )
        }
    }

    @Test("GCP lifecycle requests retain typed remote failures")
    func gcpLifecycleRemoteFailure() throws {
        let client = try makeClient(generation: 5)
        do {
            try client.startGCPLoggingSession(
                sessionID: "gcp-test",
                configuration: [],
                info: templateInfo(),
                timeout: .seconds(5)
            )
            Issue.record("gcplogs start without a project unexpectedly passed")
        } catch let error as DockerSemanticHelperRemoteError {
            #expect(error.category == .execute)
            #expect(!error.messageBytes.isEmpty)
        }
        #expect(
            try client.parseURL(Data("tcp://localhost:3".utf8)).port
                == Data("3".utf8)
        )
    }

    @Test("manifest digest mismatch fails before process launch")
    func manifestDigestMismatch() throws {
        let launch = try DockerSemanticHelperLaunchConfiguration.discover()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent(
            DockerSemanticHelperLaunchConfiguration.executableName
        )
        let manifest = directory.appendingPathComponent(
            DockerSemanticHelperLaunchConfiguration.manifestName
        )
        try FileManager.default.copyItem(
            at: launch.executableURL,
            to: executable
        )
        var manifestObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: launch.manifestURL)
            ) as? [String: Any]
        )
        manifestObject["binarySHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifest)

        #expect(throws: DockerSemanticHelperError.binaryDigestMismatch) {
            try DockerSemanticHelperClient(
                generation: DockerSemanticHelperGeneration(
                    providerID: "test.invalid-manifest",
                    providerGeneration: 1
                ),
                launchConfiguration: DockerSemanticHelperLaunchConfiguration(
                    executableURL: executable,
                    manifestURL: manifest,
                    verifyCodeSignature: false
                )
            )
        }
    }

    private func makeClient(
        generation: UInt64
    ) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClient(
            generation: DockerSemanticHelperGeneration(
                providerID: "test.client.\(generation)",
                providerGeneration: generation
            ),
            launchConfiguration: .discover()
        )
    }

    private func templateInfo() -> DockerLogTemplateInfo {
        DockerLogTemplateInfo(
            containerID:
                "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            containerName: "/alpha",
            containerEntrypoint: "/bin/sh",
            containerArguments: ["-c", "echo ok"],
            containerImageID:
                "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
            containerImageName: "example/image:latest",
            containerCreated: Date(timeIntervalSince1970: 1_234_567_890.123_456_7),
            daemonName: "dockerd",
            hostname: "engine-host"
        )
    }
}
