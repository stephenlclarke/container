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

import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

private actor PreparationOverlapProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func begin() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }
}

private actor PreparationCancellationProbe {
    private(set) var cancelled = 0

    func recordCancellation() {
        cancelled += 1
    }
}

private enum PreparationTestError: Error {
    case expected
}

struct UtilityTests {

    @Test("A v2 logging request bypasses the legacy driver projection")
    func loggingV2UsesLegacyCompatibilityPlaceholder() throws {
        let request = ContainerLogRequest(
            driver: "acme.example/remote",
            options: ["advanced-option": "value"]
        )

        let configuration = try Utility.loggingConfiguration(
            request: request,
            legacyDriver: "acme.example/remote",
            legacyOptions: ["advanced-option=value"]
        )

        #expect(configuration == .default)
    }

    @Test("An absent v2 logging request retains legacy compatibility behavior")
    func absentLoggingV2RequestUsesLegacyProjection() throws {
        let configuration = try Utility.loggingConfiguration(
            request: nil,
            legacyDriver: "none",
            legacyOptions: []
        )

        #expect(configuration.storage == .none)
    }

    @Test("Prepare independent container resources concurrently")
    func testConcurrentContainerPreparation() async throws {
        let probe = PreparationOverlapProbe()

        let result = try await Utility.prepareConcurrently(
            {
                await probe.begin()
                try await Task.sleep(for: .milliseconds(50))
                await probe.end()
                return "image"
            },
            {
                await probe.begin()
                try await Task.sleep(for: .milliseconds(50))
                await probe.end()
                return "kernel"
            },
            {
                await probe.begin()
                try await Task.sleep(for: .milliseconds(50))
                await probe.end()
                return "init"
            }
        )

        #expect(result.0 == "image")
        #expect(result.1 == "kernel")
        #expect(result.2 == "init")
        #expect(await probe.maximumActive == 3)
    }

    @Test("Cancel remaining container preparation after a failure")
    func testConcurrentContainerPreparationCancellation() async {
        let probe = PreparationCancellationProbe()
        let failing: @Sendable () async throws -> String = {
            try await Task.sleep(for: .milliseconds(20))
            throw PreparationTestError.expected
        }
        let waiting: @Sendable () async throws -> String = {
            do {
                try await Task.sleep(for: .seconds(10))
                return "unexpected"
            } catch is CancellationError {
                await probe.recordCancellation()
                throw CancellationError()
            } catch {
                throw error
            }
        }

        do {
            _ = try await Utility.prepareConcurrently(failing, waiting, waiting)
            Issue.record("expected preparation failure")
        } catch PreparationTestError.expected {
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await probe.cancelled == 2)
    }

