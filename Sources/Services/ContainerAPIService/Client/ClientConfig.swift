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
import ContainerXPC
import Foundation

/// Client API for persistent, non-secret configuration resources.
public struct ClientConfig {
    static let serviceIdentifier = "com.apple.container.apiserver"

    public static func create(
        name: String,
        contents: Data,
        labels: [String: String] = [:]
    ) async throws -> ConfigConfiguration {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .configCreate)
        message.set(key: .configName, value: name)
        message.set(key: .configData, value: contents)
        message.set(key: .configLabels, value: try JSONEncoder().encode(labels))

        let reply = try await client.send(message)
        guard let responseData = reply.dataNoCopy(key: .config) else {
            throw ConfigError.storageError("invalid response from server")
        }
        return try JSONDecoder().decode(ConfigConfiguration.self, from: responseData)
    }

    public static func delete(name: String) async throws {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .configDelete)
        message.set(key: .configName, value: name)
        _ = try await client.send(message)
    }

    public static func list() async throws -> [ConfigConfiguration] {
        let client = XPCClient(service: serviceIdentifier)
        let reply = try await client.send(XPCMessage(route: .configList))
        guard let responseData = reply.dataNoCopy(key: .configs) else {
            return []
        }
        return try JSONDecoder().decode([ConfigConfiguration].self, from: responseData)
    }

    public static func inspect(_ name: String) async throws -> ConfigConfiguration {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .configInspect)
        message.set(key: .configName, value: name)
        let reply = try await client.send(message)
        guard let responseData = reply.dataNoCopy(key: .config) else {
            throw ConfigError.configNotFound(name)
        }
        return try JSONDecoder().decode(ConfigConfiguration.self, from: responseData)
    }

    public static func read(name: String) async throws -> Data {
        let client = XPCClient(service: serviceIdentifier)
        let message = XPCMessage(route: .configRead)
        message.set(key: .configName, value: name)
        let reply = try await client.send(message)
        guard let contents = reply.dataNoCopy(key: .configData) else {
            throw ConfigError.storageError("invalid response from server")
        }
        return contents
    }
}
