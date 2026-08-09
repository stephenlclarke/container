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
    private let dynamicAllocator: (any AddressAllocator<UInt32>)?
    private let dynamicRange: ClosedRange<UInt32>?
    private var hostnames: [String: Set<UInt32>] = [:]
    private var primaryHostnames: [String: UInt32] = [:]
    private var namesByIndex: [UInt32: Set<String>] = [:]

    init(lower: UInt32, size: Int) throws {
        try self.init(lower: lower, size: size, dynamicLower: lower, dynamicSize: size)
    }

    /// Creates an allocator with a dynamic allocation subrange. Explicit address
    /// requests may use the full range, while dynamic allocation stays inside
    /// the configured subrange.
    init(lower: UInt32, size: Int, dynamicLower: UInt32, dynamicSize: Int) throws {
        guard size > 0, dynamicSize > 0 else {
            throw ContainerizationError(.invalidArgument, message: "address allocator ranges must not be empty")
        }
        guard let sizeValue = UInt32(exactly: size), let dynamicSizeValue = UInt32(exactly: dynamicSize) else {
            throw ContainerizationError(.invalidArgument, message: "address allocator range is too large")
        }
        let upper = try Self.upper(lower: lower, size: sizeValue)
        let dynamicUpper = try Self.upper(lower: dynamicLower, size: dynamicSizeValue)
        guard dynamicLower >= lower, dynamicUpper <= upper else {
            throw ContainerizationError(.invalidArgument, message: "dynamic address allocator range must be contained in the address range")
        }

        allocator = try UInt32.rotatingAllocator(
            lower: lower,
            size: sizeValue
        )
        if dynamicLower == lower, dynamicSize == size {
            dynamicAllocator = nil
            dynamicRange = nil
        } else {
            dynamicAllocator = try UInt32.rotatingAllocator(lower: dynamicLower, size: dynamicSizeValue)
            dynamicRange = dynamicLower...dynamicUpper
        }
    }

    /// Prevent a network-owned address from being allocated to an attachment.
    func reserve(index: UInt32) throws {
        try allocator.reserve(index)
        try reserveDynamic(index)
    }

    /// Allocate a network address for a host and its aliases.
    func allocate(hostname: String, aliases: [String] = [], requestedIndex: UInt32? = nil) async throws -> UInt32 {
        let hostname = try Self.normalized(hostname: hostname)
        let names = Set(try ([hostname] + aliases).map(Self.normalized(hostname:)))

        // Client is responsible for ensuring two containers don't use same hostname, so provide existing IP if hostname exists
        if let index = primaryHostnames[hostname] {
            if let requestedIndex, requestedIndex != index {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "requested IPv4 address does not match existing allocation for hostname '\(hostname)'"
                )
            }
            try reserveAliases(aliases, for: index)
            return index
        }
        let index: UInt32
        if let requestedIndex {
            try allocator.reserve(requestedIndex)
            try reserveDynamic(requestedIndex)
            index = requestedIndex
        } else if let dynamicAllocator {
            index = try dynamicAllocator.allocate()
            try allocator.reserve(index)
        } else {
            index = try allocator.allocate()
        }
        for name in names {
            hostnames[name, default: []].insert(index)
        }
        primaryHostnames[hostname] = index
        namesByIndex[index] = names

        return index
    }

    /// Free an allocated network address by hostname.
    @discardableResult
    func deallocate(hostname: String) async throws -> UInt32? {
        let hostname = try Self.normalized(hostname: hostname)
        guard let index = primaryHostnames[hostname] else {
            return nil
        }

        let names = namesByIndex.removeValue(forKey: index) ?? [hostname]
        for name in names {
            hostnames[name]?.remove(index)
            if hostnames[name]?.isEmpty == true {
                hostnames.removeValue(forKey: name)
            }
        }
        primaryHostnames.removeValue(forKey: hostname)
        try allocator.release(index)
        try releaseDynamic(index)
        return index
    }

    /// Retrieve the allocator index for a hostname.
    func lookup(hostname: String) async throws -> UInt32? {
        try await lookupAll(hostname: hostname).first
    }

    /// Retrieve the allocator index only when the name is a primary hostname.
    func lookupPrimary(hostname: String) async throws -> UInt32? {
        let hostname = try Self.normalized(hostname: hostname)
        return primaryHostnames[hostname]
    }

    /// Retrieve all allocator indexes registered for a hostname or shared alias.
    func lookupAll(hostname: String) async throws -> [UInt32] {
        let hostname = try Self.normalized(hostname: hostname)
        return hostnames[hostname, default: []].sorted()
    }

    private func reserveAliases(_ aliases: [String], for index: UInt32) throws {
        var names = namesByIndex[index] ?? []
        for alias in Set(try aliases.map(Self.normalized(hostname:))).sorted() {
            hostnames[alias, default: []].insert(index)
            names.insert(alias)
        }
        namesByIndex[index] = names
    }

    private static func normalized(hostname: String) throws -> String {
        let normalized = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        guard !normalized.isEmpty,
            !normalized.hasPrefix("."),
            !normalized.hasSuffix("."),
            !normalized.contains("..")
        else {
            throw ContainerizationError(.invalidArgument, message: "invalid hostname '\(hostname)'")
        }
        return normalized.lowercased()
    }

    private static func upper(lower: UInt32, size: UInt32) throws -> UInt32 {
        guard size > 0, size - 1 <= UInt32.max - lower else {
            throw ContainerizationError(.invalidArgument, message: "address allocator range overflows IPv4 address space")
        }
        return lower + size - 1
    }

    private func reserveDynamic(_ index: UInt32) throws {
        guard let dynamicAllocator, let dynamicRange, dynamicRange.contains(index) else {
            return
        }
        try dynamicAllocator.reserve(index)
    }

    private func releaseDynamic(_ index: UInt32) throws {
        guard let dynamicAllocator, let dynamicRange, dynamicRange.contains(index) else {
            return
        }
        try dynamicAllocator.release(index)
    }
}
