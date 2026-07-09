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
import Logging
import SystemPackage
import Testing

@testable import ContainerPlugin

struct ApplicationRootTests {
    @Test func defaultPathIsAbsolute() {
        #expect(ApplicationRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathEndsWithContainerComponent() {
        #expect(ApplicationRoot.defaultPath.lastComponent?.string == "com.apple.container")
    }

    @Test func ensureCreatedExcludesAppRootFromBackups() throws {
        let appRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-app-root-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: appRoot)
        }

        var log = Logger(label: "test.ApplicationRoot")
        log.logLevel = .critical

        try ApplicationRoot.ensureCreated(at: appRoot, log: log)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: appRoot.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)

        let values = try appRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

struct InstallRootTests {
    @Test func defaultPathIsAbsolute() {
        #expect(InstallRoot.defaultPath.isAbsolute)
    }

    @Test func defaultPathIsGrandparentOfExecutable() {
        #expect(InstallRoot.defaultPath == CommandLine.executablePath.removingLastComponent().removingLastComponent())
    }

    @Test func pathUsesEnvironmentOverride() {
        #expect(
            InstallRoot.resolve(
                environment: [InstallRoot.environmentName: "/opt/container"],
                currentDirectory: "/tmp"
            ) == FilePath("/opt/container")
        )
    }

    @Test func pathResolvesRelativeEnvironmentOverride() {
        #expect(
            InstallRoot.resolve(
                environment: [InstallRoot.environmentName: "container-root"],
                currentDirectory: "/opt/homebrew"
            ) == FilePath("/opt/homebrew/container-root")
        )
    }

    @Test func pathFallsBackToDefaultWhenEnvironmentIsMissing() {
        #expect(InstallRoot.resolve(environment: [:], currentDirectory: "/tmp") == InstallRoot.defaultPath)
    }
}

struct LogRootTests {
    @Test func pathIsNilWhenEnvUnset() {
        // CONTAINER_LOG_ROOT is not set in the unit test environment
        #expect(LogRoot.path == nil)
    }
}
