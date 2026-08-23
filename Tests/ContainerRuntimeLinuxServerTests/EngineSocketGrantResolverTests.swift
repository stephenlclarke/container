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

import ContainerEngineRuntimeSPI
import ContainerXPC
import ContainerizationError
import Darwin
import Foundation
import Testing

@testable import ContainerRuntimeLinuxServer

@Suite
struct EngineSocketGrantResolverTests {
    @Test
    func `grant is stable canonical and matches the pinned Docker ownership oracle`() throws {
        let namespace = try ContainerServiceNamespace("tests.engine.socket")
        let source = URL(filePath: "/tmp/private-authority/docker.sock")
        let intent = try InboundUnixSocketIntentV1.engineAPI()

        let first = try EngineSocketGrantResolver.configuration(
            intent,
            containerID: "example",
            serviceNamespace: namespace,
            source: source
        )
        let second = try EngineSocketGrantResolver.configuration(
            intent,
            containerID: "example",
            serviceNamespace: namespace,
            source: source
        )

        #expect(first.id == second.id)
        #expect(first.id.hasPrefix("engine-api-"))
        #expect(first.source == source)
        #expect(first.destination.path == "/var/run/docker.sock")
        #expect(first.permissions?.rawValue == 0o660)
        #expect(first.guestOwnership?.uid == 0)
        #expect(first.guestOwnership?.gid == 991)
        #expect(first.direction == .into)
    }

    @Test
    func `grant identity is fenced by container and service namespace`() throws {
        let intent = try InboundUnixSocketIntentV1.engineAPI()
        let source = URL(filePath: "/tmp/private-authority/docker.sock")
        let firstNamespace = try ContainerServiceNamespace("tests.engine.first")
        let secondNamespace = try ContainerServiceNamespace("tests.engine.second")

        let first = try EngineSocketGrantResolver.configuration(
            intent,
            containerID: "one",
            serviceNamespace: firstNamespace,
            source: source
        )
        let otherContainer = try EngineSocketGrantResolver.configuration(
            intent,
            containerID: "two",
            serviceNamespace: firstNamespace,
            source: source
        )
        let otherNamespace = try EngineSocketGrantResolver.configuration(
            intent,
            containerID: "one",
            serviceNamespace: secondNamespace,
            source: source
        )

        #expect(first.id != otherContainer.id)
        #expect(first.id != otherNamespace.id)
    }

    @Test
    func `source identity accepts only a socket owned by the current authority user`() throws {
        try EngineSocketGrantResolver.validateSourceIdentity(
            mode: mode_t(S_IFSOCK | 0o600),
            owner: 501,
            effectiveUserID: 501
        )

        #expect(throws: ContainerizationError.self) {
            try EngineSocketGrantResolver.validateSourceIdentity(
                mode: mode_t(S_IFREG | 0o600),
                owner: 501,
                effectiveUserID: 501
            )
        }
        #expect(throws: ContainerizationError.self) {
            try EngineSocketGrantResolver.validateSourceIdentity(
                mode: mode_t(S_IFSOCK | 0o600),
                owner: 502,
                effectiveUserID: 501
            )
        }
    }
}
