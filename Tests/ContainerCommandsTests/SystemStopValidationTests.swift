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
import Testing

@testable import ContainerCommands
@testable import ContainerXPC

struct SystemStopValidationTests {
    @Test
    func rejectsPathPrefix() throws {
        let namespace = try ContainerServiceNamespace("com.example.svc")
        #expect(throws: ContainerServiceNamespace.Error.self) {
            try namespace.servicePrefix(requestedPrefix: "/usr/local/container")
        }
    }

    @Test
    func rejectsInvalidCharacters() throws {
        let namespace = try ContainerServiceNamespace("com.example.svc")
        #expect(throws: ContainerServiceNamespace.Error.self) {
            try namespace.servicePrefix(requestedPrefix: "foo bar")
        }
    }

    @Test
    func acceptsDefaultPrefix() throws {
        let namespace = try ContainerServiceNamespace("com.apple.container")
        #expect(try namespace.servicePrefix(requestedPrefix: nil) == "com.apple.container.")
    }

    @Test
    func acceptsCustomReverseDNSPrefix() throws {
        let namespace = try ContainerServiceNamespace("com.example.svc")
        #expect(
            try namespace.servicePrefix(requestedPrefix: "com.example.svc.")
                == "com.example.svc."
        )
    }

    @Test
    func unhealthyAPIServerRemainsInLaunchdCleanupSet() {
        #expect(
            Application.SystemStop.serviceLabelsToDeregister(
                [
                    "com.example.svc.apiserver",
                    "com.example.svc.network-vmnet",
                    "com.other.svc.apiserver",
                ],
                servicePrefix: "com.example.svc.",
                launchdDomainString: "gui/501"
            ) == [
                "gui/501/com.example.svc.apiserver",
                "gui/501/com.example.svc.network-vmnet",
            ]
        )
    }

    @Test
    func rejectsFailedBootoutOfRegisteredService() {
        #expect(throws: ContainerizationError.self) {
            try Application.SystemStop.stopServiceAndConfirmInactive(
                fullServiceLabel: "gui/501/com.example.svc.apiserver",
                deregisterService: { _ in 5 },
                isServiceRegistered: { _ in true }
            )
        }
    }

    @Test
    func acceptsFailedBootoutOfAlreadyInactiveService() throws {
        try Application.SystemStop.stopServiceAndConfirmInactive(
            fullServiceLabel: "gui/501/com.example.svc.apiserver",
            deregisterService: { _ in 5 },
            isServiceRegistered: { _ in false }
        )
    }

    @Test
    func rejectsAParsedPrefixThatCannotMatchTheDefaultNamespace() async throws {
        let command = try Application.SystemStop.parse([
            "--prefix", "com.example.svc.",
        ])

        do {
            try await command.run()
            Issue.record("expected a mismatched service prefix to fail before service discovery")
        } catch let error as ContainerServiceNamespace.Error {
            #expect(
                error
                    == .mismatchedServicePrefix(
                        expected: "com.apple.container.",
                        actual: "com.example.svc."
                    )
            )
        }
    }
}
