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

@testable import ContainerLoggingProviders
@testable import ContainerResource

struct DockerPluginProtocolTests {
    @Test func capabilitiesUsesExactEmptyBodyAndNestedDockerResponse() async throws {
        let transport = DockerPluginTestTransport(
            responses: [.capabilities: [.success(Data(#"{"Cap":{"ReadLogs":true},"Err":""}"#.utf8))]]
        )
        let client = DockerPluginProtocolClient(transport: transport)

        let capabilities = try await client.capabilities()

        #expect(capabilities == DockerPluginCapabilities(readLogs: true))
        let call = try #require(await transport.calls.first)
        #expect(call.endpoint == .capabilities)
        #expect(call.request.isEmpty)
        #expect(call.maximumResponseBytes == DockerPluginProtocolClient.maximumResponseBytes)
    }

    @Test func startAndStopEncodeExactDockerShapeWithFullInfo() async throws {
        let transport = DockerPluginTestTransport(
            responses: [
                .startLogging: [.success(Data(#"{"Err":""}"#.utf8))],
                .stopLogging: [.success(Data("{}".utf8))],
            ]
        )
        let client = DockerPluginProtocolClient(transport: transport)
        let fifo = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/fifo-ABC_123"
        )
        let info = try dockerPluginTestInfo()

        try await client.startLogging(fifo: fifo, info: info)
        try await client.stopLogging(fifo: fifo)

        let calls = await transport.calls
        #expect(calls.map(\.endpoint) == [.startLogging, .stopLogging])
        let start = try jsonObject(calls[0].request)
        #expect(start["File"] as? String == "/run/docker/logging/fifo-ABC_123")
        let wireInfo = try #require(start["Info"] as? [String: Any])
        #expect(wireInfo["Config"] as? [String: String] == ["token": "secret", "weird": "null=\u{0}"])
        #expect(wireInfo["ContainerID"] as? String == "container-secret-id")
        #expect(wireInfo["ContainerName"] as? String == "/project-service-1")
        #expect(wireInfo["ContainerEntrypoint"] as? String == "/bin/tool")
        #expect(wireInfo["ContainerArgs"] as? [String] == ["--password", "argument-secret"])
        #expect(wireInfo["ContainerImageID"] as? String == "sha256:image")
        #expect(wireInfo["ContainerImageName"] as? String == "example/image:latest")
        #expect(wireInfo["ContainerCreated"] as? String == "2026-08-01T12:34:56.125Z")
        #expect(wireInfo["ContainerEnv"] as? [String] == ["PASSWORD=environment-secret"])
        #expect(wireInfo["ContainerLabels"] as? [String: String] == ["secret.label": "label-secret"])
        #expect(wireInfo["LogPath"] as? String == "")
        #expect(wireInfo["DaemonName"] as? String == "docker")

        let stop = try jsonObject(calls[1].request)
        #expect(stop.count == 1)
        #expect(stop["File"] as? String == "/run/docker/logging/fifo-ABC_123")
    }

    @Test func readLogsEncodesGoTimeZeroAndEveryReadConfigField() async throws {
        let responseStream = DockerPluginTestResponseStream(chunks: [])
        let transport = DockerPluginTestTransport(stream: responseStream)
        let client = DockerPluginProtocolClient(transport: transport)
        let request = try ContainerLogReadRequest(
            stdout: false,
            stderr: true,
            follow: true,
            tail: 42,
            since: Date(timeIntervalSince1970: 1_785_587_696.25),
            until: nil
        )

        _ = try await client.readLogs(
            info: dockerPluginTestInfo(),
            configuration: DockerPluginReadConfiguration(request)
        )

        let call = try #require(await transport.streamCalls.first)
        #expect(call.endpoint == .readLogs)
        let deadline = try #require(call.deadline)
        #expect(deadline > ContinuousClock().now)
        let object = try jsonObject(call.request)
        let config = try #require(object["Config"] as? [String: Any])
        #expect(config["Since"] as? String == "2026-08-01T12:34:56.25Z")
        #expect(config["Until"] as? String == "0001-01-01T00:00:00Z")
        #expect(config["Tail"] as? Int == 42)
        #expect(config["Follow"] as? Bool == true)
        #expect(object["Info"] != nil)
    }

    @Test func containerCreatedUsesGoProlepticGregorianCalendar() async throws {
        let transport = DockerPluginTestTransport(
            responses: [.startLogging: [.success(Data("{}".utf8))]]
        )
        let client = DockerPluginProtocolClient(transport: transport)
        let fifo = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/proleptic"
        )
        let info = try DockerPluginInfo(
            config: [:],
            containerID: "id",
            containerName: "name",
            containerEntrypoint: "",
            containerArgs: [],
            containerImageID: "",
            containerImageName: "",
            containerCreated: Date(timeIntervalSince1970: -62_135_596_800),
            containerEnv: [],
            containerLabels: [:],
            logPath: "",
            daemonName: "docker"
        )

        try await client.startLogging(fifo: fifo, info: info)

        let call = try #require(await transport.calls.first)
        let object = try jsonObject(call.request)
        let wireInfo = try #require(object["Info"] as? [String: Any])
        #expect(wireInfo["ContainerCreated"] as? String == "0001-01-01T00:00:00Z")
    }

    @Test func readLogsRejectsExpiredOpenDeadlineBeforeTransportEffect() async throws {
        let responseStream = DockerPluginTestResponseStream(chunks: [])
        let transport = DockerPluginTestTransport(stream: responseStream)
        let client = DockerPluginProtocolClient(transport: transport)

        await #expect(throws: DockerPluginProtocolError.deadlineExceeded) {
            try await client.readLogs(
                info: dockerPluginTestInfo(),
                configuration: DockerPluginReadConfiguration(ContainerLogReadRequest()),
                deadline: ContinuousClock().now
            )
        }

        #expect(await transport.streamCalls.isEmpty)
    }

    @Test func protocolFailuresNeverRetainPluginSecrets() async throws {
        let secret = "response-body-credential"
        let rejectedTransport = DockerPluginTestTransport(
            responses: [.startLogging: [.success(Data("{\"Err\":\"\(secret)\"}".utf8))]]
        )
        let fifo = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/safe"
        )

        do {
            try await DockerPluginProtocolClient(transport: rejectedTransport).startLogging(
                fifo: fifo,
                info: dockerPluginTestInfo()
            )
            Issue.record("expected plugin rejection")
        } catch {
            #expect(error as? DockerPluginProtocolError == .endpointRejected(endpoint: .startLogging))
            #expect(!String(describing: error).contains(secret))
        }

        let failedTransport = DockerPluginTestTransport(
            responses: [.stopLogging: [.failure(.containsSensitiveBody)]]
        )
        do {
            try await DockerPluginProtocolClient(transport: failedTransport).stopLogging(fifo: fifo)
            Issue.record("expected transport failure")
        } catch {
            #expect(error as? DockerPluginProtocolError == .transportFailure(endpoint: .stopLogging))
            #expect(!String(describing: error).contains(DockerPluginTestFailure.containsSensitiveBody.description))
        }

        let infoText = String(describing: try dockerPluginTestInfo())
        #expect(!infoText.contains("secret"))
        #expect(!infoText.contains("password"))
    }

    @Test func responseAndRequestBoundsAreEnforcedDefensively() async throws {
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: DockerPluginProtocolClient.maximumResponseBytes + 1
        )
        let transport = DockerPluginTestTransport(
            responses: [.capabilities: [.success(oversized)]]
        )
        await #expect(
            throws: DockerPluginProtocolError.responseTooLarge(
                endpoint: .capabilities,
                maximumBytes: DockerPluginProtocolClient.maximumResponseBytes
            )
        ) {
            try await DockerPluginProtocolClient(transport: transport).capabilities()
        }

        let large = String(repeating: "x", count: DockerPluginInfo.maximumEncodedBytes)
        #expect(throws: DockerPluginProtocolError.self) {
            try DockerPluginInfo(
                config: ["large": large],
                containerID: "id",
                containerName: "name",
                containerEntrypoint: "",
                containerArgs: [],
                containerImageID: "",
                containerImageName: "",
                containerCreated: .now,
                containerEnv: [],
                containerLabels: [:],
                logPath: "",
                daemonName: "docker"
            )
        }
    }

