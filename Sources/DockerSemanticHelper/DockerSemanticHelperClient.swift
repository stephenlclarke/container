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

import CSemanticHelperProcess
import CryptoKit
import Darwin
import Foundation
import Security

public struct DockerSemanticHelperLaunchConfiguration: Hashable, Sendable {
    public static let executableName = "container-semantic-helper"
    public static let manifestName = "container-semantic-helper.manifest.json"

    public let executableURL: URL
    public let manifestURL: URL
    public let verifyCodeSignature: Bool

    public init(
        executableURL: URL,
        manifestURL: URL,
        verifyCodeSignature: Bool = true
    ) {
        self.executableURL = executableURL
        self.manifestURL = manifestURL
        self.verifyCodeSignature = verifyCodeSignature
    }

    public static func discover() throws -> Self {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment[
            "CONTAINER_SEMANTIC_HELPER_PATH"
        ], !path.isEmpty {
            let executable = URL(fileURLWithPath: path).standardizedFileURL
            let manifest = executable.deletingLastPathComponent()
                .appendingPathComponent(manifestName)
            guard
                fileManager.isExecutableFile(atPath: executable.path),
                fileManager.fileExists(atPath: manifest.path)
            else {
                throw DockerSemanticHelperError.helperNotFound
            }
            return Self(executableURL: executable, manifestURL: manifest)
        }

        let launchedExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let installRoot = launchedExecutable.deletingLastPathComponent()
            .deletingLastPathComponent()
        let installedDirectory =
            installRoot
            .appendingPathComponent("libexec/container/helpers")
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentDirectory =
            sourceRoot
            .appendingPathComponent(".build/container-semantic-helper")

        for directory in [installedDirectory, developmentDirectory] {
            let executable = directory.appendingPathComponent(executableName)
            let manifest = directory.appendingPathComponent(manifestName)
            if fileManager.isExecutableFile(atPath: executable.path),
                fileManager.fileExists(atPath: manifest.path)
            {
                return Self(executableURL: executable, manifestURL: manifest)
            }
        }
        throw DockerSemanticHelperError.helperNotFound
    }
}

