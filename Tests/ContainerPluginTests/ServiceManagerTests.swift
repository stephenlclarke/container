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
    @Test func drainsOutputLargerThanPipeCapacityAndPreservesExitStatus() throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "head -c 1048576 /dev/zero; exit 7"]
        let data = try ServiceManager.runReadingOutput(process)
        #expect(data.count == 1_048_576)
        #expect(data.allSatisfy { $0 == 0 })
        #expect(process.terminationStatus == 7)
    }

    @Test func outputQueryPropagatesLaunchFailure() throws {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/launchctl")
        #expect(throws: (any Error).self) {
            try ServiceManager.runReadingOutput(process)
        }
    }

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

    @Test func preservesLaunchctlFailureDiagnostic() throws {
        let error = #expect(throws: ContainerizationError.self) {
            try ServiceManager.validateLaunchctlSuccess(
                status: 5,
                standardError: "Bootstrap failed: 5: Input/output error\n",
                args: ["bootstrap", "system", "/tmp/service.plist"]
            )
        }
        #expect(error?.code == .internalError)
        #expect(
            error?.message
                == "command `launchctl bootstrap system /tmp/service.plist` failed with status 5: Bootstrap failed: 5: Input/output error"
        )
    }

    @Test(arguments: [
        LaunchPlist.Domain.System.rawValue,
        LaunchPlist.Domain.Background.rawValue,
        LaunchPlist.Domain.Aqua.rawValue,
    ])
    func rootUsesSystemDomain(sessionType: String) throws {
        #expect(try ServiceManager.domainString(sessionType: sessionType, effectiveUserID: 0) == "system")
    }

    @Test func backgroundUserUsesUserDomain() throws {
        #expect(
            try ServiceManager.domainString(
                sessionType: LaunchPlist.Domain.Background.rawValue,
                effectiveUserID: 501
            ) == "user/501"
        )
    }

    @Test func aquaUserUsesGuiDomain() throws {
        #expect(
            try ServiceManager.domainString(
                sessionType: LaunchPlist.Domain.Aqua.rawValue,
                effectiveUserID: 501
            ) == "gui/501"
        )
    }

    @Test func rejectsUnsupportedNonRootSession() throws {
        let error = #expect(throws: ContainerizationError.self) {
            try ServiceManager.domainString(sessionType: "LoginWindow", effectiveUserID: 501)
        }
        #expect(error?.message == "unsupported session type LoginWindow")
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

    @Test func deregistrationReturnsSuccessfulBootoutWithoutRecovery() throws {
        var calls: [([String], TimeInterval?)] = []
        let result = try ServiceManager.deregister(
            fullServiceLabel: "gui/501/com.apple.container.runtime.example",
            timeoutSeconds: 0.25
        ) { args, timeout in
            calls.append((args, timeout))
            return ServiceManager.LaunchctlCommandResult(status: 0, standardError: "")
        }

        #expect(result.status == 0)
        #expect(calls.count == 1)
        #expect(calls[0].0 == ["bootout", "gui/501/com.apple.container.runtime.example"])
        #expect(calls[0].1 == 0.25)
    }

    @Test func timedOutDeregistrationKillsServiceAndRetriesBootout() throws {
        let label = "gui/501/com.apple.container.runtime.stale"
        var calls: [([String], TimeInterval?)] = []
        let result = try ServiceManager.deregister(
            fullServiceLabel: label,
            timeoutSeconds: 0.25
        ) { args, timeout in
            calls.append((args, timeout))
            if calls.count == 1 {
                throw ServiceManager.LaunchctlCommandTimeoutError(
                    args: args,
                    timeoutSeconds: timeout ?? 0
                )
            }
            return ServiceManager.LaunchctlCommandResult(status: 0, standardError: "")
        }

        #expect(result.status == 0)
        #expect(
            calls.map(\.0) == [
                ["bootout", label],
                ["kill", "SIGKILL", label],
                ["bootout", label],
            ])
        #expect(calls.allSatisfy { $0.1 == 0.25 })
    }

    @Test func ordinaryBootoutFailureDoesNotKillService() throws {
        var calls: [[String]] = []
        let result = try ServiceManager.deregister(
            fullServiceLabel: "gui/501/com.apple.container.runtime.missing",
            timeoutSeconds: 0.25
        ) { args, _ in
            calls.append(args)
            return ServiceManager.LaunchctlCommandResult(
                status: 3,
                standardError: "Could not find service"
            )
        }

        #expect(result.status == 3)
        #expect(calls == [["bootout", "gui/501/com.apple.container.runtime.missing"]])
    }

    @Test func exactDomainRegistrationUsesPrintAndMatchesOnlyItsOwnAbsence() throws {
        let cases = [
            ("system/example.service", "Could not find service \"example.service\" in domain for system"),
            ("gui/501/example.service", "Could not find service \"example.service\" in domain for user gui: 501"),
            ("user/501/example.service", "Could not find service \"example.service\" in domain for uid: 501"),
        ]
        for (target, missing) in cases {
            var arguments: [String] = []
            var observedTimeout: TimeInterval?
            #expect(
                try ServiceManager.isRegistered(fullServiceLabel: target) { args, timeout in
                    arguments = args
                    observedTimeout = timeout
                    return .init(status: 0, standardError: "")
                })
            #expect(arguments == ["print", target])
            #expect(observedTimeout == 5)
            #expect(
                try !ServiceManager.isRegistered(fullServiceLabel: target) { _, _ in
                    .init(status: 113, standardError: "Bad request.\n\(missing)\n")
                })
            #expect(throws: ContainerizationError.self) {
                try ServiceManager.isRegistered(fullServiceLabel: target) { _, _ in
                    .init(status: 113, standardError: "Could not find service \"another.service\" in domain for system")
                }
            }
            #expect(throws: ContainerizationError.self) {
                try ServiceManager.isRegistered(fullServiceLabel: target) { _, _ in
                    .init(status: 1, standardError: missing)
                }
            }
            #expect(throws: ContainerizationError.self) {
                try ServiceManager.isRegistered(fullServiceLabel: target) { _, _ in
                    .init(status: 113, standardError: "permission denied")
                }
            }
        }
    }

    @Test func bareRegistrationKeepsCurrentDomainListAndMalformedTargetsFailClosed() throws {
        var arguments: [String] = []
        #expect(
            try ServiceManager.isRegistered(fullServiceLabel: "example.service") { args, _ in
                arguments = args
                return .init(status: 0, standardError: "")
            })
        #expect(arguments == ["list", "example.service"])
        for target in ["", "gui/example.service", "gui/501/example.service/extra", "other/501/example.service"] {
            #expect(throws: ContainerizationError.self) {
                try ServiceManager.isRegistered(fullServiceLabel: target) { _, _ in
                    Issue.record("malformed target reached launchctl")
                    return .init(status: 0, standardError: "")
                }
            }
        }
    }
}
