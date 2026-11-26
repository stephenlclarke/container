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
import ContainerizationOCI
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

    @Test("Shared VM accepts host, none, and the built-in default network")
    func sharedVMNetworkCompatibility() throws {
        var management = isolationManagement(
            networks: [NetworkClient.noNetworkName]
        )

        try Utility.validateIsolationCompatibility(
            requestedIsolation: .sharedVM,
            requestedPlatform: .current,
            management: management
        )

        management.networks = []
        try Utility.validateIsolationCompatibility(
            requestedIsolation: .sharedVM,
            requestedPlatform: .current,
            management: management
        )

        management.networks = ["default,mtu=1400"]
        try Utility.validateIsolationCompatibility(
            requestedIsolation: .sharedVM,
            requestedPlatform: .current,
            management: management
        )

        management.networks = ["project-network"]
        let error = #expect(throws: ContainerizationError.self) {
            try Utility.validateIsolationCompatibility(
                requestedIsolation: .sharedVM,
                requestedPlatform: .current,
                management: management
            )
        }
        #expect(error?.code == .unsupported)
    }

    @Test("Dedicated VM retains existing configuration compatibility")
    func dedicatedVMCompatibilityIsUnrestricted() throws {
        let management = isolationManagement(
            networks: [],
            kernel: "/tmp/custom-kernel",
            virtualization: true
        )

        try Utility.validateIsolationCompatibility(
            requestedIsolation: .dedicatedVM,
            requestedPlatform: .current,
            management: management
        )
    }

    @Test("Shared VM rejects namespace and privilege escapes")
    func sharedVMRejectsNamespaceAndPrivilegeEscapes() throws {
        var management = isolationManagement(
            networks: [NetworkClient.noNetworkName]
        )
        management.userNamespace = "host"

        let namespaceError = #expect(throws: ContainerizationError.self) {
            try Utility.validateIsolationCompatibility(
                requestedIsolation: .sharedVM,
                requestedPlatform: .current,
                management: management
            )
        }
        #expect(namespaceError?.code == .unsupported)

        let privileged = ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: [],
            privileged: true
        )
        let privilegeError = #expect(throws: ContainerizationError.self) {
            try Utility.validateSharedProcessCompatibility(
                requestedIsolation: .sharedVM,
                process: privileged
            )
        }
        #expect(privilegeError?.code == .unsupported)
    }

    private func isolationManagement(
        networks: [String],
        kernel: String? = nil,
        virtualization: Bool = false
    ) -> Flags.Management {
        Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: [],
            capDrop: [],
            cidfile: "",
            detach: false,
            dns: .init(
                domain: nil,
                nameservers: [],
                options: [],
                searchDomains: []
            ),
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: kernel,
            kernelArgs: [],
            labels: [],
            maskedPaths: [],
            mounts: [],
            name: nil,
            networks: networks,
            os: "linux",
            platform: nil,
            publishPorts: [],
            publishSockets: [],
            readOnly: false,
            readonlyPaths: [],
            remove: false,
            rosetta: false,
            runtime: nil,
            ssh: false,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: virtualization,
            volumes: []
        )
    }

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

    @Test(
        "Split the image download cap across both image pipelines",
        arguments: [
            (maximum: 1, workload: 1, initImage: nil),
            (maximum: 2, workload: 1, initImage: 1),
            (maximum: 3, workload: 2, initImage: 1),
            (maximum: 8, workload: 4, initImage: 4),
        ]
    )
    func imageDownloadLimits(
        maximum: Int,
        workload: Int,
        initImage: Int?
    ) throws {
        let limits = try Utility.imageDownloadLimits(
            maxConcurrentDownloads: maximum
        )

        #expect(limits.workload == workload)
        #expect(limits.initImage == initImage)
        #expect(limits.workload + (limits.initImage ?? 0) <= maximum)
    }

    @Test("Reject a non-positive image download cap", arguments: [0, -1])
    func rejectNonPositiveImageDownloadLimit(_ maximum: Int) {
        let error = #expect(throws: ContainerizationError.self) {
            try Utility.imageDownloadLimits(maxConcurrentDownloads: maximum)
        }

        #expect(error?.code == .invalidArgument)
    }

    @Test("Validate network attachments from one network snapshot")
    func testBatchNetworkAttachmentValidation() throws {
        let attachments = [
            AttachmentConfiguration(network: "frontend", options: .init(hostname: "web")),
            AttachmentConfiguration(network: "backend", options: .init(hostname: "db")),
        ]

        try Utility.validateNetworkAttachments(
            attachments,
            availableNetworkIDs: ["frontend", "backend", "unused"]
        )
        do {
            try Utility.validateNetworkAttachments(
                attachments,
                availableNetworkIDs: ["frontend"]
            )
            Issue.record("expected missing network error")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
            #expect(error.message == "network backend not found")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
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
    func testDNSConfigurationUsesDefaultsWhenFlagsAbsent() {
        let defaults = ContainerDNSConfig(
            domain: "corp.local",
            nameservers: ["1.1.1.1"],
            searchDomains: ["corp.local"],
            options: ["ndots:2"]
        )

        let flags = Flags.DNS(
            domain: nil,
            nameservers: [],
            options: [],
            searchDomains: []
        )

        let result = Utility.dnsConfiguration(from: flags, defaults: defaults)

        #expect(result.domain == "corp.local")
        #expect(result.nameservers == ["1.1.1.1"])
        #expect(result.searchDomains == ["corp.local"])
        #expect(result.options == ["ndots:2"])
    }

    @Test
    func testDNSConfigurationFlagsOverrideDefaults() {
        let defaults = ContainerDNSConfig(
            domain: "corp.local",
            nameservers: ["1.1.1.1"],
            searchDomains: ["corp.local"],
            options: ["ndots:2"]
        )
        let flags = Flags.DNS(
            domain: "cli.local",
            nameservers: ["8.8.8.8"],
            options: ["debug"],
            searchDomains: ["cli.local"]
        )

        let result = Utility.dnsConfiguration(from: flags, defaults: defaults)

        #expect(result.domain == "cli.local")
        #expect(result.nameservers == ["8.8.8.8"])
        #expect(result.searchDomains == ["cli.local"])
        #expect(result.options == ["debug"])
    }

    @Test
    func testDNSConfigurationPartialFlagsFallbackToDefaults() {
        let defaults = ContainerDNSConfig(
            domain: "corp.local",
            nameservers: ["1.1.1.1"],
            searchDomains: ["corp.local"],
            options: ["ndots:2"]
        )
        let flags = Flags.DNS(
            domain: nil,
            nameservers: ["8.8.8.8"],
            options: [],
            searchDomains: []
        )

        let result = Utility.dnsConfiguration(from: flags, defaults: defaults)

        #expect(result.domain == "corp.local")
        #expect(result.nameservers == ["8.8.8.8"])
        #expect(result.searchDomains == ["corp.local"])
        #expect(result.options == ["ndots:2"])
    }

    @Test
    func testDNSConfigurationDomainFallsBackToHostDomain() {
        let defaults = ContainerDNSConfig()
        let flags = Flags.DNS(
            domain: nil,
            nameservers: [],
            options: [],
            searchDomains: []
        )

        let result = Utility.dnsConfiguration(from: flags, defaults: defaults, hostDomainFallback: "host.local")

        #expect(result.domain == "host.local")
    }

    @Test
    func testDNSConfigurationContainerDomainWinsOverHostDomain() {
        let defaults = ContainerDNSConfig(domain: "container.local")
        let flags = Flags.DNS(
            domain: nil,
            nameservers: [],
            options: [],
            searchDomains: []
        )

        let result = Utility.dnsConfiguration(from: flags, defaults: defaults, hostDomainFallback: "host.local")

        #expect(result.domain == "container.local")
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

    @Test("Aliases from the network specification land on the attachment they were declared for")
    func testAttachmentConfigurationsCarryAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api.test", ".foo.test"]),
            Parser.ParsedNetwork(name: "backend"),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments.count == 2)
        #expect(attachments[0].network == "default")
        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].network == "backend")
        #expect(attachments[1].options.hostname == "foo")
        #expect(attachments[1].options.aliases.isEmpty)
    }

    @Test("Aliases are carried to a later attachment")
    func testAttachmentConfigurationsCarryAliasesOnLaterNetworks() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default"),
            Parser.ParsedNetwork(name: "backend", aliases: ["db.internal"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.aliases.isEmpty)
        #expect(attachments[1].options.aliases == ["db.internal"])
    }

    @Test("A container with no network specification has no aliases")
    func testDefaultAttachmentHasNoAliases() throws {
        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: [],
            dnsDomain: "test"
        )

        #expect(attachments.count == 1)
        #expect(attachments[0].options.aliases.isEmpty)
    }

    @Test("Aliases without a domain get the default domain")
    func testQualifyAliasesAddsTheDefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "test")

        #expect(aliases == ["api.test", ".gateway.test"])
    }

    @Test("Aliases with a dot are taken to be qualified")
    func testQualifyAliasesLeavesQualifiedNamesAlone() throws {
        let aliases = try Utility.qualifyAliases(["web.internal", ".a.b", "api.test"], dnsDomain: "test")

        #expect(aliases == ["web.internal", ".a.b", "api.test"])
    }

    @Test("Aliases are left as they are without a default domain")
    func testQualifyAliasesWithoutADefaultDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway", "web.internal"], dnsDomain: nil)

        #expect(aliases == ["api", ".gateway", "web.internal"])
    }

    @Test("No aliases stay empty")
    func testQualifyAliasesWithNoAliases() throws {
        #expect(try Utility.qualifyAliases([], dnsDomain: "test").isEmpty)
        #expect(try Utility.qualifyAliases([], dnsDomain: nil).isEmpty)
    }

    @Test("The default domain is normalized when it is added")
    func testQualifyAliasesNormalizesTheDomain() throws {
        let aliases = try Utility.qualifyAliases(["api", ".gateway"], dnsDomain: "Example.TEST.")

        #expect(aliases == ["api.example.test", ".gateway.example.test"])
    }

    @Test("A default domain that is not a valid name is reported")
    func testQualifyAliasesWithAnInvalidDomain() {
        #expect(throws: (any Error).self) {
            try Utility.qualifyAliases(["api"], dnsDomain: "not a domain")
        }
    }

    @Test("Aliases in a network specification are qualified when the attachments are built")
    func testAttachmentConfigurationsQualifyAliases() throws {
        let networks = [
            Parser.ParsedNetwork(name: "default", aliases: ["api", ".foo"]),
            Parser.ParsedNetwork(name: "backend", aliases: ["db"]),
        ]

        let attachments = try Utility.getAttachmentConfigurations(
            containerId: "foo",
            builtinNetworkId: "default",
            networks: networks,
            dnsDomain: "test"
        )

        #expect(attachments[0].options.hostname == "foo.test.")
        #expect(attachments[0].options.aliases == ["api.test", ".foo.test"])
        #expect(attachments[1].options.aliases == ["db.test"])
    }
}
