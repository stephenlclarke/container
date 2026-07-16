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

import ContainerAPIClient
import ContainerXPC
import ContainerizationError
import Foundation
import Logging

public struct ConfigsHarness: Sendable {
    let log: Logging.Logger
    let service: ConfigsService

    public init(service: ConfigsService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        let configs = try await service.list()
        let reply = message.reply()
        reply.set(key: .configs, value: try JSONEncoder().encode(configs))
        return reply
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .configName) else {
            throw ContainerizationError(.invalidArgument, message: "config name cannot be empty")
        }
        guard let contents = message.dataNoCopy(key: .configData) else {
            throw ContainerizationError(.invalidArgument, message: "config contents are required")
        }

        let labels: [String: String]
        if let labelsData = message.dataNoCopy(key: .configLabels) {
            labels = try JSONDecoder().decode([String: String].self, from: labelsData)
        } else {
            labels = [:]
        }

        let config = try await service.create(name: name, contents: contents, labels: labels)
        let reply = message.reply()
        reply.set(key: .config, value: try JSONEncoder().encode(config))
        return reply
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .configName) else {
            throw ContainerizationError(.invalidArgument, message: "config name cannot be empty")
        }
        try await service.delete(name: name)
        return message.reply()
    }

    @Sendable
    public func inspect(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .configName) else {
            throw ContainerizationError(.invalidArgument, message: "config name cannot be empty")
        }
        let config = try await service.inspect(name)
        let reply = message.reply()
        reply.set(key: .config, value: try JSONEncoder().encode(config))
        return reply
    }

    @Sendable
    public func read(_ message: XPCMessage) async throws -> XPCMessage {
        guard let name = message.string(key: .configName) else {
            throw ContainerizationError(.invalidArgument, message: "config name cannot be empty")
        }
        let reply = message.reply()
        reply.set(key: .configData, value: try await service.read(name: name))
        return reply
    }
}
