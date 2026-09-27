//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ArgumentParser
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIO
import TerminalProgress

struct BuilderReadinessBackoff: Sendable {
    private static let initialDelay: Duration = .milliseconds(50)
    private static let maximumDelay: Duration = .seconds(1)

    private var delay = Self.initialDelay

    mutating func nextDelay() -> Duration {
        let current = delay
        delay = min(delay * 2, Self.maximumDelay)
        return current
    }
}

struct BuilderReadinessRecovery {
    static func shouldRestart(
        after readinessError: Error,
        builderStatusError: Error?
    ) -> Bool {
        if let containerError = readinessError as? ContainerizationError,
            containerError.code == .invalidState || containerError.code == .notFound
        {
            return true
        }

        if let containerError = builderStatusError as? ContainerizationError,
            containerError.code == .notFound
        {
            return true
        }

        return false
    }
}

public struct BuildOptions: ParsableArguments {
    public init() {}
    public enum ProgressType: String, ExpressibleByArgument {
        case auto
        case plain
        case tty
    }

    public enum SecretType: Decodable {
        case data(Data)
        case file(String)
    }

    public struct ParsedBuildContexts: Sendable {
        var sources: [String: String]
        var localPaths: [String: String]
    }

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp("Add the architecture type to the build", valueName: "value"),
        transform: { val in val.split(separator: ",").map { String($0) } }
    )
    public var arch: [[String]] = {
        [[Arch.hostArchitecture().rawValue]]
    }()

    @Option(name: .long, help: ArgumentHelp("Set build-time variables", valueName: "key=val"))
    public var buildArg: [String] = []

    @Option(name: .long, help: ArgumentHelp("Additional build context (format: name=path|url)", valueName: "name=source"))
    public var buildContext: [String] = []

    @Option(name: .long, help: ArgumentHelp("Set builder to use", valueName: "name"))
    public var builder: String?

    @Flag(name: .long, help: "Check build configuration without exporting an image")
    public var check: Bool = false

    @Option(name: .long, help: ArgumentHelp("Cache imports for the build", valueName: "value", visibility: .hidden))
    public var cacheIn: [String] = {
        []
    }()

    @Option(name: .long, help: ArgumentHelp("Cache exports for the build", valueName: "value", visibility: .hidden))
    public var cacheOut: [String] = {
        []
    }()

    @Option(name: .shortAndLong, help: "Number of CPUs to allocate to the builder container")
    public var cpus: Int64?

    @Option(name: .shortAndLong, help: ArgumentHelp("Path to Dockerfile", valueName: "path"))
    public var file: String?


    @Option(name: .shortAndLong, help: ArgumentHelp("Set a label", valueName: "key=val"))
    public var label: [String] = []

    @Option(name: .long, help: ArgumentHelp("Allow BuildKit entitlement", valueName: "value"))
    public var allow: [String] = []

    @Option(name: .long, help: ArgumentHelp("Add host mapping during build (format: host=ip)", valueName: "host=ip"))
    public var addHost: [String] = []

    @Option(
        name: .shortAndLong,
        help: "Amount of builder container memory (1MiByte granularity), with optional K, M, G, T, or P suffix"
    )
    public var memory: String?

    @Flag(name: .long, help: "Do not use cache")
    public var noCache: Bool = false

    @Option(
        name: .customLong("no-cache-filter"),
        help: ArgumentHelp("Do not use cache for the specified build stage", valueName: "stage")
    )
    public var noCacheFilter: [String] = []

    @Option(name: .long, help: ArgumentHelp("Set Dockerfile RUN network mode (default|none|host|sandbox)", valueName: "mode"))
    public var network: String?

    @Option(name: .shortAndLong, help: ArgumentHelp("Output configuration for the build (format: type=<oci|tar|local>[,dest=])", valueName: "value"))
    public var output: [String] = {
        ["type=oci"]
    }()

    @Option(
        name: .long,
        help: ArgumentHelp("Add the OS type to the build", valueName: "value"),
        transform: { val in val.split(separator: ",").map { String($0) } }
    )
    public var os: [[String]] = {
        [["linux"]]
    }()

    @Option(
        name: .long,
        help: "Add the platform to the build (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]",
        transform: { val in val.split(separator: ",").map { String($0) } }
    )
    public var platform: [[String]] = [[]]

    @Option(name: .long, help: ArgumentHelp("Progress type (format: auto|plain|tty)", valueName: "type"))
    public var progress: ProgressType = .auto

    @Option(name: .long, help: ArgumentHelp("Add a provenance attestation. Use false to explicitly disable.", valueName: "value"))
    public var provenance: String?

    @Flag(name: .shortAndLong, help: "Suppress build output")
    public var quiet: Bool = false

    @Flag(name: .long, help: "Allow privileged Dockerfile RUN steps")
    public var privileged: Bool = false

    @Option(name: .long, help: ArgumentHelp("Set build-time secrets (format: id=<key>[,env=<ENV_VAR>|,src=<local/path>])", valueName: "id=key,..."))
    public var secret: [String] = []

    public var secrets: [String: SecretType] = [:]

    @Option(name: .long, help: ArgumentHelp("Set SSH authentication used during the build from SSH_AUTH_SOCK or id=/path/to/socket values", valueName: "value"))
    public var ssh: [String] = []

    @Option(name: .long, help: ArgumentHelp("Add an SBOM attestation. Use false to explicitly disable.", valueName: "value"))
    public var sbom: String?

    @Option(name: .long, help: ArgumentHelp("Set /dev/shm size in bytes for Dockerfile RUN steps", valueName: "bytes"))
    public var shmSize: String?

    @Option(name: [.short, .customLong("tag")], help: ArgumentHelp("Name for the built image", valueName: "name"))
    public var targetImageNames: [String] = {
        [UUID().uuidString.lowercased()]
    }()

    @Option(name: .long, help: ArgumentHelp("Set the target build stage", valueName: "stage"))
    public var target: String = ""

    @Option(name: .long, help: ArgumentHelp("Set Dockerfile RUN ulimit (format: name=soft[:hard])", valueName: "name=value"))
    public var ulimit: [String] = []

    @Option(name: .long, help: ArgumentHelp("Builder shim vsock port", valueName: "port"))
    public var vsockPort: UInt32 = 8088

    @OptionGroup
    public var logOptions: Flags.Logging

    @OptionGroup
    public var dns: Flags.DNS

    @Argument(help: "Build directory")
    public var contextDir: String = "."

    @Flag(name: .long, help: "Pull latest image")
    public var pull: Bool = false

    public var log: Logger {
        var logger = Logger(label: "container", factory: { _ in StderrLogHandler() })
        logger.logLevel = logOptions.debug ? .debug : .info
        return logger
    }
    public mutating func validate() throws {
        // NOTE: Here we check the Dockerfile exists, and set `dockerfile` to point the valid Dockerfile path or stdin
        guard FileManager.default.fileExists(atPath: contextDir) else {
            throw ValidationError("context dir does not exist \(contextDir)")
        }
        for name in targetImageNames {
            guard let _ = try? Reference.parse(name) else {
                throw ValidationError("invalid reference \(name)")
            }
        }
        noCacheFilter = try Self.normalizedNoCacheFilters(noCacheFilter)

        if let filepath = file, filepath != "-" {
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: filepath, relativeTo: .currentDirectory()).path) else {
                throw ValidationError("file does not exist \(filepath)")
            }
        }

        // Parse --secret args
        for secret in self.secret {
            let parts = secret.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].hasPrefix("id=") else {
                throw ValidationError("secret must start with id=<key> \(secret)")
            }
            let key = String(parts[0].dropFirst(3))
            guard !key.contains("=") else {
                throw ValidationError("secret id cannot contain '=' \(key)")
            }
            if parts.count == 1 || parts[1].hasPrefix("env=") {
                let env = parts.count == 1 ? key : String(parts[1].dropFirst(4))
                // Using getenv/strlen over processInfo.environment to support
                // non-UTF-8 env var data.
                guard let ptr = getenv(env) else {
                    throw ValidationError("secret env var doesn't exist \(env)")
                }
                self.secrets[key] = .data(Data(bytes: ptr, count: strlen(ptr)))
            } else if parts[1].hasPrefix("src=") {
                let path = String(parts[1].dropFirst(4))
                self.secrets[key] = .file(path)
            } else {
                throw ValidationError("secret bad value \(parts[1])")
            }
        }
    }

}
