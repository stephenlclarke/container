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
import ContainerizationError
import ContainerizationExtras
import Logging

public actor DefaultNetworkService: NetworkService {
    private let network: any Network
    private let log: Logger
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]
    private var ipv6Addresses: [UInt32: IPv6Address]
    private var ipv6AddressIndexes: [IPv6Address: UInt32]
    private var allocationsBySession: [XPCServerSession: [(hostname: String, index: UInt32)]]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        log: Logger
    ) async throws {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let subnet = status.ipv4Subnet
        let size = Int(subnet.upper.value - subnet.lower.value - 3)
        self.network = network
        self.log = log
        self.allocator = try AttachmentAllocator(lower: subnet.lower.value + 2, size: size)
        self.macAddresses = [:]
        self.ipv6Addresses = [:]
        self.ipv6AddressIndexes = [:]
        self.allocationsBySession = [:]
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        aliases: [String],
        macAddress: MACAddress?,
        requestedIPv4Address: IPv4Address?,
        requestedIPv6Address: IPv6Address?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let requestedIndex = try requestedIPv4Address.map {
            try allocatableIPv4Index($0, subnet: status.ipv4Subnet)
        }
        let existingIndex = try await allocator.lookup(hostname: hostname)
        let effectiveMACAddress: MACAddress
        if let existingIndex {
            guard let existingMACAddress = macAddresses[existingIndex] else {
                throw ContainerizationError(.invalidState, message: "missing MAC address for existing network attachment '\(hostname)'")
            }
            if let macAddress, macAddress != existingMACAddress {
                throw ContainerizationError(.invalidArgument, message: "requested MAC address does not match existing allocation for hostname '\(hostname)'")
            }
            effectiveMACAddress = existingMACAddress
        } else {
            effectiveMACAddress = macAddress ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        }
        let resolvedIPv6Address = try resolveIPv6Address(
            requestedIPv6Address,
            macAddress: effectiveMACAddress,
            subnet: status.ipv6Subnet
        )
        if let resolvedIPv6Address, let owner = ipv6AddressIndexes[resolvedIPv6Address], owner != existingIndex {
            throw ContainerizationError(.exists, message: "IPv6 address '\(resolvedIPv6Address)' is already allocated")
        }

        let index = try await allocator.allocate(
            hostname: hostname,
            aliases: aliases,
            requestedIndex: requestedIndex
        )
        if let existingIndex {
            guard index == existingIndex, ipv6Addresses[index] == resolvedIPv6Address else {
                throw ContainerizationError(.invalidArgument, message: "requested IPv6 address does not match existing allocation for hostname '\(hostname)'")
            }
        } else {
            macAddresses[index] = effectiveMACAddress
            if let resolvedIPv6Address {
                ipv6Addresses[index] = resolvedIPv6Address
                ipv6AddressIndexes[resolvedIPv6Address] = index
            }
        }
        let attachment = try attachment(
            status: status,
            hostname: hostname,
            aliases: aliases,
            index: index,
            macAddress: effectiveMACAddress,
            ipv6Address: resolvedIPv6Address
        )
        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "aliases": "\(aliases.joined(separator: ","))",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "ipv6Address": "\(attachment.ipv6Address?.description ?? "unavailable")",
                "macAddress": "\(attachment.macAddress?.description ?? "unspecified")",
            ])

        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }
        if allocationsBySession[session] == nil {
            allocationsBySession[session] = []
            await session.onDisconnect { [weak self] in
                await self?.releaseSession(session)
            }
        }
        allocationsBySession[session]!.append((hostname: hostname, index: index))

        return (attachment: attachment, additionalData: additionalData)
    }

    private func releaseSession(_ session: XPCServerSession) async {
        guard let allocations = allocationsBySession.removeValue(forKey: session) else {
            return
        }
        for allocation in allocations {
            _ = try? await allocator.deallocate(hostname: allocation.hostname)
            macAddresses.removeValue(forKey: allocation.index)
            if let ipv6Address = ipv6Addresses.removeValue(forKey: allocation.index) {
                ipv6AddressIndexes.removeValue(forKey: ipv6Address)
            }
        }
        log.info("released session", metadata: ["allocations": "\(allocations.count)"])
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // Invariant: hostname -> index if and only if index -> MAC address
        let index = try await allocator.lookup(hostname: hostname)
        guard let index else {
            return nil
        }
        guard let macAddress = macAddresses[index] else {
            return nil
        }

        let attachment = try attachment(
            status: status,
            hostname: hostname,
            aliases: [],
            index: index,
            macAddress: macAddress,
            ipv6Address: ipv6Addresses[index]
        )
        log.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(IPv4Address(index))",
            ])

        return attachment
    }

    private func allocatableIPv4Index(_ address: IPv4Address, subnet: CIDRv4) throws -> UInt32 {
        let lower = subnet.lower.value + 2
        let upper = subnet.upper.value - 2
        guard address.value >= lower, address.value <= upper else {
            throw ContainerizationError(
                .invalidArgument,
                message: "requested IPv4 address '\(address)' is not an allocatable host address in subnet '\(subnet)'"
            )
        }
        return address.value
    }

    private func resolveIPv6Address(
        _ requestedIPv6Address: IPv6Address?,
        macAddress: MACAddress,
        subnet: CIDRv6?
    ) throws -> IPv6Address? {
        if let requestedIPv6Address {
            guard !requestedIPv6Address.isUnspecified else {
                throw ContainerizationError(.invalidArgument, message: "requested IPv6 address must not be unspecified")
            }
            guard requestedIPv6Address.zone == nil else {
                throw ContainerizationError(.invalidArgument, message: "requested IPv6 address must not include a zone identifier")
            }
            guard let subnet else {
                throw ContainerizationError(.invalidArgument, message: "requested IPv6 address requires an IPv6 network subnet")
            }
            guard subnet.contains(requestedIPv6Address) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "requested IPv6 address '\(requestedIPv6Address)' is not in subnet '\(subnet)'"
                )
            }
            return requestedIPv6Address
        }
        return try subnet.map { try macAddress.ipv6Address(network: $0.lower) }
    }

    private func attachment(
        status: NetworkStatus,
        hostname: String,
        aliases: [String],
        index: UInt32,
        macAddress: MACAddress,
        ipv6Address: IPv6Address?
    ) throws -> Attachment {
        let ipv6CIDR: CIDRv6?
        if let ipv6Address {
            guard let subnet = status.ipv6Subnet else {
                throw ContainerizationError(.invalidState, message: "missing IPv6 subnet for allocated IPv6 address")
            }
            ipv6CIDR = try CIDRv6(ipv6Address, prefix: subnet.prefix)
        } else {
            ipv6CIDR = nil
        }
        return Attachment(
            network: network.id,
            hostname: hostname,
            aliases: aliases,
            ipv4Address: try CIDRv4(IPv4Address(index), prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6CIDR,
            macAddress: macAddress,
            variant: network.variant
        )
    }
}
