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

import ContainerAPIClient
import ContainerEngineLogging
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerEngineWire
import ContainerPersistence
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerLoggingStorage
@testable import ContainerPlugin

struct ContainerLogsTests {
    @Test func configuredUnreadableDriverUsesUnsupportedPublicError() {
        let error = ContainersService.logReadError(
            ContainerLogReaderError.configuredDriverDoesNotSupportReading,
            operation: "open container logs"
        )

        #expect(error.code == .unsupported)
        #expect(error.message == "configured logging driver does not support reading")
    }

    @Test func otherLogReadFailuresRetainOperationContext() {
        struct FixtureError: Error {}

        let error = ContainersService.logReadError(
            FixtureError(),
            operation: "follow container logs"
        )

        #expect(error.code == .internalError)
        #expect(error.message == "failed to follow container logs: FixtureError()")
    }

    @Test func decodesAndFiltersTimestampedLogRecords() throws {
        let first = ContainerLogRecord(
            timestamp: date("2026-01-02T00:00:00Z"),
            stream: .stdout,
            data: Data("first\n".utf8)
        )
        let second = ContainerLogRecord(
            timestamp: date("2026-01-03T00:00:00Z"),
            stream: .stderr,
            data: Data("second\n".utf8)
        )
        let third = ContainerLogRecord(
            timestamp: date("2026-01-04T00:00:00Z"),
            stream: .stdout,
            data: Data("third\n".utf8)
        )
        let options = ContainerLogOptions(
            tail: 1,
            since: date("2026-01-02T12:00:00Z"),
            until: date("2026-01-04T00:00:00Z")
        )

        let records = try ContainersService.filteredLogRecords(
            logRecordData([first, second, third]),
            options: options
        )

        #expect(records == [third])
    }

    @Test func recordTailZeroDropsExistingRecords() {
        let records = [
            ContainerLogRecord(
                timestamp: date("2026-01-02T00:00:00Z"),
                stream: .stdout,
                data: Data("first".utf8)
            ),
            ContainerLogRecord(
                timestamp: date("2026-01-03T00:00:00Z"),
                stream: .stdout,
                data: Data("-line\n".utf8)
            ),
        ]

        let filtered = ContainersService.filteredLogRecords(records, options: ContainerLogOptions(tail: 0))

        #expect(filtered.isEmpty)
    }

