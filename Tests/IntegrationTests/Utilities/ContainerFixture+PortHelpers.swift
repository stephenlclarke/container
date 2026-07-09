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

import Darwin

extension ContainerFixture {
    func availableTCPPort() throws -> UInt16 {
        let fd = try Self.bindTCPPort(0, address: .ipv4Any)
        defer { Darwin.close(fd) }
        return try Self.boundPort(fd, address: .ipv4Any)
    }

    func availableTCPPortV6() throws -> UInt16 {
        let fd = try Self.bindTCPPort(0, address: .ipv6Loopback)
        defer { Darwin.close(fd) }
        return try Self.boundPort(fd, address: .ipv6Loopback)
    }

    func availableTCPPortRange(count: UInt16) throws -> UInt16 {
        guard count > 0 else {
            throw CommandError.executionFailed("port range count must be greater than zero")
        }

        let lowerBound = 50_000
        let upperBound = 60_000 - Int(count)
        guard lowerBound <= upperBound else {
            throw CommandError.executionFailed("port range count \(count) is too large")
        }

        for _ in 0..<100 {
            let start = UInt16(Int.random(in: lowerBound...upperBound))
            var fds: [Int32] = []
            do {
                for offset in 0..<Int(count) {
                    fds.append(try Self.bindTCPPort(start + UInt16(offset), address: .ipv4Any))
                }
                for fd in fds { Darwin.close(fd) }
                return start
            } catch {
                for fd in fds { Darwin.close(fd) }
            }
        }

        throw CommandError.executionFailed("failed to find \(count) consecutive available TCP ports")
    }

    private enum BindAddress {
        case ipv4Any
        case ipv6Loopback
    }

    private static func bindTCPPort(_ port: UInt16, address: BindAddress) throws -> Int32 {
        switch address {
        case .ipv4Any:
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw CommandError.executionFailed("socket(AF_INET) failed with errno \(errno)")
            }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                let savedErrno = errno
                Darwin.close(fd)
                throw CommandError.executionFailed("bind(AF_INET, port: \(port)) failed with errno \(savedErrno)")
            }
            return fd

        case .ipv6Loopback:
            let fd = socket(AF_INET6, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw CommandError.executionFailed("socket(AF_INET6) failed with errno \(errno)")
            }

            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, "::1", &addr.sin6_addr) == 1 else {
                Darwin.close(fd)
                throw CommandError.executionFailed("inet_pton(AF_INET6, ::1) failed with errno \(errno)")
            }

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else {
                let savedErrno = errno
                Darwin.close(fd)
                throw CommandError.executionFailed("bind(AF_INET6, port: \(port)) failed with errno \(savedErrno)")
            }
            return fd
        }
    }

    private static func boundPort(_ fd: Int32, address: BindAddress) throws -> UInt16 {
        switch address {
        case .ipv4Any:
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            guard result == 0 else {
                throw CommandError.executionFailed("getsockname(AF_INET) failed with errno \(errno)")
            }
            return UInt16(bigEndian: addr.sin_port)

        case .ipv6Loopback:
            var addr = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            guard result == 0 else {
                throw CommandError.executionFailed("getsockname(AF_INET6) failed with errno \(errno)")
            }
            return UInt16(bigEndian: addr.sin6_port)
        }
    }
}
