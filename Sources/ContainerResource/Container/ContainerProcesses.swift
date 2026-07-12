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

/// Process-table row currently associated with a container.
public struct ContainerProcessInfo: Sendable, Codable, Equatable {
    /// Process owner column.
    public var uid: String
    /// Process identifier.
    public var pid: Int32
    /// Parent process identifier.
    public var ppid: Int32
    /// Integer CPU utilization column.
    public var cpu: Int32
    /// Process start-time column.
    public var startTime: String
    /// Process terminal column.
    public var tty: String
    /// Process CPU-time column.
    public var time: String
    /// Process command column.
    public var command: String

    public init(
        uid: String,
        pid: Int32,
        ppid: Int32,
        cpu: Int32,
        startTime: String,
        tty: String,
        time: String,
        command: String
    ) {
        self.uid = uid
        self.pid = pid
        self.ppid = ppid
        self.cpu = cpu
        self.startTime = startTime
        self.tty = tty
        self.time = time
        self.command = command
    }
}

/// Process information currently associated with a container.
public struct ContainerProcesses: Sendable, Equatable {
    /// Container ID.
    public var id: String
    /// Process identifiers reported by the runtime cgroup.
    public var processIdentifiers: [Int32]
    /// Docker-compatible process-table rows reported by the runtime.
    public var processes: [ContainerProcessInfo]

    public init(id: String, processIdentifiers: [Int32], processes: [ContainerProcessInfo] = []) {
        self.id = id
        self.processIdentifiers = processIdentifiers
        self.processes = processes
    }
}

extension ContainerProcesses: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case processIdentifiers
        case processes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        processIdentifiers = try container.decode([Int32].self, forKey: .processIdentifiers)
        processes = try container.decodeIfPresent([ContainerProcessInfo].self, forKey: .processes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(processIdentifiers, forKey: .processIdentifiers)
        try container.encode(processes, forKey: .processes)
    }
}
