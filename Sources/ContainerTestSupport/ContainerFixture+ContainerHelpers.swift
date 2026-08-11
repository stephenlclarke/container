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

import ContainerResource
import Foundation
import SystemPackage

// MARK: - Inspect types

extension ContainerFixture {
    /// Decoded output of `container inspect <name>`.
    public struct InspectOutput: Codable {
        public struct Status: Codable {
            public let state: String
            public let networks: [ContainerResource.Attachment]
        }
        public let configuration: ContainerConfiguration
        public let status: Status
        public var networks: [ContainerResource.Attachment] { status.networks }
    }
}

// MARK: - Container lifecycle helpers

extension ContainerFixture {

    /// `-e` flags forwarding proxy env vars into container commands.
    public var proxyEnvironmentArgs: [String] {
        let vars = Set(["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy"])
        return ProcessInfo.processInfo.environment
            .filter { vars.contains($0.key) }
            .flatMap { ["-e", "\($0.key)=\($0.value)"] }
    }

    /// Starts a detached container. Uses the first warmup image when `image` is nil.
    ///
    /// `containerEnv` injects environment variables into the container via `-e` flags.
    /// To set the CLI subprocess environment (e.g. for `--ssh`), use ``run(_:env:)`` directly.
    ///
    /// Pass `waitUntilRunning: true` to poll for `running` state before returning,
    /// eliminating a separate ``ContainerFixture/waitForContainerRunning(_:attempts:)`` call.
    public func doLongRun(
        name: String,
        image: String? = nil,
        args: [String] = [],
        containerArgs: [String] = ["sleep", "infinity"],
        autoRemove: Bool = true,
        containerEnv: [String: String] = [:],
        dnsOverride: Bool = true,
        waitUntilRunning: Bool = false
    ) async throws {
        let imageRef = image ?? WarmupImage.alpine320.rawValue
        var runArgs = ["run"]
        if autoRemove { runArgs.append("--rm") }
        runArgs += ["--name", name, "-d"]
        runArgs += proxyEnvironmentArgs
        runArgs += args
        for (k, v) in containerEnv { runArgs += ["-e", "\(k)=\(v)"] }
        runArgs.append(imageRef)
        runArgs += containerArgs
        try run(runArgs, dnsOverride: dnsOverride).check()
        if waitUntilRunning {
            try await waitForContainerRunning(name)
        }
    }

    /// Creates a stopped container (`container create`).
    public func doCreate(
        name: String,
        image: String? = nil,
        args: [String] = ["sleep", "infinity"],
        volumes: [String] = [],
        networks: [String] = [],
        ports: [String] = []
    ) throws {
        let imageRef = image ?? WarmupImage.alpine320.rawValue
        var createArgs = ["create", "--rm", "--name", name]
        createArgs += proxyEnvironmentArgs
        for v in volumes { createArgs += ["-v", v] }
        for n in networks { createArgs += ["--network", n] }
        for p in ports { createArgs += ["--publish", "\(p):\(p)"] }
        createArgs.append(imageRef)
        createArgs += args
        try run(createArgs).check()
    }

    /// Starts a stopped container.
    public func doStart(_ name: String) throws {
        try run(["start", name]).check()
    }

    /// Stops a container. Pass `signal: nil` to use the server's default.
    public func doStop(_ name: String, signal: String? = "SIGKILL") throws {
        var args = ["stop"]
        if let signal { args += ["-s", signal] }
        args.append(name)
        try run(args).check()
    }

    /// Deletes a container.
    public func doRemove(_ name: String, force: Bool = false) throws {
        var args = ["delete"]
        if force { args.append("--force") }
        args.append(name)
        try run(args).check()
    }

    /// Deletes a container.
    ///
    /// When `ignoreFailure` is `false` (default) any error is rethrown — use
    /// this when the container is expected to exist and removal must succeed.
    /// Set `ignoreFailure: true` in cleanup contexts where best-effort removal
    /// is acceptable (e.g. the container may have already been removed).
    public func doRemoveIfExists(_ name: String, force: Bool = false, ignoreFailure: Bool = false) throws {
        do {
            try doRemove(name, force: force)
        } catch {
            if !ignoreFailure { throw error }
        }
    }

    /// Runs a command inside a container, returns stdout. Throws on non-zero exit.
    @discardableResult
    public func doExec(
        _ name: String,
        cmd: [String],
        detach: Bool = false,
        user: String? = nil
    ) throws -> String {
        var args = ["exec"]
        args += proxyEnvironmentArgs
        if detach { args.append("-d") }
        if let user { args += ["-u", user] }
        args.append(name)
        args += cmd
        return try run(args).check().output
    }

    /// Exports a container filesystem to a tar archive at `path`.
    public func doExport(_ name: String, to path: FilePath) throws {
        try run(["export", name, "-o", path.string]).check()
    }
}

// MARK: - Inspect helpers

extension ContainerFixture {

    private static let routineLogInspectionKind = "container-log-configuration-inspection-v1"

    /// Removes the deliberately non-authoritative logging projection before
    /// legacy integration assertions decode the remaining configuration.
    ///
    /// The production `container inspect` contract must remain redaction-safe
    /// and non-decodable as persisted configuration. These fixtures do not
    /// assert logging state, so they retain all other inspect fields while
    /// discarding only the recognized diagnostic projection.
    package static func inspectDataForConfigurationAssertions(_ data: Data) throws -> Data {
        guard var outputs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CommandError.executionFailed("container inspect output is not an object array")
        }

        for index in outputs.indices {
            guard var configuration = outputs[index]["configuration"] as? [String: Any] else {
                throw CommandError.executionFailed("container inspect output is missing configuration")
            }
            guard let logging = configuration["logging"] as? [String: Any] else {
                continue
            }
            guard let diagnosticKind = logging["diagnosticKind"] else {
                continue
            }
            guard diagnosticKind as? String == Self.routineLogInspectionKind else {
                throw CommandError.executionFailed(
                    "container inspect output has an unknown logging diagnostic projection"
                )
            }

            configuration.removeValue(forKey: "logging")
            outputs[index]["configuration"] = configuration
        }

        return try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys])
    }

    /// Returns the parsed inspect output for a container.
    public func inspectContainer(_ name: String) throws -> InspectOutput {
        let result = try run(["inspect", name]).check()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Self.inspectDataForConfigurationAssertions(result.outputData)
        let outputs = try decoder.decode([InspectOutput].self, from: data)
        guard let first = outputs.first else {
            throw CommandError.executionFailed("container '\(name)' not found in inspect output")
        }
        return first
    }

    /// Returns the `status.state` string for a container (e.g. `"running"`, `"stopped"`).
    public func getContainerStatus(_ name: String) throws -> String {
        try inspectContainer(name).status.state
    }

    /// Returns the `configuration.id` for a container.
    public func getContainerId(_ name: String) throws -> String {
        try inspectContainer(name).configuration.id
    }
}
