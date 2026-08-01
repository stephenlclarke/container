//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import Containerization
import Darwin
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

@Suite(.serialized)
struct ContainerLogRuntimePlanTests {
    @Test
    func planningIsPureAndRejectsTamperedAuthorityState() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let marker = fixture.bundle.path.appendingPathComponent("existing-marker")
        try Data("untouched".utf8).write(to: marker)
        let entriesBeforePlanning = try fixture.entryNames(at: fixture.bundle.path)

        _ = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(driver: "json-file")
        )
        #expect(try fixture.entryNames(at: fixture.bundle.path) == entriesBeforePlanning)

        #expect(throws: ContainerLogRuntimePlanError.incompleteConfiguration) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    leaseGeneration: 0
                )
            )
        }
        #expect(throws: ContainerLogRuntimePlanError.incompleteConfiguration) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    contractDigest: "sha256:tampered"
                )
            )
        }
        #expect(throws: ContainerLogRuntimePlanError.invalidContract) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    requestedDriver: "local"
                )
            )
        }
        #expect(throws: ContainerLogRuntimePlanError.invalidContract) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    delivery: LogDeliveryConfiguration(requestedMode: .nonBlocking)
                )
            )
        }
        #expect(throws: ContainerLogRuntimePlanError.invalidContract) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    readPolicy: LogReadPolicy(source: .unavailable)
                )
            )
        }
        #expect(throws: ContainerLogRuntimePlanError.invalidOption("max-size")) {
            try ContainerLogRuntimePlan(
                configuration: try loggingV2Configuration(
                    driver: "json-file",
                    options: ["max-size": "not-a-size"]
                )
            )
        }

        #expect(try fixture.entryNames(at: fixture.bundle.path) == entriesBeforePlanning)
        #expect(try Data(contentsOf: marker) == Data("untouched".utf8))
    }

    @Test
    func selectsDistinctLegacyNoneJSONFileAndLocalPlans() throws {
        var legacyConfiguration = testConfiguration()
        legacyConfiguration.logging = ContainerLogConfiguration(
            maxSizeInBytes: 12_345,
            maxFileCount: 7
        )
        let legacy = try ContainerLogRuntimePlan(configuration: legacyConfiguration)
        guard case .legacy(let maximumFileSize, let maximumFileCount) = legacy else {
            Issue.record("expected the legacy writer plan")
            return
        }
        #expect(maximumFileSize == 12_345)
        #expect(maximumFileCount == 7)

        let none = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(driver: "none")
        )
        guard case .none = none else {
            Issue.record("expected the none plan")
            return
        }

        let jsonFile = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(
                driver: "json-file",
                options: [
                    "compress": "false",
                    "max-file": "3",
                    "max-size": "2m",
                    "mode": "non-blocking",
                    "max-buffer-size": "64k",
                ]
            )
        )
        guard case .jsonFile(let jsonConfiguration, let jsonDelivery, let jsonAttributes) = jsonFile else {
            Issue.record("expected the json-file plan")
            return
        }
        #expect(jsonConfiguration.maximumFileSize == 2 * 1024 * 1024)
        #expect(jsonConfiguration.maximumFileCount == 3)
        #expect(!jsonConfiguration.compress)
        #expect(jsonDelivery.effectiveMode == .nonBlocking)
        #expect(jsonDelivery.effectiveMaxBufferSizeInBytes == 64 * 1024)
        #expect(jsonAttributes.isEmpty)

        let local = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(
                driver: "local",
                options: [
                    "compress": "false",
                    "max-file": "4",
                    "max-size": "3m",
                ]
            )
        )
        guard case .local(let localConfiguration, let localDelivery, let localAttributes) = local else {
            Issue.record("expected the local plan")
            return
        }
        #expect(localConfiguration.maximumFileSize == 3 * 1024 * 1024)
        #expect(localConfiguration.maximumFileCount == 4)
        #expect(!localConfiguration.compress)
        #expect(localDelivery.effectiveMode == .blocking)
        #expect(localAttributes.isEmpty)
    }

    @Test
    func noneActivationCreatesNoFilesOrProcessGeneration() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let marker = fixture.bundle.path.appendingPathComponent("existing-marker")
        try Data("untouched".utf8).write(to: marker)
        let entriesBeforeActivation = try fixture.entryNames(at: fixture.bundle.path)
        let plan = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(driver: "none")
        )

        let capture = try plan.activate(bundle: fixture.bundle, terminal: false)
        capture.close()

        #expect(capture.stdout == nil)
        #expect(capture.stderr == nil)
        #expect(capture.session == nil)
        #expect(capture.publicLogPath == nil)
        #expect(try fixture.entryNames(at: fixture.bundle.path) == entriesBeforeActivation)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.containerLoggingV2.path))
    }

    @Test
    func legacyActivationAppendsAcrossRestartAndKeepsV2StateAbsent() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        var configuration = testConfiguration()
        configuration.logging = ContainerLogConfiguration()
        let plan = try ContainerLogRuntimePlan(configuration: configuration)

        let first = try plan.activate(bundle: fixture.bundle, terminal: false)
        #expect(first.session == nil)
        #expect(first.publicLogPath == fixture.bundle.containerLog)
        try #require(first.stdout).write(Data("first\n".utf8))
        first.close()

        let second = try plan.activate(bundle: fixture.bundle, terminal: false)
        try #require(second.stderr).write(Data("second\n".utf8))
        second.close()

        #expect(
            try Data(contentsOf: fixture.bundle.containerLog)
                == Data("first\nsecond\n".utf8)
        )
        #expect(try Data(contentsOf: fixture.bundle.containerLogRecords).split(separator: UInt8(ascii: "\n")).count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.containerLoggingV2.path))
    }

    @Test
    func jsonFileActivationAppendsAcrossRestartAndAdvancesGeneration() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let plan = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(
                driver: "json-file",
                options: ["max-file": "2"]
            )
        )

        let first = try plan.activate(bundle: fixture.bundle, terminal: false)
        #expect(first.publicLogPath == fixture.bundle.containerJSONFileLog)
        #expect(first.session != nil)
        try #require(first.stdout).write(Data("first\n".utf8))
        first.close()

        let second = try plan.activate(bundle: fixture.bundle, terminal: false)
        try #require(second.stderr).write(Data("second\n".utf8))
        second.close()

        let reader = try DockerJSONFileLogReader(
            directoryURL: fixture.bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            maximumFileCount: 2
        )
        let result = try reader.read(DockerJSONFileLogReadRequest())
        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.stream) == [.stdout, .stderr])
        #expect(result.records.map(\.log) == [Data("first\n".utf8), Data("second\n".utf8)])

        let generationStore = try ContainerLogProcessGenerationStore(
            directoryURL: fixture.bundle.containerLoggingV2
        )
        #expect(try generationStore.next() == 3)
    }

    @Test
    func localActivationAppendsAcrossRestartWithoutPublishingPrivatePath() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let plan = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(
                driver: "local",
                options: [
                    "compress": "false",
                    "max-file": "3",
                    "max-size": "1m",
                ]
            )
        )

        let first = try plan.activate(bundle: fixture.bundle, terminal: false)
        #expect(first.publicLogPath == nil)
        try #require(first.stdout).write(Data("first\n".utf8))
        first.close()

        let second = try plan.activate(bundle: fixture.bundle, terminal: false)
        try #require(second.stderr).write(Data("second\n".utf8))
        second.close()

        let reader = try NativeLocalLogReader(
            directoryURL: fixture.bundle.containerNativeLocalLogDirectory,
            activeFileName: ContainerResource.Bundle.nativeLocalLogName,
            maximumFileCount: 3
        )
        let result = try reader.read(NativeLocalLogReadRequest())
        #expect(result.issues.isEmpty)
        #expect(result.records.map(\.stream) == [.stdout, .stderr])
        #expect(result.records.map(\.payload) == [Data("first".utf8), Data("second".utf8)])
        #expect(result.records.map(\.processGeneration) == [1, 2])
    }

    @Test
    func metadataSelectionUsesExactAndRegexMatchesWithEnvironmentPrecedence() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let configuration = try loggingV2Configuration(
            driver: "json-file",
            options: [
                "env": "shared,exact-env,EMPTY",
                "env-regex": "^REGEX_ENV$",
                "labels": "shared,exact-label",
                "labels-regex": "^regex-label$",
            ],
            labels: [
                "ignored-label": "ignored",
                "shared": "label-value",
                "exact-label": "label-exact",
                "regex-label": "label-regex",
            ],
            environment: [
                "ignored-env=ignored",
                "shared=environment-value",
                "exact-env=environment-exact",
                "REGEX_ENV=environment-regex",
                "EMPTY",
            ]
        )
        let plan = try ContainerLogRuntimePlan(configuration: configuration)
        let expectedAttributes = [
            "EMPTY": "",
            "REGEX_ENV": "environment-regex",
            "exact-env": "environment-exact",
            "exact-label": "label-exact",
            "regex-label": "label-regex",
            "shared": "environment-value",
        ]
        guard case .jsonFile(_, _, let attributes) = plan else {
            Issue.record("expected the json-file plan")
            return
        }
        #expect(attributes == expectedAttributes)

        let capture = try plan.activate(bundle: fixture.bundle, terminal: false)
        try #require(capture.stdout).write(Data("metadata\n".utf8))
        capture.close()
        let reader = try DockerJSONFileLogReader(
            directoryURL: fixture.bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            maximumFileCount: 1
        )
        let result = try reader.read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.attributes) == [expectedAttributes])
    }

    @Test
    func terminalActivationCapturesOnlyTheMergedStdoutStream() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        let plan = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(driver: "json-file")
        )

        let capture = try plan.activate(bundle: fixture.bundle, terminal: true)
        #expect(capture.stdout != nil)
        #expect(capture.stderr == nil)
        try #require(capture.stdout).write(Data("merged-terminal-output\n".utf8))
        capture.close()

        let session = try #require(capture.session)
        #expect(session.snapshot.closed)
        #expect(session.snapshot.closedStreams == Set([.stdout]))
        let reader = try DockerJSONFileLogReader(
            directoryURL: fixture.bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            maximumFileCount: 1
        )
        let result = try reader.read(DockerJSONFileLogReadRequest())
        #expect(result.records.map(\.stream) == [.stdout])
        #expect(result.records.map(\.log) == [Data("merged-terminal-output\n".utf8)])
    }

    @Test
    func failedActivationLeavesNoWriterArtifactsAndNeverReusesReservedGeneration() throws {
        let fixture = try RuntimePlanFixture()
        defer { fixture.remove() }
        try fixture.createSecureDirectory(at: fixture.bundle.containerLoggingV2)
        let symlinkTarget = fixture.bundle.path.appendingPathComponent("symlink-target", isDirectory: true)
        try fixture.createSecureDirectory(at: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            at: fixture.bundle.containerJSONFileLogDirectory,
            withDestinationURL: symlinkTarget
        )
        let plan = try ContainerLogRuntimePlan(
            configuration: try loggingV2Configuration(driver: "json-file")
        )

        #expect(throws: (any Error).self) {
            try plan.activate(bundle: fixture.bundle, terminal: false)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.bundle.containerJSONFileLog.path))
        #expect(!FileManager.default.fileExists(atPath: symlinkTarget.appendingPathComponent("json.log").path))
        let loggingEntries = try fixture.entryNames(at: fixture.bundle.containerLoggingV2)
        #expect(!loggingEntries.contains(where: { $0.contains(".tmp.") }))
        let generationStore = try ContainerLogProcessGenerationStore(
            directoryURL: fixture.bundle.containerLoggingV2
        )
        #expect(try generationStore.next() == 2)
    }

    private func loggingV2Configuration(
        driver: String,
        options: [String: String] = [:],
        labels: [String: String] = [:],
        environment: [String] = [],
        leaseGeneration: UInt64 = 1,
        requestedDriver: String? = nil,
        contractDigest: String? = nil,
        delivery: LogDeliveryConfiguration? = nil,
        readPolicy: LogReadPolicy? = nil
    ) throws -> ContainerConfiguration {
        let descriptor = try #require(BuiltinLogDriverDescriptors.current.descriptor(named: driver))
        let resolvedDelivery = try delivery ?? expectedDelivery(options: options)
        let resolvedReadPolicy =
            try readPolicy
            ?? LogReadPolicy(source: driver == "none" ? .unavailable : .direct)
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: leaseGeneration,
            driver: driver,
            safeOptions: options,
            delivery: resolvedDelivery,
            readPolicy: resolvedReadPolicy,
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: descriptor.providerGeneration,
            contractDigest: contractDigest ?? descriptor.optionContractDigest
        )
        let logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: requestedDriver ?? driver,
                options: options
            ),
            resolved: resolved
        )
        var configuration = testConfiguration(environment: environment)
        configuration.labels = labels
        configuration.logging = logging
        return configuration
    }

    private func expectedDelivery(
        options: [String: String]
    ) throws -> LogDeliveryConfiguration {
        let mode: LogDeliveryConfiguration.Mode?
        switch options["mode"] {
        case nil, "":
            mode = nil
        case "blocking":
            mode = .blocking
        case "non-blocking":
            mode = .nonBlocking
        default:
            mode = nil
        }
        let maximumBufferSize = options["max-buffer-size"].flatMap {
            ContainerLogOptionValueParser.sizeInBytes($0, allowingZero: true)
        }
        return try LogDeliveryConfiguration(
            requestedMode: mode,
            maxBufferSizeInBytes: maximumBufferSize
        )
    }

    private func testConfiguration(
        environment: [String] = []
    ) -> ContainerConfiguration {
        ContainerConfiguration(
            id: "runtime-plan-test",
            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "0", count: 64),
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: environment,
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0),
                supplementalGroups: [],
                rlimits: []
            )
        )
    }
}

private struct RuntimePlanFixture {
    let bundle: ContainerResource.Bundle

    init() throws {
        let temporaryRootPath = FileManager.default.temporaryDirectory.path
        let canonicalPointer = temporaryRootPath.withCString { Darwin.realpath($0, nil) }
        guard let canonicalPointer else {
            throw RuntimePlanFixtureError.canonicalTemporaryDirectory(errno)
        }
        let canonicalTemporaryRoot = URL(
            fileURLWithPath: String(cString: canonicalPointer),
            isDirectory: true
        )
        free(canonicalPointer)
        let path = canonicalTemporaryRoot.appendingPathComponent(
            "container-log-runtime-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        bundle = ContainerResource.Bundle(path: path)
        try createSecureDirectory(at: path)
    }

    func createSecureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    func entryNames(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: bundle.path)
    }
}

private enum RuntimePlanFixtureError: Error {
    case canonicalTemporaryDirectory(Int32)
}