public final class DockerSemanticHelperClient: DockerSemanticServicing,
    @unchecked Sendable
{
    private struct ProcessState {
        var pid: pid_t
        var descriptor: Int32
        var nextRequestID: UInt64
        var fenced: Bool
    }

    private static let maximumTimeout: Duration = .seconds(30)
    private static let handshakeTimeout: Duration = .seconds(5)

    public let generation: DockerSemanticHelperGeneration
    public let manifest: DockerSemanticHelperManifest

    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var process: ProcessState

    public init(
        generation: DockerSemanticHelperGeneration,
        launchConfiguration: DockerSemanticHelperLaunchConfiguration
    ) throws {
        self.generation = generation
        self.manifest = try Self.loadAndVerifyManifest(
            launchConfiguration
        )

        var pid: pid_t = 0
        var descriptor: Int32 = -1
        let spawnResult = launchConfiguration.executableURL.path.withCString {
            csh_spawn($0, &pid, &descriptor)
        }
        guard spawnResult == 0 else {
            throw DockerSemanticHelperError.spawnFailed(Int32(spawnResult))
        }
        self.process = ProcessState(
            pid: pid,
            descriptor: descriptor,
            nextRequestID: 1,
            fenced: false
        )

        do {
            try verifyHandshake()
        } catch {
            fenceGeneration()
            throw error
        }
    }

    deinit {
        fenceGeneration()
    }

    public static func shared(
        for generation: DockerSemanticHelperGeneration,
        launchConfiguration: DockerSemanticHelperLaunchConfiguration? = nil
    ) throws -> DockerSemanticHelperClient {
        try DockerSemanticHelperClientPool.shared.client(
            generation: generation,
            launchConfiguration: launchConfiguration ?? .discover()
        )
    }

    /// Permanently retires this provider generation and every older helper
    /// generation for the same provider. Provider unload and replacement must
    /// call this only after their generation-fenced sessions have quiesced.
    public static func retireSharedGeneration(
        _ generation: DockerSemanticHelperGeneration
    ) {
        DockerSemanticHelperClientPool.shared.retire(
            through: generation
        )
    }

    public func matchRegularExpression(
        pattern: Data,
        candidates: [Data],
        timeout: Duration = .seconds(2)
    ) throws -> [Bool] {
        guard
            pattern.count
                <= DockerSemanticProtocolV1.maximumRegularExpressionBytes,
            candidates.count <= DockerSemanticProtocolV1.maximumCandidateCount
        else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(
            pattern,
            maximumBytes: DockerSemanticProtocolV1.maximumRegularExpressionBytes
        )
        try request.appendByteList(
            candidates,
            maximumCount: DockerSemanticProtocolV1.maximumCandidateCount,
            maximumValueBytes: DockerSemanticProtocolV1.maximumCandidateBytes
        )
        let response = try perform(
            opcode: .regularExpressionBatch,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let count = try reader.read(UInt32.self)
        guard
            count == UInt32(candidates.count),
            count <= UInt32(DockerSemanticProtocolV1.maximumCandidateCount)
        else {
            throw fencedProtocolViolation()
        }
        var matches = [Bool]()
        matches.reserveCapacity(Int(count))
        for _ in 0..<count {
            let value = try reader.read(UInt8.self)
            guard value <= 1 else {
                throw fencedProtocolViolation()
            }
            matches.append(value == 1)
        }
        guard reader.isAtEnd else {
            throw fencedProtocolViolation()
        }
        return matches
    }

    public func renderLogTemplate(
        template: Data,
        info: DockerLogTemplateInfo,
        configuration: [DockerSemanticBytePair],
        timeout: Duration = .seconds(2)
    ) throws -> Data {
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(
            template,
            maximumBytes: DockerSemanticProtocolV1.maximumTemplateBytes
        )
        try request.appendByteMap(configuration)
        try request.appendByteField(info.containerID)
        try request.appendByteField(info.containerName)
        try request.appendByteField(info.containerEntrypoint)
        try request.appendByteList(info.containerArguments)
        try request.appendByteField(info.containerImageID)
        try request.appendByteField(info.containerImageName)
        request.append(info.containerCreatedSeconds)
        request.append(info.containerCreatedNanoseconds)
        try request.appendByteList(info.containerEnvironment)
        try request.appendByteMap(info.containerLabels)
        try request.appendByteField(info.logPath)
        try request.appendByteField(info.daemonName)
        try request.appendByteField(info.hostname)

        let response = try perform(
            opcode: .templateRender,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let output = try reader.readByteField(
            maximumBytes: DockerSemanticProtocolV1.maximumOutputBytes
        )
        guard reader.isAtEnd else {
            throw fencedProtocolViolation()
        }
        return output
    }

    public func parseURL(
        _ source: Data,
        timeout: Duration = .seconds(2)
    ) throws -> DockerParsedURL {
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(source)
        let response = try perform(
            opcode: .urlParse,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let fields = try reader.readByteFields(count: 12)
        let passwordIsSet = try reader.read(UInt8.self)
        let forceQuery = try reader.read(UInt8.self)
        guard
            passwordIsSet <= 1,
            forceQuery <= 1,
            reader.isAtEnd
        else {
            throw fencedProtocolViolation()
        }
        return DockerParsedURL(
            scheme: fields[0],
            opaque: fields[1],
            username: fields[2],
            password: fields[3],
            passwordIsSet: passwordIsSet == 1,
            host: fields[4],
            path: fields[5],
            rawPath: fields[6],
            forceQuery: forceQuery == 1,
            rawQuery: fields[7],
            fragment: fields[8],
            rawFragment: fields[9],
            hostname: fields[10],
            port: fields[11]
        )
    }

    public func parseFluentdAddress(
        _ source: Data,
        timeout: Duration = .seconds(2)
    ) throws -> DockerFluentdAddress {
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(source)
        let response = try perform(
            opcode: .fluentdAddress,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let networkProtocol = try reader.readByteField()
        let host = try reader.readByteField()
        let port = try reader.read(UInt16.self)
        let path = try reader.readByteField()
        guard reader.isAtEnd else {
            throw fencedProtocolViolation()
        }
        return DockerFluentdAddress(
            networkProtocol: networkProtocol,
            host: host,
            port: port,
            path: path
        )
    }

    public func parseGELFAddress(
        _ source: Data,
        timeout: Duration = .seconds(2)
    ) throws -> DockerGELFAddress {
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(source)
        let response = try perform(
            opcode: .gelfAddress,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let scheme = try reader.readByteField()
        let address = try reader.readByteField()
        let host = try reader.readByteField()
        let port = try reader.read(UInt16.self)
        guard reader.isAtEnd else {
            throw fencedProtocolViolation()
        }
        return DockerGELFAddress(
            scheme: scheme,
            address: address,
            host: host,
            port: port
        )
    }

    public func parseSyslogAddress(
        _ source: Data,
        timeout: Duration = .seconds(2)
    ) throws -> DockerSyslogAddress {
        var request = DockerSemanticBinaryWriter()
        try request.appendByteField(source)
        let response = try perform(
            opcode: .syslogAddress,
            payload: request.data,
            timeout: timeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let networkProtocol = try reader.readByteField()
        let address = try reader.readByteField()
        let host = try reader.readByteField()
        let port = try reader.read(UInt16.self)
        guard reader.isAtEnd else {
            throw fencedProtocolViolation()
        }
        return DockerSyslogAddress(
            networkProtocol: networkProtocol,
            address: address,
            host: host,
            port: port
        )
    }

    /// Cancels the in-flight request, terminates the helper, and permanently
    /// fences this provider generation. A new process requires a new provider
    /// generation, preventing silent semantic changes after partial work.
    public func cancelAndFenceGeneration() {
        fenceGeneration()
    }

    private func verifyHandshake() throws {
        let response = try perform(
            opcode: .hello,
            payload: Data(),
            timeout: Self.handshakeTimeout
        )
        var reader = DockerSemanticBinaryReader(response)
        let values = try reader.readByteFields(count: 5, maximumBytes: 256)
        guard
            reader.isAtEnd,
            values[0] == Data(manifest.helperVersion.utf8),
            values[1] == Data(manifest.goVersion.utf8),
            values[2] == Data(manifest.mobyCommit.utf8),
            values[3] == Data(manifest.helperSourceSHA256.utf8),
            values[4] == Data(manifest.oracleFixtureSHA256.utf8)
        else {
            throw DockerSemanticHelperError.invalidManifest
        }
    }

    private func perform(
        opcode: DockerSemanticProtocolV1.Opcode,
        payload: Data,
        timeout: Duration
    ) throws -> Data {
        let timeoutNanoseconds = try Self.timeoutNanoseconds(timeout)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        requestLock.lock()
        defer { requestLock.unlock() }
        guard ContinuousClock.now < deadline else {
            throw DockerSemanticHelperError.deadlineExceeded
        }

        let (requestID, descriptor) = try reserveRequest()
        let header = DockerSemanticProtocolV1.Header(
            kind: .request,
            opcode: opcode,
            requestID: requestID,
            timeoutNanoseconds: timeoutNanoseconds,
            status: 0,
            flags: 0
        )
        var frame = try header.encode(payloadByteCount: payload.count)
        frame.append(payload)

        do {
            try writeAll(frame, descriptor: descriptor, deadline: deadline)
            let lengthBytes = try readExactly(
                4,
                descriptor: descriptor,
                deadline: deadline
            )
            var lengthReader = DockerSemanticBinaryReader(lengthBytes)
            let frameByteCount = try lengthReader.read(UInt32.self)
            guard
                frameByteCount >= UInt32(DockerSemanticProtocolV1.headerBytes),
                frameByteCount
                    <= UInt32(DockerSemanticProtocolV1.maximumFrameBytes)
            else {
                throw DockerSemanticHelperError.protocolViolation
            }
            let responseHeaderBytes = try readExactly(
                DockerSemanticProtocolV1.headerBytes,
                descriptor: descriptor,
                deadline: deadline
            )
            let responseHeader = try DockerSemanticProtocolV1.Header.decode(
                responseHeaderBytes
            )
            let payloadByteCount =
                Int(frameByteCount)
                - DockerSemanticProtocolV1.headerBytes
            let responsePayload = try readExactly(
                payloadByteCount,
                descriptor: descriptor,
                deadline: deadline
            )
            guard
                responseHeader.kind == .response,
                responseHeader.opcode == opcode,
                responseHeader.requestID == requestID,
                responseHeader.timeoutNanoseconds == 0,
                responseHeader.flags == 0
            else {
                throw DockerSemanticHelperError.protocolViolation
            }
            if responseHeader.status != 0 {
                guard
                    let category = DockerSemanticHelperRemoteErrorCategory(
                        rawValue: responseHeader.status
                    )
                else {
                    throw DockerSemanticHelperError.protocolViolation
                }
                var reader = DockerSemanticBinaryReader(responsePayload)
                let message = try reader.readByteField(maximumBytes: 64 * 1024)
                guard reader.isAtEnd else {
                    throw DockerSemanticHelperError.protocolViolation
                }
                throw DockerSemanticHelperRemoteError(
                    category: category,
                    messageBytes: message
                )
            }
            return responsePayload
        } catch let remote as DockerSemanticHelperRemoteError {
            throw remote
        } catch DockerSemanticHelperError.deadlineExceeded {
            fenceGeneration()
            throw DockerSemanticHelperError.deadlineExceeded
        } catch {
            fenceGeneration()
            if let helperError = error as? DockerSemanticHelperError {
                throw helperError
            }
            throw DockerSemanticHelperError.protocolViolation
        }
    }

    private func reserveRequest() throws -> (UInt64, Int32) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !process.fenced else {
            throw DockerSemanticHelperError.generationFenced
        }
        var status: Int32 = 0
        let waitResult = csh_wait_nohang(process.pid, &status)
        guard waitResult == 0 else {
            process.fenced = true
            if process.descriptor >= 0 {
                _ = csh_close(process.descriptor)
                process.descriptor = -1
            }
            throw DockerSemanticHelperError.helperExited
        }
        let requestID = process.nextRequestID
        let (next, overflow) = requestID.addingReportingOverflow(1)
        guard !overflow, next != 0 else {
            process.fenced = true
            throw DockerSemanticHelperError.generationFenced
        }
        process.nextRequestID = next
        return (requestID, process.descriptor)
    }

    private func writeAll(
        _ bytes: Data,
        descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < rawBuffer.count {
                try waitUntilWritable(descriptor, deadline: deadline)
                let result = csh_write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, Self.isRetryableIOError() {
                    continue
                } else {
                    throw DockerSemanticHelperError.helperExited
                }
            }
        }
    }

    private func readExactly(
        _ count: Int,
        descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> Data {
        guard count >= 0 else {
            throw DockerSemanticHelperError.protocolViolation
        }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var readCount = 0
            while readCount < count {
                try waitUntilReadable(descriptor, deadline: deadline)
                let amount = csh_read(
                    descriptor,
                    baseAddress.advanced(by: readCount),
                    count - readCount
                )
                if amount > 0 {
                    readCount += amount
                } else if amount < 0, Self.isRetryableIOError() {
                    continue
                } else {
                    throw DockerSemanticHelperError.helperExited
                }
            }
        }
        return result
    }

    private func waitUntilReadable(
        _ descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        let result = csh_poll_readable(
            descriptor,
            try Self.remainingMilliseconds(deadline: deadline)
        )
        if result == 0 {
            throw DockerSemanticHelperError.deadlineExceeded
        }
        guard result > 0 else {
            throw DockerSemanticHelperError.helperExited
        }
    }

    private func waitUntilWritable(
        _ descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        let result = csh_poll_writable(
            descriptor,
            try Self.remainingMilliseconds(deadline: deadline)
        )
        if result == 0 {
            throw DockerSemanticHelperError.deadlineExceeded
        }
        guard result > 0 else {
            throw DockerSemanticHelperError.helperExited
        }
    }

    private func fencedProtocolViolation() -> DockerSemanticHelperError {
        fenceGeneration()
        return .protocolViolation
    }

    private func fenceGeneration() {
        let pid: pid_t
        let descriptor: Int32
        stateLock.lock()
        if process.fenced {
            stateLock.unlock()
            return
        }
        process.fenced = true
        pid = process.pid
        descriptor = process.descriptor
        process.descriptor = -1
        stateLock.unlock()

        if descriptor >= 0 {
            _ = csh_close(descriptor)
        }
        if pid > 0 {
            _ = csh_signal(pid, csh_signal_terminate())
            var status: Int32 = 0
            for _ in 0..<20 {
                if csh_wait_nohang(pid, &status) == pid {
                    return
                }
                usleep(1_000)
            }
            _ = csh_signal(pid, csh_signal_kill())
            _ = csh_wait(pid, &status)
        }
    }

    private static func loadAndVerifyManifest(
        _ configuration: DockerSemanticHelperLaunchConfiguration
    ) throws -> DockerSemanticHelperManifest {
        let manifestData = try Data(
            contentsOf: configuration.manifestURL,
            options: [.mappedIfSafe]
        )
        guard manifestData.count <= DockerSemanticHelperManifest.maximumEncodedBytes
        else {
            throw DockerSemanticHelperError.invalidManifest
        }
        let manifest: DockerSemanticHelperManifest
        do {
            manifest = try JSONDecoder().decode(
                DockerSemanticHelperManifest.self,
                from: manifestData
            )
            try manifest.validatePinnedProvenance()
        } catch let error as DockerSemanticHelperError {
            throw error
        } catch {
            throw DockerSemanticHelperError.invalidManifest
        }

        let binaryData = try Data(
            contentsOf: configuration.executableURL,
            options: [.mappedIfSafe]
        )
        let binaryDigest = SHA256.hash(data: binaryData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard binaryDigest == manifest.binarySHA256 else {
            throw DockerSemanticHelperError.binaryDigestMismatch
        }
        if configuration.verifyCodeSignature {
            try verifyCodeSignature(at: configuration.executableURL)
        }
        return manifest
    }

    private static func verifyCodeSignature(at url: URL) throws {
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                url as CFURL,
                SecCSFlags(),
                &staticCode
            ) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            ) == errSecSuccess
        else {
            throw DockerSemanticHelperError.invalidCodeSignature
        }
    }

    private static func timeoutNanoseconds(_ timeout: Duration) throws -> UInt64 {
        guard timeout > .zero, timeout <= maximumTimeout else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        let components = timeout.components
        guard components.seconds >= 0 else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        let (secondNanoseconds, overflow) = UInt64(components.seconds)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let attosecondNanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let (result, additionOverflow) =
            secondNanoseconds
            .addingReportingOverflow(attosecondNanoseconds)
        guard !overflow, !additionOverflow, result > 0 else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        return result
    }

    private static func remainingMilliseconds(
        deadline: ContinuousClock.Instant
    ) throws -> Int32 {
        let now = ContinuousClock.now
        guard now < deadline else {
            throw DockerSemanticHelperError.deadlineExceeded
        }
        let duration = now.duration(to: deadline)
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let millisecondsFromSeconds = min(
            seconds * 1_000,
            Int64(Int32.max)
        )
        let fractionalMilliseconds = max(
            components.attoseconds / 1_000_000_000_000_000,
            0
        )
        let rounded = min(
            millisecondsFromSeconds + fractionalMilliseconds + 1,
            Int64(Int32.max)
        )
        return Int32(rounded)
    }

    private static func isRetryableIOError() -> Bool {
        let error = csh_errno()
        return error == csh_error_interrupted()
            || error == csh_error_would_block()
    }
}

private final class DockerSemanticHelperClientPool: @unchecked Sendable {
    static let shared = DockerSemanticHelperClientPool()

    private struct Key: Hashable {
        let generation: DockerSemanticHelperGeneration
        let launchConfiguration: DockerSemanticHelperLaunchConfiguration
    }

    private let lock = NSLock()
    private var clients = [Key: DockerSemanticHelperClient]()
    private var retiredGenerationByProviderID = [String: UInt64]()

    func client(
        generation: DockerSemanticHelperGeneration,
        launchConfiguration: DockerSemanticHelperLaunchConfiguration
    ) throws -> DockerSemanticHelperClient {
        let key = Key(
            generation: generation,
            launchConfiguration: launchConfiguration
        )
        lock.lock()
        defer { lock.unlock() }
        if let retiredGeneration = retiredGenerationByProviderID[
            generation.providerID
        ], generation.providerGeneration <= retiredGeneration {
            throw DockerSemanticHelperError.generationFenced
        }
        if let existing = clients[key] {
            return existing
        }
        let client = try DockerSemanticHelperClient(
            generation: generation,
            launchConfiguration: launchConfiguration
        )
        clients[key] = client
        return client
    }

    func retire(through generation: DockerSemanticHelperGeneration) {
        let clientsToFence: [DockerSemanticHelperClient]
        lock.lock()
        let retiredGeneration = max(
            retiredGenerationByProviderID[generation.providerID] ?? 0,
            generation.providerGeneration
        )
        retiredGenerationByProviderID[generation.providerID] = retiredGeneration
        let keysToRemove = clients.keys.filter {
            $0.generation.providerID == generation.providerID
                && $0.generation.providerGeneration <= retiredGeneration
        }
        clientsToFence = keysToRemove.compactMap {
            clients.removeValue(forKey: $0)
        }
        lock.unlock()

        for client in clientsToFence {
            client.cancelAndFenceGeneration()
        }
    }
}
