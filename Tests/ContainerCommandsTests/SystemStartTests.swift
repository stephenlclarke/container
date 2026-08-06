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

import ContainerPlugin
import ContainerizationError
import Darwin
import Foundation
import SystemPackage
import Testing

@testable import ContainerCommands

struct SystemStartTests {
    @Test func parsesInitialFilesystemArchive() throws {
        let archive = "/tmp/container-system-start-init-image.tar"
        let command = try Application.SystemStart.parse([
            "--init-image-archive", archive,
        ])

        #expect(command.initImageArchive?.string == archive)
    }

    @Test func initialFilesystemPullDoesNotParseSystemStartArguments() throws {
        let reference =
            "ghcr.io/stephenlclarke/containerization/vminit:"
            + String(repeating: "a", count: 40)

        let command = try Application.SystemStart.initialFilesystemPullCommand(
            initImage: reference
        )

        #expect(command.reference == reference)
        #expect(command.registry.scheme == "auto")
        #expect(command.progressFlags.progress == .auto)
        #expect(command.imageFetchFlags.maxConcurrentDownloads == 3)
        #expect(command.arch == nil)
        #expect(command.os == nil)
        #expect(command.platform == nil)
    }

    @Test func engineConfigurationUsesPrivateShortPublicSocket() {
        let configuration = ContainerEngineServiceConfiguration(
            appRoot: FilePath("/tmp/container-state"),
            effectiveUserID: 501
        )
        #expect(
            configuration.publicSocketPath.string
                == "/tmp/container-engine-501/docker.sock"
        )
        #expect(
            configuration.providerSocketPath.string
                == "/tmp/container-state/engine-provider/provider.sock"
        )
        #expect(
            configuration.stateDirectory.string
                == "/tmp/container-state/engine-gateway"
        )
        let pathCapacity = withUnsafeBytes(of: sockaddr_un().sun_path) {
            $0.count
        }
        #expect(configuration.publicSocketPath.string.utf8.count < pathCapacity)
        #expect(
            configuration.arguments(executablePath: "/usr/local/bin/container-engine")
                == [
                    "/usr/local/bin/container-engine",
                    "--socket", "/tmp/container-engine-501/docker.sock",
                    "--provider-socket", "/tmp/container-state/engine-provider/provider.sock",
                    "--state-directory", "/tmp/container-state/engine-gateway",
                ]
        )
    }

    @Test func engineLaunchPlistIsPrivateAndComplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "container-engine-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ContainerEngineServiceConfiguration(
            appRoot: FilePath(root.path(percentEncoded: false))
        )
        let arguments = configuration.arguments(
            executablePath: "/usr/local/bin/container-engine"
        )
        try configuration.writeLaunchPlist(
            LaunchPlist(
                label: ContainerEngineServiceConfiguration.launchdLabel,
                arguments: arguments,
                runAtLoad: true,
                keepAlive: true
            )
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: configuration.plistPath.string
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let data = try Data(
            contentsOf: URL(fileURLWithPath: configuration.plistPath.string)
        )
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(
            plist["Label"] as? String
                == ContainerEngineServiceConfiguration.launchdLabel
        )
        #expect(plist["ProgramArguments"] as? [String] == arguments)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
    }

    @Test func acceptsMatchingAppRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Application.SystemStart.validateAppRoot(
            requested: FilePath(root.path(percentEncoded: false)),
            actual: root
        )
    }

    @Test func rejectsMismatchedAppRoot() throws {
        let requested = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-requested-\(UUID())")
        let actual = FileManager.default.temporaryDirectory
            .appending(path: "container-system-start-actual-\(UUID())")
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: requested)
            try? FileManager.default.removeItem(at: actual)
        }

        let error = #expect(throws: ContainerizationError.self) {
            try Application.SystemStart.validateAppRoot(
                requested: FilePath(requested.path(percentEncoded: false)),
                actual: actual
            )
        }
        #expect(error?.code == .invalidState)
        #expect(error?.message.contains("stop it before changing --app-root") == true)
    }
}
