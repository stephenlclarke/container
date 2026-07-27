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

import ContainerTestSupport
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ContainerTestSupportTests {

    @Test
    func additionalCABundleUsesDistinctAlpineReferences() {
        let originalBundle = ProcessInfo.processInfo.environment["CLITEST_CA_BUNDLE"]
        defer { restoreEnvironment("CLITEST_CA_BUNDLE", to: originalBundle) }

        unsetenv("CLITEST_CA_BUNDLE")
        for image in WarmupImage.allCases {
            #expect(image.preparedReference == image.rawValue)
        }

        setenv("CLITEST_CA_BUNDLE", "/tmp/clitest-ca-bundle.pem", 1)
        #expect(WarmupImage.alpine320.preparedReference != WarmupImage.alpine320.rawValue)
        #expect(WarmupImage.alpine318.preparedReference != WarmupImage.alpine318.rawValue)
        #expect(WarmupImage.busybox136.preparedReference == WarmupImage.busybox136.rawValue)
    }

    @Test
    func dnsOverrideIsAppliedOnlyWhenRequested() async throws {
        let originalNameservers = ProcessInfo.processInfo.environment["CLITEST_DNS_NAMESERVERS"]
        let originalEchoArguments = ProcessInfo.processInfo.environment["CLITEST_ECHO_ARGUMENTS"]
        let originalArgumentLog = ProcessInfo.processInfo.environment["CLITEST_ARGUMENT_LOG"]
        let argumentLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-test-support-\(UUID().uuidString).log")
        setenv("CLITEST_DNS_NAMESERVERS", "10.0.0.1, 10.0.0.2", 1)
        setenv("CLITEST_ECHO_ARGUMENTS", "true", 1)
        setenv("CLITEST_ARGUMENT_LOG", argumentLog.path, 1)
        defer {
            restoreEnvironment("CLITEST_DNS_NAMESERVERS", to: originalNameservers)
            restoreEnvironment("CLITEST_ECHO_ARGUMENTS", to: originalEchoArguments)
            restoreEnvironment("CLITEST_ARGUMENT_LOG", to: originalArgumentLog)
            try? FileManager.default.removeItem(at: argumentLog)
        }

        try await withFakeContainerCLI {
            try await ContainerFixture.with { fixture in
                for command in ["build", "create", "run"] {
                    let result = try fixture.run([command, "example"])
                    #expect(
                        result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                            == [command, "--dns", "10.0.0.1", "--dns", "10.0.0.2", "example"])
                }

                let globalFlag = try fixture.run(["--debug", "run", "example"])
                #expect(
                    globalFlag.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        == ["--debug", "run", "--dns", "10.0.0.1", "--dns", "10.0.0.2", "example"])

                let passthrough = try fixture.run(["run", "example", "--dns", "192.0.2.1"])
                #expect(
                    passthrough.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        == ["run", "--dns", "10.0.0.1", "--dns", "10.0.0.2", "example", "--dns", "192.0.2.1"])

                let disabled = try fixture.run(
                    ["run", "--no-dns", "example"], dnsOverride: false)
                #expect(
                    disabled.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        == ["run", "--no-dns", "example"])

                let unrelated = try fixture.run(["exec", "example", "run"])
                #expect(
                    unrelated.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        == ["exec", "example", "run"])

                try await fixture.withContainer(
                    image: "example", runArgs: ["--no-dns"], dnsOverride: false
                ) { _ in }
                let invocations = try String(contentsOf: argumentLog, encoding: .utf8)
                    .components(separatedBy: .newlines)
                let containerRun = try #require(
                    invocations.first { $0.hasPrefix("run ") && $0.contains(" --no-dns ") })
                #expect(containerRun.contains(" --no-dns "))
                #expect(!containerRun.contains("10.0.0.1"))
            }
        }
    }

    @Test
    func assertionsReportCommandFailuresWithoutTestingRuntime() async throws {
        try await withFakeContainerCLI {
            try await ContainerFixture.with { fixture in
                try fixture.assertContainerHasFile("fixture", at: "present")
                try fixture.assertContainerMissingFile("fixture", at: "missing")
                try fixture.assertImageBuilt("expected")

                #expect {
                    try fixture.assertContainerHasFile("fixture", at: "missing")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "missing should exist in container"
                }

                #expect {
                    try fixture.assertContainerMissingFile("fixture", at: "present")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "present should NOT exist in container"
                }

                #expect {
                    try fixture.assertImageBuilt("mismatched")
                } throws: { error in
                    guard case .executionFailed(let message) = error as? CommandError else {
                        return false
                    }
                    return message == "expected image mismatched to be present"
                }
            }
        }
    }

    private func withFakeContainerCLI<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-test-support-\(UUID().uuidString)", isDirectory: true)
        let executable = directory.appendingPathComponent("container", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
            #!/bin/sh
            if [ -n "$CLITEST_ARGUMENT_LOG" ]; then
              (
                printf '%s' "$1"
                shift
                for argument in "$@"; do printf ' %s' "$argument"; done
                printf '\\n'
              ) >> "$CLITEST_ARGUMENT_LOG"
            fi
            if [ "$1" = "inspect" ]; then
              printf '%s\\n' '"running"'
              exit 0
            fi
            if [ "$CLITEST_ECHO_ARGUMENTS" = "true" ]; then
              printf '%s\\n' "$@"
              exit 0
            fi
            if [ "$1" = "exec" ]; then
              case "$5" in
                present) exit 0 ;;
                *) exit 1 ;;
              esac
            fi
            if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
              case "$3" in
                expected) printf '%s\\n' '[{"configuration":{"name":"expected"},"variants":[]}]' ;;
                mismatched) printf '%s\\n' '[{"configuration":{"name":"other"},"variants":[]}]' ;;
                *) exit 1 ;;
              esac
              exit 0
            fi
            exit 1
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        guard chmod(executable.path, 0o755) == 0 else {
            throw CommandError.executionFailed("could not mark fake container executable")
        }

        let originalPath = ProcessInfo.processInfo.environment["CONTAINER_CLI_PATH"]
        setenv("CONTAINER_CLI_PATH", executable.path, 1)
        defer {
            if let originalPath {
                setenv("CONTAINER_CLI_PATH", originalPath, 1)
            } else {
                unsetenv("CONTAINER_CLI_PATH")
            }
        }
        return try await body()
    }

    private func restoreEnvironment(_ name: String, to value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}
