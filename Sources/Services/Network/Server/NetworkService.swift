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
import ContainerizationExtras

/// A network service
public protocol NetworkService: Sendable {
    /// Gets the properties of the realized network.
    func status() async throws -> NetworkStatus

    /// Register a hostname and allocate associated addresses.
    ///
    /// A retained allocation survives a runtime XPC session closing and must
    /// later be released by the resource authority.
    func allocate(
        hostname: String,
        aliases: [String],
        macAddress: MACAddress?,
        requestedIPv4Address: IPv4Address?,
        requestedIPv6Address: IPv6Address?,
        retainOnDisconnect: Bool,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?)

    /// Release a retained attachment by its primary hostname.
    func release(hostname: String) async throws

    /// Return the attachment for a hostname if it is registered with the network.
    func lookup(hostname: String) async throws -> Attachment?

    /// Return every attachment registered for a hostname or shared alias.
    func lookupAll(hostname: String) async throws -> [Attachment]
}

extension NetworkService {
    public func lookupAll(hostname: String) async throws -> [Attachment] {
        guard let attachment = try await lookup(hostname: hostname) else {
            return []
        }
        return [attachment]
    }
}
