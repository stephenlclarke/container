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

import Containerization
import ContainerizationArchive
import ContainerizationError
import CryptoKit
import Foundation
import Logging
import Testing

@testable import ContainerAPIService

struct KernelServiceTests {
    @Test func installKernelFromLocalTarVerifiesDigest() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let digest = try KernelService.sha256Hex(of: tarFile)

            try await service.installKernelFrom(
                tar: URL(string: tarFile.path)!,
                kernelFilePath: kernelPath,
                platform: .linuxArm,
                progressUpdate: nil,
                expectedDigest: "sha256:\(digest)",
                force: false)

            let kernel = try await service.getDefaultKernel(platform: .linuxArm)
            #expect(try Data(contentsOf: kernel.path) == kernelData)
        }
    }

    @Test func installKernelFromLocalTarRejectsDigestMismatchWithoutInstalling() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let wrongDigest = String(repeating: "0", count: 64)

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(fileURLWithPath: tarFile.path),
                    kernelFilePath: kernelPath,
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: "sha256:\(wrongDigest)",
                    force: false)
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromLocalTarRejectsInvalidDigestValues() async throws {
        try await withTempDir { tempDir in
            let kernelPath = "boot/vmlinux"
            let kernelData = Data("kernel binary".utf8)
            let tarFile = try Self.writeTar(
                at: tempDir.appendingPathComponent("kernel.tar"),
                path: kernelPath,
                data: kernelData)
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))
            let sha256 = try KernelService.sha256Hex(of: tarFile)
            let sha1 = try Self.sha1Hex(of: tarFile)
            let invalidDigests = [
                "sha256-not-a-digest",
                "sha1:\(sha1)",
                "sha256:not-a-digest",
                String(repeating: "0", count: 64),
                "sha256:\(String(sha256.dropLast(2)))",
                "sha256:\(sha1)",
            ]

            for digest in invalidDigests {
                await #expect(throws: ContainerizationError.self) {
                    try await service.installKernelFrom(
                        tar: URL(fileURLWithPath: tarFile.path),
                        kernelFilePath: kernelPath,
                        platform: .linuxArm,
                        progressUpdate: nil,
                        expectedDigest: digest,
                        force: false)
                }
            }
            await #expect(throws: ContainerizationError.self) {
                _ = try await service.getDefaultKernel(platform: .linuxArm)
            }
        }
    }

    @Test func installKernelFromRemoteTarRequiresDigest() async throws {
        try await withTempDir { tempDir in
            let service = try KernelService(
                log: Logger(label: "com.apple.container.test.kernel-service"),
                appRoot: tempDir.appendingPathComponent("app"))

            await #expect(throws: ContainerizationError.self) {
                try await service.installKernelFrom(
                    tar: URL(string: "https://example.com/kernel.tar")!,
                    kernelFilePath: "boot/vmlinux",
                    platform: .linuxArm,
                    progressUpdate: nil,
                    expectedDigest: nil,
                    force: false)
            }
        }
    }

    @Test("Kernel archive preparation does not hold actor isolation")
    func archivePreparationDoesNotBlockActor() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probe = KernelArchiveIsolationProbe()
        let preparation = Task {
            try await probe.prepare(started: started, release: release)
        }

        let didStart = await KernelArchiveSemaphore.wait(started, timeout: .now() + 1)
        guard didStart else {
            release.signal()
            preparation.cancel()
            throw KernelArchiveTestError.timedOut
        }

        let pinged = KernelArchiveCountdown(count: 1)
        let ping = Task {
            await probe.ping(pinged)
        }
        do {
            try await pinged.wait(timeout: .seconds(1))
        } catch {
            release.signal()
            preparation.cancel()
            throw error
        }

        release.signal()
        await ping.value
        #expect(try await preparation.value == 1)
    }

    private static func writeTar(at tarFile: URL, path: String, data: Data) throws -> URL {
        let archiver = try ArchiveWriter(format: .paxRestricted, filter: .none, file: tarFile)
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.size = numericCast(data.count)
        try archiver.writeEntry(entry: entry, data: data)
        try archiver.finishEncoding()
        return tarFile
    }

    private static func sha1Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withTempDir(body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }
}

private enum KernelArchiveTestError: Error {
    case timedOut
}

private enum KernelArchiveSemaphore {
    static func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}

private actor KernelArchiveCountdown {
    private var remaining: Int

    init(count: Int) {
        self.remaining = count
    }

    func arrive() {
        remaining -= 1
    }

    func wait(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while remaining > 0 {
            guard clock.now < deadline else {
                throw KernelArchiveTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor KernelArchiveIsolationProbe {
    func prepare(started: DispatchSemaphore, release: DispatchSemaphore) async throws -> Int {
        try await ConcurrentKernelArchiveIO.run {
            started.signal()
            release.wait()
            return 1
        }
    }

    func ping(_ countdown: KernelArchiveCountdown) async {
        await countdown.arrive()
    }
}
