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
import Darwin
import NIO
import SocketForwarder

struct HostPortBinding: Sendable {
    let proxyAddress: SocketAddress
    let boundInterface: SocketBoundInterface?

    static func resolve(hostAddress: IPAddress, hostPort: UInt16) throws -> HostPortBinding {
        try resolve(hostAddress: hostAddress, hostPort: hostPort, interfaceIndex: HostInterface.index)
    }

    static func resolve(
        hostAddress: IPAddress,
        hostPort: UInt16,
        interfaceIndex: (IPAddress) -> UInt32?
    ) throws -> HostPortBinding {
        let requestedAddress = try SocketAddress(ipAddress: hostAddress.description, port: Int(hostPort))
        guard hostPort < 1024, hostAddress.isLoopback else {
            return HostPortBinding(proxyAddress: requestedAddress, boundInterface: nil)
        }

        guard let index = interfaceIndex(hostAddress) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "host address \(hostAddress) is not assigned to a host network interface"
            )
        }

        let wildcardAddress: SocketAddress
        let boundInterface: SocketBoundInterface
        switch hostAddress {
        case .v4:
            wildcardAddress = try SocketAddress(ipAddress: "0.0.0.0", port: Int(hostPort))
            boundInterface = .ipv4(CInt(bitPattern: index))
        case .v6:
            wildcardAddress = try SocketAddress(ipAddress: "::", port: Int(hostPort))
            boundInterface = .ipv6(CInt(bitPattern: index))
        }

        return HostPortBinding(proxyAddress: wildcardAddress, boundInterface: boundInterface)
    }
}

private enum HostInterface {
    static func index(for address: IPAddress) -> UInt32? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let start = addressList else {
            return nil
        }
        defer { freeifaddrs(start) }

        for interface in sequence(first: start, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = interface.pointee.ifa_addr else {
                continue
            }
            let name = String(cString: interface.pointee.ifa_name)
            let index = if_nametoindex(name)
            guard index != 0, matches(address, socketAddress: socketAddress, interfaceName: name, interfaceIndex: index) else {
                continue
            }
            return index
        }
        return nil
    }

    private static func matches(
        _ requestedAddress: IPAddress,
        socketAddress: UnsafePointer<sockaddr>,
        interfaceName: String,
        interfaceIndex: UInt32
    ) -> Bool {
        switch requestedAddress {
        case .v4(let requested):
            guard socketAddress.pointee.sa_family == AF_INET,
                socketAddress.pointee.sa_len >= MemoryLayout<sockaddr_in>.size
            else {
                return false
            }
            let actual = UnsafeRawPointer(socketAddress).load(as: sockaddr_in.self)
            return UInt32(bigEndian: actual.sin_addr.s_addr) == requested.value

        case .v6(let requested):
            guard socketAddress.pointee.sa_family == AF_INET6,
                socketAddress.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size
            else {
                return false
            }
            let actual = UnsafeRawPointer(socketAddress).load(as: sockaddr_in6.self)
            let bytes = withUnsafeBytes(of: actual.sin6_addr) { Array($0) }
            guard let actualAddress = try? IPv6Address(bytes), actualAddress.value == requested.value else {
                return false
            }
            guard let zone = requested.zone else {
                return true
            }
            return zone == interfaceName || zone == String(interfaceIndex)
        }
    }
}