    @Test("Parse simple key-value pairs")
    func testSimpleKeyValuePairs() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["key2"] == "value2")
    }

    @Test("Parse standalone keys")
    func testStandaloneKeys() {
        let result = Utility.parseKeyValuePairs(["standalone"])

        #expect(result["standalone"] == "")
    }

    @Test("Parse key with an explicitly empty value")
    func testKeyWithEmptyValue() {
        let result = Utility.parseKeyValuePairs(["owner="])

        #expect(result["owner"] == "")
        #expect(result["owner="] == nil)
    }

    @Test("Parse empty input")
    func testEmptyInput() {
        let result = Utility.parseKeyValuePairs([])

        #expect(result.isEmpty)
    }

    @Test("Parse mixed format")
    func testMixedFormat() {
        let result = Utility.parseKeyValuePairs(["key1=value1", "standalone", "key2=value2"])

        #expect(result["key1"] == "value1")
        #expect(result["standalone"] == "")
        #expect(result["key2"] == "value2")
    }

    @Test("Valid MAC address with colons")
    func testValidMACAddressWithColons() throws {
        try Utility.validMACAddress("02:42:ac:11:00:02")
        try Utility.validMACAddress("AA:BB:CC:DD:EE:FF")
        try Utility.validMACAddress("00:00:00:00:00:00")
        try Utility.validMACAddress("ff:ff:ff:ff:ff:ff")
    }

    @Test("Valid MAC address with hyphens")
    func testValidMACAddressWithHyphens() throws {
        try Utility.validMACAddress("02-42-ac-11-00-02")
        try Utility.validMACAddress("AA-BB-CC-DD-EE-FF")
    }

    @Test("Invalid MAC address format")
    func testInvalidMACAddressFormat() {
        #expect(throws: Error.self) {
            try Utility.validMACAddress("invalid")
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00")  // Too short
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:02:03")  // Too long
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("ZZ:ZZ:ZZ:ZZ:ZZ:ZZ")  // Invalid hex
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02:42:ac:11:00:")  // Incomplete
        }
        #expect(throws: Error.self) {
            try Utility.validMACAddress("02.42.ac.11.00.02")  // Wrong separator
        }
    }

    @Test("Trim fully-qualified digest strips scheme and truncates to 12 chars")
    func testTrimDigestFullyQualified() {
        let hex = "0be69a25c33692845efb1e93f4254f28505a330896376bf8"
        #expect(Utility.trimDigest(digest: "sha256:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with unknown scheme strips scheme prefix")
    func testTrimDigestUnknownScheme() {
        let hex = "abcdef123456789012345678"
        #expect(Utility.trimDigest(digest: "blake3:\(hex)") == String(hex.prefix(12)))
    }

    @Test("Trim digest with no scheme truncates directly")
    func testTrimDigestNoScheme() {
        let hex = "abcdef1234567890"
        #expect(Utility.trimDigest(digest: hex) == String(hex.prefix(12)))
    }

    @Test("Trim digest shorter than 12 chars returns value unchanged")
    func testTrimDigestShort() {
        #expect(Utility.trimDigest(digest: "sha256:abc") == "abc")
    }

    @Test("Infrastructure image matching normalizes configured references")
    func infrastructureImageMatchingNormalizesConfiguredReferences() throws {
        let config = ContainerSystemConfig(
            build: BuildConfig(image: "custom-builder"),
            registry: RegistryConfig(domain: "registry.example.com"),
            vminit: VminitConfig(image: "custom-init")
        )

        #expect(
            try Utility.isInfraImage(
                name: "custom-builder:latest",
                containerSystemConfig: config
            )
        )
        #expect(
            try Utility.isInfraImage(
                name: "custom-builder:latest",
                containerSystemConfig: config
            )
        )
        #expect(
            try Utility.isInfraImage(
                name: "registry.example.com/custom-builder:latest",
                containerSystemConfig: config
            )
        )
        #expect(
            try Utility.isInfraImage(
                name: "custom-init",
                containerSystemConfig: config
            )
        )
        #expect(
            try Utility.isInfraImage(
                name: "custom-init:latest",
                containerSystemConfig: config
            )
        )
        #expect(
            try !Utility.isInfraImage(
                name: "registry.example.com/application:latest",
                containerSystemConfig: config
            )
        )
    }

    @Test("Image mounts project a snapshot as a read-only subpath mount")
    func imageMountFilesystemProjectsSnapshot() throws {
        let snapshot = Filesystem.block(
            format: "ext4",
            source: "/tmp/image-snapshot",
            destination: "/",
            options: []
        )
        let mount = try Utility.imageMountFilesystem(
            parsed: ParsedImageMount(
                reference: "example/assets:latest",
                destination: "/assets",
                options: [],
                subpath: "public"
            ),
            snapshot: snapshot
        )

        #expect(mount.type == snapshot.type)
        #expect(mount.source == snapshot.source)
        #expect(mount.destination == "/assets")
        #expect(mount.options == ["ro"])
        #expect(mount.sourceSubpath == "public")
    }

    @Test("Image mounts require a block-backed snapshot")
    func imageMountFilesystemRejectsNonBlockSnapshot() {
        let snapshot = Filesystem.virtiofs(source: "/tmp/image-snapshot", destination: "/", options: [])

        #expect {
            _ = try Utility.imageMountFilesystem(
                parsed: ParsedImageMount(reference: "example/assets:latest", destination: "/assets"),
                snapshot: snapshot
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("image mount snapshot must be a block filesystem")
        }
    }

    @Test
    func testValidEntityName() throws {
        try Utility.validEntityName("my-container")
        try Utility.validEntityName("test.container")
        try Utility.validEntityName("abc123")
        try Utility.validEntityName("a1")
        try Utility.validEntityName("container_1.test-abc")
    }

    @Test
    func testInvalidEntityName() {
        #expect(throws: Error.self) { try Utility.validEntityName("../../tmp/evil") }
        #expect(throws: Error.self) { try Utility.validEntityName("../foo") }
        #expect(throws: Error.self) { try Utility.validEntityName("foo/bar") }
        #expect(throws: Error.self) { try Utility.validEntityName("/tmp/evil") }
        #expect(throws: Error.self) { try Utility.validEntityName("") }
        #expect(throws: Error.self) { try Utility.validEntityName(".hidden") }
        #expect(throws: Error.self) { try Utility.validEntityName("-bad") }
        #expect(throws: Error.self) { try Utility.validEntityName("a") }
    }

    @Test
    func testPublishPortParser() throws {
        let ports = try Parser.publishPorts([
            "127.0.0.1:8000:9080",
            "8080-8179:9000-9099/udp",
        ])
        #expect(ports.count == 2)
        #expect(ports[0].hostAddress.description == "127.0.0.1")
        #expect(ports[0].hostPort == 8000)
        #expect(ports[0].containerPort == 9080)
        #expect(ports[0].proto == .tcp)
        #expect(ports[0].count == 1)
        #expect(ports[1].hostAddress.description == "0.0.0.0")
        #expect(ports[1].hostPort == 8080)
        #expect(ports[1].containerPort == 9000)
        #expect(ports[1].proto == .udp)
        #expect(ports[1].count == 100)
    }

    @Test
    func networkSelectionReturnsHostMode() throws {
        switch try Utility.networkSelection(["host"]) {
        case .host:
            break
        default:
            Issue.record("expected host network selection")
        }
    }

    @Test
    func networkSelectionReturnsNoNetworkMode() throws {
        switch try Utility.networkSelection(["none"]) {
        case .none:
            break
        default:
            Issue.record("expected none network selection")
        }
    }

    @Test
    func networkSelectionParsesAttachments() throws {
        switch try Utility.networkSelection(["backend,alias=api"]) {
        case .attachments(let networks):
            #expect(networks.count == 1)
            #expect(networks[0].name == "backend")
            #expect(networks[0].aliases == ["api"])
        default:
            Issue.record("expected attachment network selection")
        }
    }

    @Test
    func attachmentConfigurationsPreserveScopedDNSAliases() throws {
        let configurations = try Utility.getAttachmentConfigurations(
            containerId: "api",
            builtinNetworkId: "backend",
            networks: [try Parser.network("backend,dns-alias=database:db")],
            dnsDomain: nil
        )

        #expect(configurations.count == 1)
        #expect(configurations[0].options.scopedDNSAliases == ["database": "db"])
    }

    @Test
    func attachmentConfigurationsRejectCrossNetworkScopedDNSAliasConflicts() throws {
        #expect {
            _ = try Utility.getAttachmentConfigurations(
                containerId: "api",
                builtinNetworkId: "default",
                networks: [
                    try Parser.network("frontend,dns-alias=database:db"),
                    try Parser.network("backend,dns-alias=database:redis"),
                ],
                dnsDomain: nil
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("network DNS alias 'database' maps to both 'db' and 'redis'")
        }
    }

    @Test
    func networkSelectionRejectsHostMixedWithOtherNetworks() throws {
        #expect(throws: (any Error).self) {
            _ = try Utility.networkSelection(["host", "backend"])
        }
    }

    @Test
    func networkSelectionRejectsNoneMixedWithOtherNetworks() throws {
        #expect(throws: (any Error).self) {
            _ = try Utility.networkSelection(["none", "backend"])
        }
    }

    @Test
    func networkSelectionRejectsNoneWithAttachmentProperties() throws {
        #expect(throws: (any Error).self) {
            _ = try Utility.networkSelection(["none,alias=api"])
        }
    }
}
