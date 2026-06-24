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

/// Configuration for periodically probing a running container.
///
/// The process is intentionally stored as a normal ``ProcessConfiguration`` so
/// callers can choose exec-form or shell-form behavior before handing the
/// container definition to the API server.
public struct ContainerHealthCheck: Sendable, Codable {
    public static let defaultIntervalInNanoseconds: UInt64 = 30_000_000_000
    public static let defaultTimeoutInNanoseconds: UInt64 = 30_000_000_000
    public static let defaultStartPeriodInNanoseconds: UInt64 = 0
    public static let defaultRetries: UInt32 = 3

    /// Process to run inside the container for each health probe.
    public var process: ProcessConfiguration
    /// Delay between health probes.
    public var intervalInNanoseconds: UInt64
    /// Maximum time a probe is allowed to run before it is treated as failed.
    public var timeoutInNanoseconds: UInt64
    /// Grace period after container start during which failures do not count.
    public var startPeriodInNanoseconds: UInt64
    /// Optional delay between probes during the start period.
    public var startIntervalInNanoseconds: UInt64?
    /// Number of consecutive counted failures before the container is unhealthy.
    public var retries: UInt32

    public init(
        process: ProcessConfiguration,
        intervalInNanoseconds: UInt64 = Self.defaultIntervalInNanoseconds,
        timeoutInNanoseconds: UInt64 = Self.defaultTimeoutInNanoseconds,
        startPeriodInNanoseconds: UInt64 = Self.defaultStartPeriodInNanoseconds,
        startIntervalInNanoseconds: UInt64? = nil,
        retries: UInt32 = Self.defaultRetries
    ) {
        self.process = process
        self.intervalInNanoseconds = intervalInNanoseconds
        self.timeoutInNanoseconds = timeoutInNanoseconds
        self.startPeriodInNanoseconds = startPeriodInNanoseconds
        self.startIntervalInNanoseconds = startIntervalInNanoseconds
        self.retries = retries
    }
}
