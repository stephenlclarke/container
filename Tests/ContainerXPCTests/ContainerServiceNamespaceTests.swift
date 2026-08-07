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

#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import ContainerXPC

@Suite(.serialized)
struct ContainerServiceNamespaceTests {
    @Test
    func defaultNamespacePreservesCurrentServiceNames() throws {
        let namespace = try ContainerServiceNamespace.resolve(environment: [:])

        #expect(namespace.value == "com.apple.container")
        #expect(namespace.apiServerIdentifier == "com.apple.container.apiserver")
        #expect(namespace.machineAPIServerIdentifier == "com.apple.container.core.machine-apiserver")
        #expect(namespace.imagesServiceIdentifier == "com.apple.container.core.container-core-images")
        #expect(namespace.runtimeServicePrefix == "com.apple.container.runtime")
        #expect(namespace.networkServicePrefix == "com.apple.container.network")
        #expect(namespace.engineLaunchdLabel == "io.github.stephenlclarke.container.engine")
    }

    @Test
    func customNamespaceScopesEveryServiceIdentity() throws {
        let namespace = try ContainerServiceNamespace.resolve(
            environment: [ContainerServiceNamespace.environmentName: "io.github.example.candidate"]
        )

        #expect(namespace.apiServerIdentifier == "io.github.example.candidate.apiserver")
        #expect(namespace.machineAPIServerIdentifier == "io.github.example.candidate.core.machine-apiserver")
        #expect(namespace.imagesServiceIdentifier == "io.github.example.candidate.core.container-core-images")
        #expect(namespace.runtimeServicePrefix == "io.github.example.candidate.runtime")
        #expect(namespace.networkServicePrefix == "io.github.example.candidate.network")
        #expect(namespace.engineLaunchdLabel == "io.github.example.candidate.engine")
        #expect(namespace.socketDirectorySuffix.count == 24)
        for character in namespace.socketDirectorySuffix {
            #expect(character.isHexDigit)
        }
    }

    @Test
    func servicePrefixCannotEscapeResolvedNamespace() throws {
        let namespace = try ContainerServiceNamespace("io.github.example.candidate")

        #expect(try namespace.servicePrefix(requestedPrefix: nil) == "io.github.example.candidate.")
        #expect(
            try namespace.servicePrefix(
                requestedPrefix: "io.github.example.candidate."
            ) == "io.github.example.candidate."
        )
        #expect(throws: ContainerServiceNamespace.Error.self) {
            try namespace.servicePrefix(requestedPrefix: "com.apple.container.")
        }
    }

    @Test(arguments: ["", ".candidate", "candidate.", "candidate..test", "candidate/test", "candidate test"])
    func malformedOverrideIsRejected(value: String) {
        #expect(throws: ContainerServiceNamespace.Error.self) {
            try ContainerServiceNamespace.resolve(
                environment: [ContainerServiceNamespace.environmentName: value]
            )
        }
    }

    @Test
    func namespaceLengthAndSupportedLabelCharactersAreValidated() throws {
        let valid = "io_github.example-1.candidate_2"
        #expect(try ContainerServiceNamespace(valid).value == valid)

        let tooLong = String(repeating: "a", count: 193)
        #expect(throws: ContainerServiceNamespace.Error.self) {
            try ContainerServiceNamespace(tooLong)
        }
    }

    @Test
    func validationErrorsExplainTheSafeNamespaceBoundary() {
        let invalid = ContainerServiceNamespace.Error.invalid("candidate/test")
        #expect(
            invalid.errorDescription
                == "invalid CONTAINER_SERVICE_NAMESPACE \"candidate/test\": use dot-separated launchd-label components containing only letters, digits, '-', or '_'"
        )

        let mismatch = ContainerServiceNamespace.Error.mismatchedServicePrefix(
            expected: "io.github.example.candidate.",
            actual: "com.apple.container."
        )
        #expect(
            mismatch.errorDescription == "--prefix must match CONTAINER_SERVICE_NAMESPACE (io.github.example.candidate.), got com.apple.container."
        )
    }

    @Test
    func currentFailsClosedForAnInvalidProcessOverride() {
        let environmentName = ContainerServiceNamespace.environmentName
        let originalValue = ProcessInfo.processInfo.environment[environmentName]
        defer {
            if let originalValue {
                setenv(environmentName, originalValue, 1)
            } else {
                unsetenv(environmentName)
            }
        }

        #expect(setenv(environmentName, "candidate/invalid", 1) == 0)
        #expect(ContainerServiceNamespace.current.value == "invalid.container.namespace")
    }
}
#endif
