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
import Testing

@testable import ContainerRuntimeLinuxServer

struct HostPortBindingTests {
    @Test
    func highPortKeepsRequestedAddress() throws {
        let hostAddress = try IPAddress("127.0.0.1")

        let binding = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 8080) { _ in
            Issue.record("high ports must not resolve a bound interface")
            return nil
        }

        #expect(binding.proxyAddress.ipAddress == "127.0.0.1")
        #expect(binding.proxyAddress.port == 8080)
        #expect(binding.boundInterface == nil)
    }

    @Test
    func unspecifiedLowPortKeepsWildcardAddress() throws {
        let hostAddress = try IPAddress("0.0.0.0")

        let binding = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 80) { _ in
            Issue.record("wildcard addresses must not resolve a bound interface")
            return nil
        }

        #expect(binding.proxyAddress.ipAddress == "0.0.0.0")
        #expect(binding.proxyAddress.port == 80)
        #expect(binding.boundInterface == nil)
    }

    @Test
    func nonLoopbackLowPortKeepsRequestedAddress() throws {
        let hostAddress = try IPAddress("192.0.2.1")

        let binding = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 80) { _ in
            Issue.record("non-loopback addresses must not use the loopback workaround")
            return nil
        }

        #expect(binding.proxyAddress.ipAddress == "192.0.2.1")
        #expect(binding.proxyAddress.port == 80)
        #expect(binding.boundInterface == nil)
    }

    @Test
    func explicitIPv4LowPortUsesInterfaceBoundWildcard() throws {
        let hostAddress = try IPAddress("127.0.0.1")

        let binding = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 80) { resolvedAddress in
            #expect(resolvedAddress == hostAddress)
            return 7
        }

        #expect(binding.proxyAddress.ipAddress == "0.0.0.0")
        #expect(binding.proxyAddress.port == 80)
        #expect(binding.boundInterface == .ipv4(7))
    }

    @Test
    func explicitIPv6LowPortUsesInterfaceBoundWildcard() throws {
        let hostAddress = try IPAddress("::1")

        let binding = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 80) { resolvedAddress in
            #expect(resolvedAddress == hostAddress)
            return 9
        }

        #expect(binding.proxyAddress.ipAddress == "::")
        #expect(binding.proxyAddress.port == 80)
        #expect(binding.boundInterface == .ipv6(9))
    }

    @Test
    func explicitLowPortRejectsUnassignedAddress() throws {
        let hostAddress = try IPAddress("127.0.0.2")

        #expect(throws: ContainerizationError.self) {
            _ = try HostPortBinding.resolve(hostAddress: hostAddress, hostPort: 80) { _ in nil }
        }
    }

    @Test
    func loopbackLowPortFindsHostInterface() throws {
        let binding = try HostPortBinding.resolve(hostAddress: IPAddress("127.0.0.1"), hostPort: 80)

        #expect(binding.proxyAddress.ipAddress == "0.0.0.0")
        #expect(binding.boundInterface != nil)
    }
}
