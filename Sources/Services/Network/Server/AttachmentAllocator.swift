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

import ContainerizationError
import ContainerizationExtras

actor AttachmentAllocator {
    private let allocator: any AddressAllocator<UInt32>
    private var hostnames: [String: UInt32] = [:]
    private var primaryHostnames: [String: UInt32] = [:]
    private var namesByIndex: [UInt32: Set<String>] = [:]

    init(lower: UInt32, size: Int) throws {
        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: UInt32(size)
        )
    }

    /// Allocate a network address for a host and its aliases.
    func allocate(hostname: String, aliases: [String] = []) async throws -> UInt32 {
        let names = Set([hostname] + aliases)

        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let index = primaryHostnames[hostname] {
            try reserveAliases(aliases, for: index)
            return index
        }
        let conflictingNames = names.filter { hostnames[$0] != nil }.sorted()
        guard conflictingNames.isEmpty else {
            throw ContainerizationError(.exists, message: "hostname(s) already exist: \(conflictingNames)")
        }

        let index = try allocator.allocate()
        for name in names {
            hostnames[name] = index
        }
        primaryHostnames[hostname] = index
        namesByIndex[index] = names

        return index
    }

    /// Free an allocated network address by hostname.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        guard let index = hostnames[hostname] else {
            return nil
        }

        let names = namesByIndex.removeValue(forKey: index) ?? [hostname]
        for name in names {
            hostnames.removeValue(forKey: name)
            primaryHostnames.removeValue(forKey: name)
        }
        try allocator.release(index)
        return index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        hostnames[hostname]
    }

    private func reserveAliases(_ aliases: [String], for index: UInt32) throws {
        var names = namesByIndex[index] ?? []
        for alias in Set(aliases).sorted() {
            if let existing = hostnames[alias], existing != index {
                throw ContainerizationError(.exists, message: "hostname(s) already exist: [\"\(alias)\"]")
            }
            hostnames[alias] = index
            names.insert(alias)
        }
        namesByIndex[index] = names
    }
}
