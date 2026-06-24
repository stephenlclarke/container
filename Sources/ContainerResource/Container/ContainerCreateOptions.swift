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

/// Restart behavior applied by the runtime when a container's init process exits.
public struct ContainerRestartPolicy: Codable, Equatable, Sendable {
    /// Supported restart policy modes.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Do not restart the container automatically.
        case no
        /// Restart only when the init process exits with a non-zero status.
        case onFailure = "on-failure"
        /// Restart whenever the init process exits unless the user stopped it.
        case always
        /// Restart unless the container has been stopped by the user.
        case unlessStopped = "unless-stopped"
    }

    /// The selected restart mode.
    public let mode: Mode
    /// Optional consecutive retry limit. Valid only for `on-failure`.
    public let maximumRetryCount: UInt32?
    /// Optional fixed delay between restart attempts, in nanoseconds.
    public let retryDelayInNanoseconds: UInt64?
    /// Optional successful-run window before retry state is reset, in nanoseconds.
    public let successfulRunDurationInNanoseconds: UInt64?

    private enum CodingKeys: String, CodingKey {
        case mode
        case maximumRetryCount
        case retryDelayInNanoseconds
        case successfulRunDurationInNanoseconds
    }

    public init(
        mode: Mode,
        maximumRetryCount: UInt32? = nil,
        retryDelayInNanoseconds: UInt64? = nil,
        successfulRunDurationInNanoseconds: UInt64? = nil
    ) {
        self.mode = mode
        // on-failure:0 follows Docker/Moby semantics: zero means no retry cap,
        // not "zero retries." Colima's Docker runtime delegates this to Docker
        // Engine, and Moby's restart manager treats MaximumRetryCount == 0 as
        // unlimited.
        switch mode {
        case .onFailure:
            self.maximumRetryCount = maximumRetryCount == 0 ? nil : maximumRetryCount
        case .no, .always, .unlessStopped:
            self.maximumRetryCount = nil
        }
        switch mode {
        case .no:
            self.retryDelayInNanoseconds = nil
            self.successfulRunDurationInNanoseconds = nil
        case .onFailure, .always, .unlessStopped:
            self.retryDelayInNanoseconds = retryDelayInNanoseconds
            self.successfulRunDurationInNanoseconds = successfulRunDurationInNanoseconds
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        let maximumRetryCount = try container.decodeIfPresent(UInt32.self, forKey: .maximumRetryCount)
        let retryDelayInNanoseconds = try container.decodeIfPresent(UInt64.self, forKey: .retryDelayInNanoseconds)
        let successfulRunDurationInNanoseconds = try container.decodeIfPresent(UInt64.self, forKey: .successfulRunDurationInNanoseconds)

        self.init(
            mode: mode,
            maximumRetryCount: maximumRetryCount,
            retryDelayInNanoseconds: retryDelayInNanoseconds,
            successfulRunDurationInNanoseconds: successfulRunDurationInNanoseconds
        )
    }

    public static let no = ContainerRestartPolicy(mode: .no)
}

public struct ContainerCreateOptions: Codable, Sendable {
    /// Remove the container and wipe out its data on container stop
    public let autoRemove: Bool
    /// Override the rootFs with this one other than the image-cloned version
    public let rootFsOverride: Filesystem?
    /// Restart behavior applied when the container's init process exits.
    public let restartPolicy: ContainerRestartPolicy

    public init(
        autoRemove: Bool,
        rootFsOverride: Filesystem? = nil,
        restartPolicy: ContainerRestartPolicy = .no
    ) {
        self.autoRemove = autoRemove
        self.rootFsOverride = rootFsOverride
        self.restartPolicy = restartPolicy
    }

    public static let `default` = ContainerCreateOptions(autoRemove: false)

    enum CodingKeys: String, CodingKey {
        case autoRemove
        case rootFsOverride
        case restartPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoRemove = try container.decode(Bool.self, forKey: .autoRemove)
        rootFsOverride = try container.decodeIfPresent(Filesystem.self, forKey: .rootFsOverride)
        restartPolicy = try container.decodeIfPresent(ContainerRestartPolicy.self, forKey: .restartPolicy) ?? .no
    }
}