    @Test func fifoReferencesRejectHostPathsTraversalAndNestedPaths() throws {
        for path in [
            "/tmp/fifo",
            "/run/docker/logging/../escape",
            "/run/docker/logging/nested/fifo",
            "/run/docker/logging/",
            "/run/docker/logging/name with space",
        ] {
            #expect(throws: DockerPluginProtocolError.invalidFIFOReference) {
                try DockerPluginFIFOReference(validatingPluginPath: path)
            }
        }

        let valid = try DockerPluginFIFOReference(
            validatingPluginPath: "/run/docker/logging/0123456789abcdef"
        )
        #expect(!String(describing: valid).contains("0123456789abcdef"))
    }
}

func dockerPluginTestInfo() throws -> DockerPluginInfo {
    try DockerPluginInfo(
        config: ["token": "secret", "weird": "null=\u{0}"],
        containerID: "container-secret-id",
        containerName: "/project-service-1",
        containerEntrypoint: "/bin/tool",
        containerArgs: ["--password", "argument-secret"],
        containerImageID: "sha256:image",
        containerImageName: "example/image:latest",
        containerCreated: Date(timeIntervalSince1970: 1_785_587_696.125),
        containerEnv: ["PASSWORD=environment-secret"],
        containerLabels: ["secret.label": "label-secret"],
        logPath: "",
        daemonName: "docker"
    )
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

enum DockerPluginTestFailure: Error, Sendable, CustomStringConvertible {
    case containsSensitiveBody

    var description: String { "transport-secret-body" }
}

struct DockerPluginTestCall: Equatable, Sendable {
    let endpoint: DockerPluginEndpoint
    let request: Data
    let maximumResponseBytes: Int
    let deadline: ContinuousClock.Instant?
}

actor DockerPluginTestTransport: DockerPluginRPCTransport {
    private var responses: [DockerPluginEndpoint: [Result<Data, DockerPluginTestFailure>]]
    private let stream: (any DockerPluginResponseStream)?
    private(set) var calls = [DockerPluginTestCall]()
    private(set) var streamCalls = [DockerPluginTestCall]()

    init(
        responses: [DockerPluginEndpoint: [Result<Data, DockerPluginTestFailure>]] = [:],
        stream: (any DockerPluginResponseStream)? = nil
    ) {
        self.responses = responses
        self.stream = stream
    }

    func call(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumResponseBytes: Int,
        deadline: ContinuousClock.Instant?
    ) async throws -> Data {
        calls.append(
            DockerPluginTestCall(
                endpoint: endpoint,
                request: request,
                maximumResponseBytes: maximumResponseBytes,
                deadline: deadline
            )
        )
        guard var queue = responses[endpoint], !queue.isEmpty else {
            return Data("{}".utf8)
        }
        let result = queue.removeFirst()
        responses[endpoint] = queue
        return try result.get()
    }

    func openStream(
        endpoint: DockerPluginEndpoint,
        request: Data,
        maximumChunkBytes: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> any DockerPluginResponseStream {
        streamCalls.append(
            DockerPluginTestCall(
                endpoint: endpoint,
                request: request,
                maximumResponseBytes: maximumChunkBytes,
                deadline: deadline
            )
        )
        return try #require(stream)
    }
}

actor DockerPluginTestResponseStream: DockerPluginResponseStream {
    private var chunks: [Data]
    private(set) var closeCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func nextChunk(maximumBytes: Int) async throws -> Data? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func close() async {
        closeCount += 1
    }
}
