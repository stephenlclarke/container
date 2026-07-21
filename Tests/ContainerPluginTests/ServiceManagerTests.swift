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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerPlugin

struct ServiceManagerTests {
    @Test func acceptsSuccessfulLaunchctlStatus() throws {
        try ServiceManager.validateLaunchctlSuccess(
            status: 0,
            args: ["bootstrap", "gui/501", "/tmp/service.plist"]
        )
    }

    @Test func rejectsFailedLaunchctlStatus() throws {
        let error = #expect(throws: ContainerizationError.self) {
            try ServiceManager.validateLaunchctlSuccess(
                status: 5,
                args: ["bootstrap", "gui/501", "/tmp/service.plist"]
            )
        }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains("launchctl bootstrap gui/501 /tmp/service.plist") == true)
        #expect(error?.message.hasSuffix("status 5") == true)
    }

    @Test func registrationActionRegistersWhenServiceIsMissing() {
        #expect(
            ServiceManager.registrationAction(
                loadedPlistPath: nil,
                expectedPlistPath: "/tmp/current/service.plist"
            ) == .register
        )
    }

    @Test func registrationActionReusesMatchingService() throws {
        let directory = "/tmp/container-service-manager-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let plistPath = "\(directory)/service.plist"
        FileManager.default.createFile(atPath: plistPath, contents: Data())

        #expect(
            ServiceManager.registrationAction(
                loadedPlistPath: "/private\(plistPath)",
                expectedPlistPath: plistPath
            ) == .reuse
        )
    }

    @Test func registrationActionReplacesStaleService() {
        #expect(
            ServiceManager.registrationAction(
                loadedPlistPath: "/tmp/previous/service.plist",
                expectedPlistPath: "/tmp/current/service.plist"
            ) == .replace
        )
    }

    @Test func parsesPlistPathFromLaunchctlPrint() {
        let output = """
            gui/501/com.apple.container.example = {
                path = /private/tmp/container/app/service.plist
                state = running
            }
            """
        #expect(ServiceManager.plistPath(fromLaunchctlPrint: output) == "/private/tmp/container/app/service.plist")
    }
}
