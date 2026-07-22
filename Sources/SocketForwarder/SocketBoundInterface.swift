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
import NIO

/// Restricts a wildcard listener to a single host network interface.
public enum SocketBoundInterface: Equatable, Sendable {
    case ipv4(CInt)
    case ipv6(CInt)
}

extension ServerBootstrap {
    func binding(to interface: SocketBoundInterface?) -> ServerBootstrap {
        guard let interface else {
            return self
        }

        switch interface {
        case .ipv4(let index):
            return serverChannelOption(
                ChannelOptions.socket(.init(IPPROTO_IP), .init(IP_BOUND_IF)),
                value: index
            )
        case .ipv6(let index):
            return serverChannelOption(
                ChannelOptions.socket(.init(IPPROTO_IPV6), .init(IPV6_BOUND_IF)),
                value: index
            )
        }
    }
}

extension DatagramBootstrap {
    func binding(to interface: SocketBoundInterface?) -> DatagramBootstrap {
        guard let interface else {
            return self
        }

        switch interface {
        case .ipv4(let index):
            return channelOption(
                ChannelOptions.socket(.init(IPPROTO_IP), .init(IP_BOUND_IF)),
                value: index
            )
        case .ipv6(let index):
            return channelOption(
                ChannelOptions.socket(.init(IPPROTO_IPV6), .init(IPV6_BOUND_IF)),
                value: index
            )
        }
    }
}
