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
import Foundation
import NIOCore

enum DockerSocketAddressError: Error {
    case invalidUTF8Host
    case invalidUnixPath
}

enum DockerSocketAddress {
    static func host(_ bytes: Data) throws -> String {
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw DockerSocketAddressError.invalidUTF8Host
        }
        return value
    }

    static func unix(path: Data) throws -> SocketAddress {
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard
            !path.isEmpty,
            !path.contains(0),
            path.count < pathCapacity
        else {
            throw DockerSocketAddressError.invalidUnixPath
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        var terminatedPath = path
        terminatedPath.append(0)
        terminatedPath.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyMemory(from: source)
            }
        }
        return SocketAddress(address)
    }
}
