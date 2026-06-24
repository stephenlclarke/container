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

/// The observed health status of a container, as derived from a periodic
/// healthcheck probe.
public enum HealthStatus: String, CaseIterable, Sendable, Codable {
    /// No healthcheck is configured or no result is available.
    case none
    /// The healthcheck is running but has not produced a successful probe.
    case starting
    /// The most recent probe reported the container as healthy.
    case healthy
    /// The most recent probe reported the container as unhealthy.
    case unhealthy
}
