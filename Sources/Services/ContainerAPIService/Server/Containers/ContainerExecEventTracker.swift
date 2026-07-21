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

/// Tracks user-requested exec processes and renders their Docker-compatible events.
struct ContainerExecEventTracker {
    private var configurations: [String: [String: ProcessConfiguration]] = [:]

    /// Records a created exec process and returns Docker's `exec_create` event.
    mutating func create(
        snapshot: ContainerSnapshot,
        processID: String,
        configuration: ProcessConfiguration
    ) -> ContainerEvent {
        configurations[snapshot.id, default: [:]][processID] = configuration
        return event(
            action: "exec_create: \(command(configuration))",
            snapshot: snapshot,
            processID: processID
        )
    }

    /// Returns Docker's `exec_start` event for a previously created exec process.
    func start(snapshot: ContainerSnapshot, processID: String) -> ContainerEvent? {
        guard let configuration = configurations[snapshot.id]?[processID] else {
            return nil
        }
        return event(
            action: "exec_start: \(command(configuration))",
            snapshot: snapshot,
            processID: processID
        )
    }

    /// Removes one tracked process and returns its single terminal `exec_die` event.
    mutating func die(snapshot: ContainerSnapshot, processID: String, exitCode: Int32) -> ContainerEvent? {
        guard configurations[snapshot.id]?.removeValue(forKey: processID) != nil else {
            return nil
        }
        return event(
            action: "exec_die",
            snapshot: snapshot,
            processID: processID,
            additionalAttributes: ["exitCode": "\(exitCode)"]
        )
    }

    /// Returns the configuration that must be passed to the runtime to start an exec process.
    func configuration(containerID: String, processID: String) -> ProcessConfiguration? {
        configurations[containerID]?[processID]
    }

    /// Drops transient process state after its container has been removed.
    mutating func removeContainer(id: String) {
        configurations.removeValue(forKey: id)
    }

    /// Keeps Docker's human-readable exec action suffix stable without interpreting command arguments.
    private func command(_ configuration: ProcessConfiguration) -> String {
        ([configuration.executable] + configuration.arguments).joined(separator: " ")
    }

    /// Builds Docker-shaped exec metadata without generic lifecycle-only attributes.
    private func event(
        action: String,
        snapshot: ContainerSnapshot,
        processID: String,
        additionalAttributes: [String: String] = [:]
    ) -> ContainerEvent {
        var attributes = snapshot.configuration.labels
        attributes["image"] = snapshot.configuration.image.reference
        attributes["execID"] = processID
        attributes.merge(additionalAttributes) { _, additional in additional }
        return ContainerEvent(
            type: "container",
            id: snapshot.id,
            action: action,
            attributes: attributes
        )
    }
}