    @Test func recordTailFiltersAfterRebuildingLogicalLines() {
        let first = date("2026-01-01T00:00:00Z")
        let second = date("2026-01-02T00:00:00Z")
        let records = [
            ContainerLogRecord(timestamp: first, stream: .stdout, data: Data("one\npa".utf8)),
            ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("rt\ntwo\nthree".utf8)),
            ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("-tail\n".utf8)),
        ]

        let filtered = ContainersService.filteredLogRecords(records, options: ContainerLogOptions(tail: 2))

        #expect(
            filtered == [
                ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("two\n".utf8)),
                ContainerLogRecord(timestamp: second, stream: .stdout, data: Data("three-tail\n".utf8)),
            ])
    }

    @Test func recordTimeFiltersAfterRebuildingLogicalLines() {
        let before = date("2026-01-01T00:00:00Z")
        let inside = date("2026-01-02T00:00:00Z")
        let after = date("2026-01-03T00:00:00Z")
        let records = [
            ContainerLogRecord(timestamp: before, stream: .stdout, data: Data("old".utf8)),
            ContainerLogRecord(timestamp: inside, stream: .stdout, data: Data("-line\ninside".utf8)),
            ContainerLogRecord(timestamp: after, stream: .stdout, data: Data("-line\nnew\n".utf8)),
        ]

        let filtered = ContainersService.filteredLogRecords(
            records,
            options: ContainerLogOptions(since: inside, until: inside)
        )

        #expect(
            filtered == [
                ContainerLogRecord(timestamp: inside, stream: .stdout, data: Data("inside-line\n".utf8))
            ])
    }

    @Test func filtersLogsBySinceUntilAndTail() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z first
            2026-01-03T00:00:00Z second
            2026-01-04T00:00:00Z new

            """
        let options = ContainerLogOptions(
            tail: 1,
            since: date("2026-01-02T00:00:00Z"),
            until: date("2026-01-03T00:00:00Z")
        )

        let data = ContainersService.filteredLogData(Data(content.utf8), options: options)

        #expect(String(data: data, encoding: .utf8) == "2026-01-03T00:00:00Z second\n")
    }

    @Test func preservesUnparseableLinesEmptyLinesAndTrailingNewline() throws {
        let content = """
            2026-01-01T00:00:00Z old
            unparseable

            2026-01-03T00:00:00Z retained

            """
        let options = ContainerLogOptions(
            since: date("2026-01-02T00:00:00Z")
        )

        let data = ContainersService.filteredLogData(Data(content.utf8), options: options)

        #expect(String(data: data, encoding: .utf8) == "unparseable\n\n2026-01-03T00:00:00Z retained\n")
    }

    @Test func tailZeroReturnsEmptyLogData() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: 0))

        #expect(data.isEmpty)
    }

    @Test func negativeTailDoesNotDropLogs() throws {
        let content = """
            2026-01-01T00:00:00Z old
            2026-01-02T00:00:00Z new

            """

        let data = ContainersService.filteredLogData(Data(content.utf8), options: ContainerLogOptions(tail: -1))

        #expect(String(data: data, encoding: .utf8) == content)
    }

    @Test func nonUTF8LogsCanBeTailedWithoutDecoding() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let data = ContainersService.filteredLogData(bytes, options: ContainerLogOptions(tail: 1))

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func nonUTF8LogsApplyTailWhenOpeningFilteredHandle() throws {
        let bytes = Data([0xff, 0xfe, 0x0a, 0x41, 0x0a])
        let handle = try fileHandle(containing: bytes)

        let filtered = ContainersService.applyLogOptions(to: handle, options: ContainerLogOptions(tail: 1))
        let data = try #require(try filtered.readToEnd())

        #expect(data == Data([0x41, 0x0a]))
    }

    @Test func logRecordTailReturnsNewestRecords() {
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("second\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("third\n".utf8))

        let records = ContainersService.filteredLogRecords(
            [first, second, third],
            options: ContainerLogOptions(tail: 2)
        )

        #expect(records == [second, third])
    }

    @Test func logRecordTailZeroReturnsNoRecords() {
        let record = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))

        let records = ContainersService.filteredLogRecords([record], options: ContainerLogOptions(tail: 0))

        #expect(records.isEmpty)
    }

    @Test func logRecordNegativeTailDoesNotDropRecords() {
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("second\n".utf8))

        let records = ContainersService.filteredLogRecords(
            [first, second],
            options: ContainerLogOptions(tail: -1)
        )

        #expect(records == [first, second])
    }

    @Test func harnessDecodesLogOptions() {
        let message = XPCMessage(route: .containerLogs)
        let since = Date(timeIntervalSince1970: 0)
        let until = Date(timeIntervalSince1970: -1)
        message.set(key: .logTail, value: Int64(0))
        message.set(key: .logSince, value: since)
        message.set(key: .logUntil, value: until)
        message.set(key: .logIncludeRotated, value: true)

        let options = ContainersHarness.logOptions(from: message)
        let replay = ContainersHarness.logReplayOptions(from: message)

        #expect(options.tail == 0)
        #expect(options.since == since)
        #expect(options.until == until)
        #expect(replay.includeRotated)
    }

    @Test func harnessLeavesAbsentLogOptionsUnset() {
        let message = XPCMessage(route: .containerLogs)

        let options = ContainersHarness.logOptions(from: message)

        #expect(options.tail == nil)
        #expect(options.since == nil)
        #expect(options.until == nil)
        #expect(!ContainersHarness.logReplayOptions(from: message).includeRotated)
    }

    @Test func rotatedLogURLsSortOldestToNewestAndIgnoreInvalidSuffixes() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-url-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let activeURL = tempURL.appendingPathComponent("stdio.log")
        let expectedNames = ["stdio.log.10", "stdio.log.2", "stdio.log.1"]
        for name in expectedNames + ["stdio.log", "stdio.log.0", "stdio.log.old", "other.log.3"] {
            _ = FileManager.default.createFile(atPath: tempURL.appendingPathComponent(name).path, contents: nil)
        }
        try FileManager.default.createDirectory(at: tempURL.appendingPathComponent("stdio.log.4"), withIntermediateDirectories: true)

        let urls = ContainersService.rotatedLogURLs(for: activeURL)

        #expect(urls.map(\.lastPathComponent) == expectedNames)
    }

    @Test func staticLogReplayIncludesRotatedFilesInChronologicalOrder() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("newer\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("older\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 2))
        try Data("oldest\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 3))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-log-replay-test")
        let handles = try await service.logs(
            id: id,
            options: .default,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        defer {
            for handle in handles {
                try? handle.close()
            }
        }

        let stdio = try #require(try handles[0].readToEnd())
        let boot = try #require(try handles[1].readToEnd())

        #expect(String(data: stdio, encoding: .utf8) == "oldest\nolder\nnewer\nactive\n")
        #expect(String(data: boot, encoding: .utf8) == "boot\n")
    }

    @Test func version2LogsReadCanonicalJSONFileStorage() async throws {
        let tempURL = try canonicalTemporaryDirectory()
            .appendingPathComponent("container-v2-log-read-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(
            path: containerRoot.appendingPathComponent(id)
        )
        try FileManager.default.createDirectory(
            at: bundle.containerLoggingV2,
            withIntermediateDirectories: true
        )
        for directory in [tempURL, containerRoot, bundle.path, bundle.containerLoggingV2] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        var configuration = testConfiguration(id: id)
        configuration.logging = try version2JSONFileConfiguration()
        try bundle.set(configuration: configuration)
        let store = try DockerJSONFileLogStore(
            directoryURL: bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            configuration: DockerJSONFileLogConfiguration()
        )
        try store.write(
            ContainerLogRecordV2(
                stream: .stdout,
                observation: ContainerLogObservation(
                    wallClock: try ContainerLogTimestamp(
                        secondsSinceUnixEpoch: 1_767_323_045,
                        nanoseconds: 123_456_789
                    ),
                    monotonicInstant: ContinuousClock().now
                ),
                payload: Data("canonical".utf8),
                partial: nil,
                sequence: 1,
                processGeneration: 1
            )
        )
        try store.close()
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(
            appRoot: tempURL,
            logLabel: "container-v2-log-read-test"
        )
        let handles = try await service.logs(id: id, options: .default)
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        let raw = try #require(try handles[0].readToEnd())
        #expect(raw == Data("canonical\n".utf8))

        let records = try await service.logRecords(id: id)
        #expect(records.count == 1)
        #expect(records[0].stream == .stdout)
        #expect(records[0].data == Data("canonical\n".utf8))
        #expect(
            abs(
                records[0].timestamp.timeIntervalSince1970
                    - 1_767_323_045.123_456_7
            ) < 0.000_001
        )

        let followedRawHandle = try await service.followLogs(
            id: id,
            options: .default
        )
        defer { try? followedRawHandle.close() }
        let followedRaw = try #require(try followedRawHandle.readToEnd())
        #expect(followedRaw == Data("canonical\n".utf8))

        let followedRecordHandle = try await service.followLogRecords(
            id: id,
            options: .default
        )
        defer { try? followedRecordHandle.close() }
        let followedRecordData = try #require(
            try followedRecordHandle.readToEnd()
        )
        let followedRecords = try logRecords(from: followedRecordData)
        #expect(followedRecords.count == 1)
        #expect(followedRecords[0].stream == records[0].stream)
        #expect(followedRecords[0].data == records[0].data)
        #expect(
            abs(
                followedRecords[0].timestamp.timeIntervalSince1970
                    - records[0].timestamp.timeIntervalSince1970
            ) < 0.001
        )
    }

    @Test func engineLoggingBackendUsesAuthoritativeInspectionAndExactReader() async throws {
        let tempURL = try canonicalTemporaryDirectory()
            .appendingPathComponent("container-engine-log-read-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let id = "engine-log-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(
            path: containerRoot.appendingPathComponent(id)
        )
        try FileManager.default.createDirectory(
            at: bundle.containerLoggingV2,
            withIntermediateDirectories: true
        )
        for directory in [tempURL, containerRoot, bundle.path, bundle.containerLoggingV2] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        var configuration = testConfiguration(id: id)
        configuration.creationDate = Date(timeIntervalSince1970: 1_767_225_600)
        configuration.labels = ["compose.project": "fixture"]
        configuration.logging = try version2JSONFileConfiguration(
            safeOptions: ["max-file": "1"]
        )
        try bundle.set(configuration: configuration)

        let timestamp = try ContainerLogTimestamp(
            secondsSinceUnixEpoch: 1_767_323_045,
            nanoseconds: 123_456_789
        )
        let store = try DockerJSONFileLogStore(
            directoryURL: bundle.containerJSONFileLogDirectory,
            activeFileName: ContainerResource.Bundle.jsonFileLogName,
            configuration: DockerJSONFileLogConfiguration()
        )
        try store.write(
            ContainerLogRecordV2(
                stream: .stderr,
                observation: ContainerLogObservation(
                    wallClock: timestamp,
                    monotonicInstant: ContinuousClock().now
                ),
                payload: Data("exact-engine-record".utf8),
                partial: nil,
                sequence: 1,
                attributes: ["compose.service": "web"],
                processGeneration: 1
            )
        )
        try store.close()
        try bundle.setDurably(
            lifecycleState: ContainerLifecycleStateV1(
                startedDate: Date(
                    timeIntervalSince1970: 1_767_323_045
                )
            )
        )

        let containers = try service(
            appRoot: tempURL,
            logLabel: "container-engine-log-read-test"
        )
        let backend = ContainerDockerLoggingBackend(
            containers: containers,
            engineIdentity: "test-authority",
            serverVersion: "test-version",
            imageCountProvider: { 3 }
        )
        let info = try await backend.loggingSystemInfo()
        #expect(info.defaultDriver == "json-file")
        #expect(info.registeredDrivers.contains("json-file"))
        #expect(info.registeredDrivers.contains("local"))

        let inspection = try await backend.inspectContainerLogging(
            containerID: id
        )
        #expect(inspection.configuration.driver == "json-file")
        #expect(inspection.configuration.options == ["max-file": "1"])
        #expect(inspection.publicLogPath == bundle.containerJSONFileLog.path)
        #expect(!inspection.terminal)

        let reader = try await backend.openContainerLogs(
            containerID: id,
            request: DockerLogReadRequest(
                stdout: true,
                stderr: true,
                follow: false,
                tail: nil,
                since: nil,
                until: nil,
                timestamps: true,
                details: true
            )
        )
        let record = try #require(try await reader.nextRecord())
        #expect(record.source == .standardError)
        #expect(record.timestamp.secondsSinceUnixEpoch == timestamp.secondsSinceUnixEpoch)
        #expect(record.timestamp.nanoseconds == timestamp.nanoseconds)
        #expect(record.line == Data("exact-engine-record\n".utf8))
        #expect(record.attributes == ["compose.service": "web"])
        #expect(try await reader.nextRecord() == nil)
        await reader.close()

        let declaration = try ContainerEngineProviderDeclaration(
            profile: .enhanced,
            kind: .containerAuthority,
            implementationVersion: "test",
            runtimeRevisions: ["container": "test"],
            stateSchemaVersion: 1,
            capabilities: [
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerAttach",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerAttachWebsocket",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerResize",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerLogs",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerInspect",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerList",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemInfo",
                    status: .native
                ),
                try ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemVersion",
                    status: .native
                ),
            ]
        )
        let controller = try DockerLoggingAPIController(
            backend: backend,
            sharedResponseBackend: backend
        )
        let providerRoot = try canonicalTemporaryDirectory()
            .appendingPathComponent(
                "ce-provider-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: providerRoot) }
        let provider = try ContainerEngineProviderSessionServer(
            responder: controller,
            socketPath: providerRoot.appendingPathComponent("provider.sock").path,
            declaration: declaration,
            stateRootUUID: try #require(
                UUID(uuidString: "41A36BAF-17E0-4CA8-882D-F9E31D754EF4")
            )
        )
        try provider.start()
        do {
            let client = ContainerEngineProviderSessionClient(
                socketPath: provider.socketPath,
                expectedFingerprint: provider.fingerprint
            )
            let versionResponse = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/version")
            )
            #expect(versionResponse.status == 200)
            let versionObject = try engineJSONObject(versionResponse)
            #expect(versionObject["Version"] as? String == "test-version")
            #expect(versionObject["ApiVersion"] as? String == "1.53")
            #expect(versionObject["MinAPIVersion"] as? String == "1.44")

            let runningListResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .get,
                    target: "/v1.53/containers/json"
                )
            )
            #expect(runningListResponse.status == 200)
            #expect(try engineJSONArray(runningListResponse).isEmpty)

            let listResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .get,
                    target:
                        "/v1.53/containers/json?all=1&filters=%7B%22label%22%3A%5B%22compose.project%3Dfixture%22%5D%2C%22status%22%3A%5B%22exited%22%5D%7D"
                )
            )
            #expect(listResponse.status == 200)
            let listObjects = try engineJSONArray(listResponse)
            #expect(listObjects.count == 1)
            let listObject = try #require(listObjects.first)
            #expect(listObject["Id"] as? String == id)
            #expect(listObject["Names"] as? [String] == ["/\(id)"])
            #expect(listObject["Image"] as? String == configuration.image.reference)
            #expect(listObject["ImageID"] as? String == configuration.image.digest)
            #expect(listObject["Command"] as? String == "/bin/sh")
            #expect(listObject["Created"] as? Int == 1_767_225_600)
            #expect(listObject["State"] as? String == "exited")
            #expect((listObject["Status"] as? String)?.hasPrefix("Exited (0) ") == true)
            #expect(
                listObject["Labels"] as? [String: String]
                    == ["compose.project": "fixture"]
            )

            let infoResponse = await client.respond(
                to: DockerHTTPRequest(method: .get, target: "/v1.53/info")
            )
            #expect(infoResponse.status == 200)
            let infoObject = try engineJSONObject(infoResponse)
            #expect(infoObject["ID"] as? String == "test-authority")
            #expect(infoObject["Containers"] as? Int == 1)
            #expect(infoObject["ContainersRunning"] as? Int == 0)
            #expect(infoObject["ContainersPaused"] as? Int == 0)
            #expect(infoObject["ContainersStopped"] as? Int == 1)
            #expect(infoObject["Images"] as? Int == 3)
            #expect(infoObject["LoggingDriver"] as? String == "json-file")
            let plugins = try #require(infoObject["Plugins"] as? [String: Any])
            #expect((plugins["Log"] as? [String])?.contains("local") == true)

            let inspectResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .get,
                    target: "/v1.53/containers/\(id)/json"
                )
            )
            #expect(inspectResponse.status == 200)
            let inspectObject = try engineJSONObject(inspectResponse)
            #expect(inspectObject["Id"] as? String == id)
            #expect(inspectObject["Driver"] as? String == "apple-container")
            #expect(inspectObject["LogPath"] as? String == bundle.containerJSONFileLog.path)
            #expect(inspectObject["Path"] as? String == "/bin/sh")
            #expect(inspectObject["Args"] as? [String] == [])
            #expect(inspectObject["Image"] as? String == configuration.image.digest)
            #expect(inspectObject["Name"] as? String == "/\(id)")
            #expect(inspectObject["Platform"] as? String == "linux")
            let inspectState = try #require(
                inspectObject["State"] as? [String: Any]
            )
            #expect(inspectState["Status"] as? String == "exited")
            #expect(inspectState["Running"] as? Bool == false)
            #expect(inspectState["ExitCode"] as? Int == 0)
            let inspectConfig = try #require(
                inspectObject["Config"] as? [String: Any]
            )
            #expect(inspectConfig["Tty"] as? Bool == false)
            #expect(inspectConfig["Hostname"] as? String == id)
            #expect(inspectConfig["User"] as? String == "0:0")
            #expect(inspectConfig["Image"] as? String == configuration.image.reference)
            #expect(inspectConfig["Entrypoint"] as? [String] == ["/bin/sh"])
            #expect(inspectConfig["Cmd"] as? [String] == [])
            let inspectHostConfig = try #require(
                inspectObject["HostConfig"] as? [String: Any]
            )
            #expect(inspectHostConfig["NetworkMode"] as? String == "default")
            #expect(inspectHostConfig["AutoRemove"] as? Bool == false)
            let restartPolicy = try #require(
                inspectHostConfig["RestartPolicy"] as? [String: Any]
            )
            #expect(restartPolicy["Name"] as? String == "no")
            #expect(restartPolicy["MaximumRetryCount"] as? Int == 0)
            let inspectLogConfig = try #require(
                inspectHostConfig["LogConfig"] as? [String: Any]
            )
            #expect(inspectLogConfig["Type"] as? String == "json-file")
            #expect(
                inspectLogConfig["Config"] as? [String: String]
                    == ["max-file": "1"]
            )

            let response = await client.respond(
                to: DockerHTTPRequest(
                    method: .get,
                    target:
                        "/v1.53/containers/\(id)/logs?stdout=1&stderr=1&timestamps=1&details=1"
                )
            )
            #expect(response.status == 200)
            if case .managedStream(let session) = response.body {
                let chunk = try #require(try await session.nextChunk())
                #expect(chunk.range(of: Data("exact-engine-record\n".utf8)) != nil)
                #expect(chunk.range(of: Data("compose.project".utf8)) == nil)
                #expect(chunk.range(of: Data("compose.service=web".utf8)) != nil)
                #expect(try await session.nextChunk() == nil)
            } else {
                Issue.record("expected managed Engine log stream")
            }

            let attachResponse = await client.respond(
                to: try DockerHTTPRequest(
                    method: .post,
                    target:
                        "/v1.53/containers/\(id)/attach?logs=1&stream=0&stdin=0&stdout=1&stderr=1",
                    uniqueHeaders: [
                        "Connection": "Upgrade",
                        "Upgrade": "tcp",
                    ]
                )
            )
            #expect(attachResponse.status == 200)
            if case .hijack(let session, let terminal) = attachResponse.body {
                #expect(!terminal)
                var frames = [DockerStreamFrame]()
                for try await frame in session.frames {
                    frames.append(frame)
                }
                #expect(
                    frames
                        == [
                            DockerStreamFrame(
                                channel: .standardError,
                                data: Data("exact-engine-record\n".utf8)
                            )
                        ]
                )
                #expect(try await session.wait() == 0)
            } else {
                Issue.record("expected Engine attach hijack")
            }

            let webSocketResponse = await client.respond(
                to: try DockerHTTPRequest(
                    method: .get,
                    target:
                        "/v1.53/containers/\(id)/attach/ws?logs=1&stream=0&stdin=0&stdout=1&stderr=1",
                    uniqueHeaders: [
                        "Connection": "Upgrade",
                        "Upgrade": "websocket",
                        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                        "Sec-WebSocket-Version": "13",
                    ]
                )
            )
            #expect(webSocketResponse.status == 101)
            if case .webSocket(let session) = webSocketResponse.body {
                var frames = [DockerStreamFrame]()
                for try await frame in session.frames {
                    frames.append(frame)
                }
                #expect(
                    frames
                        == [
                            DockerStreamFrame(
                                channel: .standardError,
                                data: Data("exact-engine-record\n".utf8)
                            )
                        ]
                )
                #expect(try await session.wait() == 0)
            } else {
                Issue.record("expected Engine WebSocket attach")
            }

            await #expect(
                throws: DockerLoggingBackendError.containerNotFound("missing")
            ) {
                try await backend.resizeContainerTerminal(
                    containerID: "missing",
                    height: 24,
                    width: 80
                )
            }
            await #expect(
                throws: DockerLoggingBackendError.conflict(
                    "container \(id) is not running"
                )
            ) {
                try await backend.resizeContainerTerminal(
                    containerID: id,
                    height: 24,
                    width: 80
                )
            }

            let invalidResizeResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .post,
                    target:
                        "/v1.53/containers/\(id)/resize?h=4294967296&w=80"
                )
            )
            #expect(invalidResizeResponse.status == 400)

            let stoppedResizeResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .post,
                    target:
                        "/v1.53/containers/\(id)/resize?h=24&w=80"
                )
            )
            #expect(stoppedResizeResponse.status == 409)
            #expect(
                try engineJSONObject(stoppedResizeResponse)["message"]
                    as? String == "container \(id) is not running"
            )

            let missingResizeResponse = await client.respond(
                to: DockerHTTPRequest(
                    method: .post,
                    target:
                        "/v1.53/containers/missing/resize?h=24&w=80"
                )
            )
            #expect(missingResizeResponse.status == 404)

            await containers.publishEngineResizeEvent(
                snapshot: try containers.engineAttachmentInspection(
                    containerID: id
                ).snapshot,
                height: UInt32.max,
                width: UInt32(UInt16.max) + 2
            )

            let eventSubscription = await containers.events(
                options: ContainerEventOptions(until: Date())
            )
            defer { try? eventSubscription.fileHandle.close() }
            let eventData = try #require(
                try eventSubscription.fileHandle.readToEnd()
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = try String(decoding: eventData, as: UTF8.self)
                .split(separator: "\n")
                .map {
                    try decoder.decode(ContainerEvent.self, from: Data($0.utf8))
                }
            #expect(
                events.map(\.action)
                    == ["attach", "detach", "attach", "detach", "resize"]
            )
            #expect(events.allSatisfy { $0.id == id })
            #expect(events.last?.attributes["height"] == String(UInt32.max))
            #expect(
                events.last?.attributes["width"]
                    == String(UInt32(UInt16.max) + 2)
            )
            await provider.shutdown()
        } catch {
            await provider.shutdown()
            throw error
        }
    }

    @Test func dockerContainerListProjectionCoversLifecycleFieldsAndFilters() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var createdConfiguration = testConfiguration(id: "created-one")
        createdConfiguration.creationDate = Date(timeIntervalSince1970: 100)
        createdConfiguration.labels = ["role": "worker"]
        createdConfiguration.initProcess.arguments = ["-c", "echo hello"]
        createdConfiguration.exposedPorts = ["8080/tcp"]
        createdConfiguration.mounts = [.tmpfs(destination: "/cache", options: [])]
        createdConfiguration.networks = [
            AttachmentConfiguration(
                network: "fixture-net",
                options: AttachmentOptions(hostname: "created-one")
            )
        ]
        let created = ContainerSnapshot(
            configuration: createdConfiguration,
            status: .stopped,
            networks: []
        )

        var exitedConfiguration = testConfiguration(id: "exited-two")
        exitedConfiguration.creationDate = Date(timeIntervalSince1970: 200)
        exitedConfiguration.labels = ["role": "worker"]
        let exited = ContainerSnapshot(
            configuration: exitedConfiguration,
            status: .stopped,
            networks: [],
            startedDate: Date(timeIntervalSince1970: 250),
            exitCode: 7,
            exitedDate: Date(timeIntervalSince1970: 300)
        )

        var deadConfiguration = testConfiguration(id: "dead-three")
        deadConfiguration.creationDate = Date(timeIntervalSince1970: 300)
        let dead = ContainerSnapshot(
            configuration: deadConfiguration,
            status: .unknown,
            networks: []
        )

        var runningConfiguration = testConfiguration(id: "running-four")
        runningConfiguration.creationDate = Date(timeIntervalSince1970: 400)
        let running = ContainerSnapshot(
            configuration: runningConfiguration,
            status: .running,
            networks: [],
            startedDate: Date(timeIntervalSince1970: 500)
        )

        var pausedConfiguration = testConfiguration(id: "paused-five")
        pausedConfiguration.creationDate = Date(timeIntervalSince1970: 500)
        let paused = ContainerSnapshot(
            configuration: pausedConfiguration,
            status: .paused,
            networks: [],
            startedDate: Date(timeIntervalSince1970: 600),
            health: .healthy
        )
        let snapshots = [created, exited, dead, running, paused]

        func objects(
            all: Bool = true,
            limit: Int? = nil,
            size: Bool = false,
            filters: [String: [String]] = [:]
        ) throws -> [[String: Any]] {
            try ContainerDockerLoggingBackend.containerListObjects(
                snapshots: snapshots,
                request: DockerContainerListRequest(
                    all: all,
                    limit: limit,
                    size: size,
                    filters: filters
                ),
                now: now
            )
        }

        func ids(_ filters: [String: [String]]) throws -> [String] {
            try objects(filters: filters).compactMap { $0["Id"] as? String }
        }

        #expect(try objects(all: false).compactMap { $0["Id"] as? String }
            == ["paused-five", "running-four"])
        #expect(try objects(limit: 2).compactMap { $0["Id"] as? String }
            == ["paused-five", "running-four"])
        #expect(try ids(["label": ["role=worker"]])
            == ["exited-two", "created-one"])
        #expect(try ids(["status": ["exited"], "exited": ["7"]])
            == ["exited-two"])
        #expect(try ids(["id": ["dead-th"]]) == ["dead-three"])
        #expect(try ids(["name": ["^/running-"]]) == ["running-four"])
        #expect(try ids(["ancestor": [createdConfiguration.image.reference]])
            == ["paused-five", "running-four", "dead-three", "exited-two", "created-one"])
        #expect(try ids(["before": ["dead-three"]])
            == ["exited-two", "created-one"])
        #expect(try ids(["since": ["running-four"]]) == ["paused-five"])
        #expect(try ids(["network": ["fixture-net"]]) == ["created-one"])
        #expect(try ids(["volume": ["/cache"]]) == ["created-one"])
        #expect(try ids(["expose": ["8080/tcp"]]) == ["created-one"])
        #expect(try ids(["health": ["healthy"]]) == ["paused-five"])
        #expect(try ids(["is-task": ["true"]]).isEmpty)
        #expect(try ids(["isolation": ["default"]]).count == 5)
        #expect(throws: DockerLoggingBackendError.self) {
            try objects(filters: ["unsupported": ["value"]])
        }

        let createdObject = try #require(
            objects(size: true).first { $0["Id"] as? String == "created-one" }
        )
        #expect(createdObject["State"] as? String == "created")
        #expect(createdObject["Status"] as? String == "Created")
        #expect(createdObject["Command"] as? String == "/bin/sh -c 'echo hello'")
        #expect(createdObject["SizeRw"] as? Int == 0)
        #expect(createdObject["SizeRootFs"] as? Int == 0)
        let createdNetworks = try #require(
            createdObject["NetworkSettings"] as? [String: Any]
        )
        #expect(
            (createdNetworks["Networks"] as? [String: Any])?["fixture-net"] != nil
        )
        let pausedObject = try #require(
            objects().first { $0["Id"] as? String == "paused-five" }
        )
        #expect((pausedObject["Status"] as? String)?.hasSuffix("(Paused)") == true)
        let pausedHealth = try #require(
            pausedObject["Health"] as? [String: Any]
        )
        #expect(pausedHealth["Status"] as? String == "healthy")
        #expect(pausedHealth["FailingStreak"] as? Int == 0)
        let deadObject = try #require(
            objects().first { $0["Id"] as? String == "dead-three" }
        )
        #expect(deadObject["Status"] as? String == "Dead")
    }

    @Test func engineLoggingInspectionHidesJSONFilePathBeforeFirstStart() async throws {
        let tempURL = try canonicalTemporaryDirectory()
            .appendingPathComponent(
                "container-engine-created-log-inspect-test-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let id = "engine-created-log-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(
            path: containerRoot.appendingPathComponent(id)
        )
        try FileManager.default.createDirectory(
            at: bundle.path,
            withIntermediateDirectories: true
        )
        for directory in [tempURL, containerRoot, bundle.path] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        var configuration = testConfiguration(id: id)
        configuration.logging = try version2JSONFileConfiguration()
        try bundle.set(configuration: configuration)

        let containers = try service(
            appRoot: tempURL,
            logLabel: "container-engine-created-log-inspect-test"
        )
        let inspection = try await containers.engineLoggingInspection(
            containerID: id
        )

        #expect(inspection.driver == "json-file")
        #expect(inspection.publicLogPath == nil)
    }

    @Test func engineAttachDoesNotStreamUnreadableFiniteHistory() {
        let plan = ContainerDockerRuntimeAttachPlan(
            request: DockerAttachRequest(
                includeLogs: true,
                stream: false,
                stdin: false,
                stdout: true,
                stderr: true,
                detachKeys: nil
            ),
            terminal: false,
            hasLogReader: false
        )

        #expect(!plan.input)
        #expect(!plan.stdout)
        #expect(!plan.stderr)
    }

    @Test func engineAttachStreamsUnreadableLiveOutputWithDockerTTYSelection() {
        let nonTerminal = ContainerDockerRuntimeAttachPlan(
            request: DockerAttachRequest(
                includeLogs: true,
                stream: true,
                stdin: true,
                stdout: true,
                stderr: true,
                detachKeys: "ctrl-x"
            ),
            terminal: false,
            hasLogReader: false
        )
        let terminalStderr = ContainerDockerRuntimeAttachPlan(
            request: DockerAttachRequest(
                includeLogs: false,
                stream: true,
                stdin: false,
                stdout: false,
                stderr: true,
                detachKeys: nil
            ),
            terminal: true,
            hasLogReader: false
        )
        let terminalBoth = ContainerDockerRuntimeAttachPlan(
            request: DockerAttachRequest(
                includeLogs: false,
                stream: true,
                stdin: false,
                stdout: true,
                stderr: true,
                detachKeys: nil
            ),
            terminal: true,
            hasLogReader: false
        )
        let readable = ContainerDockerRuntimeAttachPlan(
            request: DockerAttachRequest(
                includeLogs: true,
                stream: true,
                stdin: false,
                stdout: true,
                stderr: true,
                detachKeys: nil
            ),
            terminal: false,
            hasLogReader: true
        )

        #expect(nonTerminal.input)
        #expect(nonTerminal.stdout)
        #expect(nonTerminal.stderr)
        #expect(!terminalStderr.stdout)
        #expect(!terminalStderr.stderr)
        #expect(terminalBoth.stdout)
        #expect(!terminalBoth.stderr)
        #expect(!readable.stdout)
        #expect(!readable.stderr)
    }

    @Test func engineResizeAcceptsDockerUInt32DomainAndUsesPTYRepresentation() {
        let maximum = ContainerDockerLoggingBackend.terminalSize(
            height: UInt32.max,
            width: UInt32.max
        )
        let wrapped = ContainerDockerLoggingBackend.terminalSize(
            height: UInt32(UInt16.max) + 1,
            width: UInt32(UInt16.max) + 2
        )

        #expect(maximum.height == UInt16.max)
        #expect(maximum.width == UInt16.max)
        #expect(wrapped.height == 0)
        #expect(wrapped.width == 1)
    }

    @Test func engineAttachRejectsPausedAndRestartingBeforeReplay() throws {
        #expect(
            throws: DockerLoggingBackendError.conflict(
                "container paused-container is paused, unpause the container before attach"
            )
        ) {
            try ContainerDockerLoggingBackend.validateAttachState(
                containerID: "paused-container",
                status: .paused,
                restarting: false
            )
        }

        #expect(
            throws: DockerLoggingBackendError.conflict(
                "container restarting-container is restarting, wait until the container is running"
            )
        ) {
            try ContainerDockerLoggingBackend.validateAttachState(
                containerID: "restarting-container",
                status: .stopped,
                restarting: true
            )
        }

        for status in [
            RuntimeStatus.unknown,
            .stopped,
            .running,
            .stopping,
        ] {
            try ContainerDockerLoggingBackend.validateAttachState(
                containerID: "allowed-container",
                status: status,
                restarting: false
            )
        }
    }

    @Test func engineActiveWireReaderPreservesExactRecordAndTerminalMode() async throws {
        let source = try ContainerLogReadRecordV1(
            stream: .stdout,
            timestamp: ContainerLogTimestamp(
                secondsSinceUnixEpoch: 1_767_323_045,
                nanoseconds: 987_654_321
            ),
            data: Data("active-wire\n".utf8),
            attributes: ["compose.project": "example"],
            sequence: 41,
            processGeneration: 7
        )
        var encoded = try JSONEncoder().encode(
            ContainerLogReadRecordWireV1(source)
        )
        encoded.append(UInt8(ascii: "\n"))
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: encoded)
        try pipe.fileHandleForWriting.close()

        let reader = WireDockerLogReadSession(
            file: pipe.fileHandleForReading,
            terminal: true
        )
        #expect(reader.terminal)
        let record = try #require(try await reader.nextRecord())
        #expect(record.source == .standardOutput)
        #expect(
            record.timestamp.secondsSinceUnixEpoch
                == source.timestamp.secondsSinceUnixEpoch
        )
        #expect(record.timestamp.nanoseconds == source.timestamp.nanoseconds)
        #expect(record.line == source.data)
        #expect(record.attributes == source.attributes)
        #expect(try await reader.nextRecord() == nil)
    }

    @Test func staticLogReplayAppliesTailAfterCombiningRotatedFiles() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-log-tail-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("newer\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("older\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 2))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-log-tail-test")
        let handles = try await service.logs(
            id: id,
            options: ContainerLogOptions(tail: 2),
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        let data = try #require(try handles[0].readToEnd())

        #expect(String(data: data, encoding: .utf8) == "newer\nactive\n")
    }

    @Test func boundedTailRebuildsLineAcrossRotatedFiles() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-bounded-log-tail-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let older = tempURL.appendingPathComponent("stdio.log.1")
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("one\npar".utf8).write(to: older)
        try Data("t\ntwo\n".utf8).write(to: active)

        let data = try ContainersService.tailLogData(from: [older, active], lineCount: 2)

        #expect(String(data: data, encoding: .utf8) == "part\ntwo\n")
    }

    @Test func defaultLogReplayKeepsActiveFileOnly() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-active-log-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)
        try Data("rotated\n".utf8).write(to: rotatedLogURL(for: bundle.containerLog, index: 1))
        try Data("boot\n".utf8).write(to: bundle.bootlog)

        let service = try service(appRoot: tempURL, logLabel: "container-active-log-replay-test")
        let handles = try await service.logs(id: id, options: .default)
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        let data = try #require(try handles[0].readToEnd())

        #expect(String(data: data, encoding: .utf8) == "active\n")
    }

    @Test func followedLogFileReplaysInitialTailAndFollowsRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("one\ntwo\n".utf8).write(to: active)

        let stream = try ContainersService.followLogFile(
            for: active,
            options: ContainerLogOptions(tail: 1),
            pollInterval: .milliseconds(10)
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: Data("two\nthree\nfour\n".utf8))

        try append("three\n", to: active)
        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try Data("four\n".utf8).write(to: active)

        let output = try await outputTask

        #expect(String(data: output, encoding: .utf8) == "two\nthree\nfour\n")
    }

    @Test func followedLogFileTailZeroStartsEmptyBeforeFollowing() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-tail-zero-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.log")
        try Data("old\n".utf8).write(to: active)

        let stream = try ContainersService.followLogFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10)
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: Data("new\n".utf8))

        try append("new\n", to: active)
        let output = try await outputTask

        #expect(String(data: output, encoding: .utf8) == "new\n")
    }

    @Test func followedLogRecordFileReplaysInitialTailAndFollowsRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let first = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("one\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stderr, data: Data("two\n".utf8))
        let third = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stdout, data: Data("three\n".utf8))
        let fourth = ContainerLogRecord(timestamp: date("2026-01-04T00:00:00Z"), stream: .stdout, data: Data("four\n".utf8))
        try logRecordData([first, second]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 1),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [second, third, fourth]
        async let outputTask = followedData(from: stream, until: recordDataMarker(fourth))

        try append([third], to: active)
        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try logRecordData([fourth]).write(to: active)

        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileTailZeroStartsEmptyBeforeFollowing() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-tail-zero-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        try logRecordData([old]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [new]
        async let outputTask = followedData(from: stream, until: recordDataMarker(new))

        try append([new], to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileTailZeroDropsOpenInitialRecord() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-tail-zero-open-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        let oldData = try logRecordData([old])
        try Data(oldData.dropLast(2)).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(tail: 0),
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        async let outputTask = followedData(from: stream, until: recordDataMarker(new))

        var appended = Data(oldData.suffix(2))
        appended.append(try logRecordData([new]))
        try append(appended, to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == [new])
    }

    @Test func followedLogRecordFileCompletesPartialLineAcrossRotation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-partial-rotation-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let started = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("pa".utf8))
        let completed = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("rt\n".utf8))
        let expectedRecord = ContainerLogRecord(timestamp: started.timestamp, stream: .stdout, data: Data("part\n".utf8))
        try logRecordData([started]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: .default,
            pollInterval: .milliseconds(10),
            isLive: { true }
        )
        defer {
            try? stream.close()
        }
        let expected = [expectedRecord]
        async let outputTask = followedData(from: stream, until: recordDataMarker(expectedRecord))

        try FileManager.default.moveItem(at: active, to: rotatedLogURL(for: active, index: 1))
        try logRecordData([completed]).write(to: active)
        let output = try await outputTask

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileFlushesPartialLineWhenContainerStops() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-stop-flush-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let partial = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stderr, data: Data("partial".utf8))
        try logRecordData([partial]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: .default,
            pollInterval: .milliseconds(10),
            isLive: { false }
        )
        defer {
            try? stream.close()
        }
        let expected = [partial]
        let output = try await followedData(from: stream, until: recordDataMarker(partial))

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedLogRecordFileAppliesInitialSinceUntilAndTail() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-record-filter-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        let active = tempURL.appendingPathComponent("stdio.jsonl")
        let old = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("old\n".utf8))
        let first = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("first\n".utf8))
        let second = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("second\n".utf8))
        let new = ContainerLogRecord(timestamp: date("2026-01-04T00:00:00Z"), stream: .stdout, data: Data("new\n".utf8))
        try logRecordData([old, first, second, new]).write(to: active)

        let stream = try ContainersService.followLogRecordFile(
            for: active,
            options: ContainerLogOptions(
                tail: 1,
                since: first.timestamp,
                until: second.timestamp
            ),
            pollInterval: .milliseconds(10),
            isLive: { false }
        )
        defer {
            try? stream.close()
        }
        let expected = [second]
        let output = try await followedData(from: stream, until: recordDataMarker(second))

        #expect(try logRecords(from: output) == expected)
    }

    @Test func followedRawLogsRejectTimeFilters() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-follow-log-filter-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        try Data("active\n".utf8).write(to: bundle.containerLog)

        let service = try service(appRoot: tempURL, logLabel: "container-follow-log-filter-test")

        await #expect(throws: (any Error).self) {
            _ = try await service.followLogs(
                id: id,
                options: ContainerLogOptions(since: date("2026-01-01T00:00:00Z"))
            )
        }
    }

    @Test func staticRecordReplayIncludesRotatedFilesInChronologicalOrder() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-rotated-record-replay-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let bundle = try createBundle(appRoot: tempURL, id: id)
        let oldest = ContainerLogRecord(timestamp: date("2026-01-01T00:00:00Z"), stream: .stdout, data: Data("oldest\n".utf8))
        let newer = ContainerLogRecord(timestamp: date("2026-01-02T00:00:00Z"), stream: .stdout, data: Data("newer\n".utf8))
        let active = ContainerLogRecord(timestamp: date("2026-01-03T00:00:00Z"), stream: .stderr, data: Data("active\n".utf8))
        try logRecordData([active]).write(to: bundle.containerLogRecords)
        try logRecordData([newer]).write(to: rotatedLogURL(for: bundle.containerLogRecords, index: 1))
        try logRecordData([oldest]).write(to: rotatedLogURL(for: bundle.containerLogRecords, index: 2))

        let service = try service(appRoot: tempURL, logLabel: "container-rotated-record-replay-test")
        let records = try await service.logRecords(
            id: id,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )

        #expect(records == [oldest, newer, active])
    }

    @Test func opensTimestampedLogRecordFile() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-record-file-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(path: containerRoot.appendingPathComponent(id))
        try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
        try bundle.set(configuration: testConfiguration(id: id))
        let records = [
            ContainerLogRecord(
                timestamp: date("2026-01-02T00:00:00Z"),
                stream: .stdout,
                data: Data("first\n".utf8)
            )
        ]
        let expectedData = try logRecordData(records)
        try expectedData.write(to: bundle.containerLogRecords)

        let service = try ContainersService(
            appRoot: tempURL,
            pluginLoader: try pluginLoader(appRoot: tempURL),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: "container-log-record-file-test")
        )

        let file = try await service.logRecordFile(id: id)
        defer {
            try? file.close()
        }
        let data = file.readDataToEndOfFile()

        #expect(data == expectedData)
    }

    @Test func streamsRotatedTimestampedLogRecordFilesOldestFirst() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-record-stream-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let id = "test-container"
        let containerRoot = tempURL.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(path: containerRoot.appendingPathComponent(id))
        try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
        try bundle.set(configuration: testConfiguration(id: id))
        let oldest = try logRecordData([
            ContainerLogRecord(
                timestamp: date("2026-01-01T00:00:00Z"),
                stream: .stdout,
                data: Data("oldest\n".utf8)
            )
        ])
        let newer = try logRecordData([
            ContainerLogRecord(
                timestamp: date("2026-01-02T00:00:00Z"),
                stream: .stderr,
                data: Data("newer\n".utf8)
            )
        ])
        let active = try logRecordData([
            ContainerLogRecord(
                timestamp: date("2026-01-03T00:00:00Z"),
                stream: .stdout,
                data: Data("active\n".utf8)
            )
        ])
        try oldest.write(
            to: bundle.containerLogRecords.appendingPathExtension("2")
        )
        try newer.write(
            to: bundle.containerLogRecords.appendingPathExtension("1")
        )
        try active.write(to: bundle.containerLogRecords)

        let service = try service(
            appRoot: tempURL,
            logLabel: "container-log-record-stream-test"
        )
        let file = try await service.logRecordFile(
            id: id,
            replay: ContainerLogReplayOptions(includeRotated: true)
        )
        defer {
            try? file.close()
        }

        #expect(file.readDataToEndOfFile() == oldest + newer + active)
    }

    private func logRecordData(_ records: [ContainerLogRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private func logRecords(from data: Data) throws -> [ContainerLogRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: UInt8(ascii: "\n")).map { line in
            try decoder.decode(ContainerLogRecord.self, from: Data(line))
        }
    }

    private func recordDataMarker(_ record: ContainerLogRecord) -> Data {
        Data("\"data\":\"\(record.data.base64EncodedString())\"".utf8)
    }

    private func fileHandle(containing data: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-test-\(UUID().uuidString)")
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private func append(_ value: String, to url: URL) throws {
        try append(Data(value.utf8), to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func append(_ records: [ContainerLogRecord], to url: URL) throws {
        try append(logRecordData(records), to: url)
    }

    private func followedData(
        from handle: FileHandle,
        until expected: Data,
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            FollowReadState(handle: handle, expected: expected, continuation: continuation)
                .start(timeout: timeout)
        }
    }

    private func createBundle(appRoot: URL, id: String) throws -> ContainerResource.Bundle {
        let containerRoot = appRoot.appendingPathComponent("containers")
        let bundle = ContainerResource.Bundle(path: containerRoot.appendingPathComponent(id))
        try FileManager.default.createDirectory(at: bundle.path, withIntermediateDirectories: true)
        try bundle.set(configuration: testConfiguration(id: id))
        return bundle
    }

    private func engineJSONObject(
        _ response: DockerHTTPResponse
    ) throws -> [String: Any] {
        guard case .bytes(let data) = response.body else {
            throw EngineResponseFixtureError("expected Engine JSON byte response")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func engineJSONArray(
        _ response: DockerHTTPResponse
    ) throws -> [[String: Any]] {
        guard case .bytes(let data) = response.body else {
            throw EngineResponseFixtureError("expected Engine JSON byte response")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [[String: Any]])
    }

    private func service(appRoot: URL, logLabel: String) throws -> ContainersService {
        try ContainersService(
            appRoot: appRoot,
            pluginLoader: try pluginLoader(appRoot: appRoot),
            containerSystemConfig: ContainerSystemConfig(),
            log: Logger(label: logLabel)
        )
    }

    private func rotatedLogURL(for url: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(url.path).\(index)")
    }

    private func testConfiguration(id: String) -> ContainerConfiguration {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    private func version2JSONFileConfiguration(
        safeOptions: [String: String] = [:]
    ) throws -> ContainerLogConfiguration {
        let descriptor = try #require(
            BuiltinLogDriverDescriptors.current.descriptor(named: "json-file")
        )
        return try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: "json-file",
                options: safeOptions
            ),
            resolved: ResolvedContainerLogConfiguration(
                leaseGeneration: 1,
                driver: "json-file",
                safeOptions: safeOptions,
                delivery: LogDeliveryConfiguration(),
                readPolicy: LogReadPolicy(source: .direct),
                providerIdentity: descriptor.providerIdentity,
                providerGenerationAtResolution: descriptor.providerGeneration,
                contractDigest: descriptor.optionContractDigest
            )
        )
    }

    private func canonicalTemporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        let pointer = path.withCString { Darwin.realpath($0, nil) }
        let canonical = try #require(pointer)
        defer { free(canonical) }
        return URL(
            fileURLWithPath: String(cString: canonical),
            isDirectory: true
        )
    }

    private func pluginLoader(appRoot: URL) throws -> PluginLoader {
        let pluginRoot = appRoot.appendingPathComponent("plugins")
        let runtimeURL = pluginRoot.appendingPathComponent("container-runtime-linux")
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        return try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [pluginRoot],
            pluginFactories: [StaticRuntimePluginFactory()]
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            preconditionFailure("invalid test date: \(value)")
        }
        return date
    }
}

private struct EngineResponseFixtureError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct FollowReadTimeout: Error, CustomStringConvertible {
    var output: String

    var description: String {
        "timed out waiting for followed log output; observed: \(output)"
    }
}

private final class FollowReadState: @unchecked Sendable {
    private let handle: FileHandle
    private let expected: Data
    private let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var output = Data()
    private var finished = false

    init(
        handle: FileHandle,
        expected: Data,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.handle = handle
        self.expected = expected
        self.continuation = continuation
    }

    func start(timeout: Duration) {
        handle.readabilityHandler = { [self] readableHandle in
            read(from: readableHandle)
        }
        Task { [self] in
            try? await Task.sleep(for: timeout)
            finish(.failure(timeoutError()))
        }
    }

    private func timeoutError() -> FollowReadTimeout {
        lock.lock()
        let data = output
        lock.unlock()
        return FollowReadTimeout(output: String(data: data, encoding: .utf8) ?? "<non-utf8>")
    }

    private func read(from handle: FileHandle) {
        let data = handle.availableData
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if data.isEmpty {
            let result = output
            lock.unlock()
            finish(.success(result))
            return
        }
        output.append(data)
        let matched = output.range(of: expected) != nil
        let result = output
        lock.unlock()
        if matched {
            finish(.success(result))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        handle.readabilityHandler = nil
        lock.unlock()

        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private struct StaticRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux" else {
            return nil
        }
        return Plugin(binaryURL: installURL.appending(path: "bin/container-runtime-linux"), config: runtimeConfig)
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }

    private var runtimeConfig: PluginConfig {
        let servicesConfig = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [PluginConfig.Service(type: .runtime, description: nil)],
            defaultArguments: []
        )
        return PluginConfig(abstract: "runtime", author: nil, servicesConfig: servicesConfig)
    }
}
