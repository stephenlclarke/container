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
import Testing

@testable import ContainerK8s

@Suite("CoreDNS configuration")
struct CoreDNSConfigurationTests {
    private let corefile = """
        .:53 {
            errors
            health {
               lameduck 5s
            }
            forward . /etc/resolv.conf
            cache 30
        }
        """

    @Test func bindsRootServerToAdvertisedNodeAddress() throws {
        let configured = try K8sHelper.coreDNSCorefile(corefile, bindAddress: "192.168.66.4")

        #expect(configured.contains(".:53 {\n    bind 192.168.66.4\n"))
        #expect(configured.contains("forward . /etc/resolv.conf"))
    }

    @Test func applyingSameAddressIsIdempotent() throws {
        let configured = try K8sHelper.coreDNSCorefile(corefile, bindAddress: "192.168.66.4")

        #expect(try K8sHelper.coreDNSCorefile(configured, bindAddress: "192.168.66.4") == configured)
    }

    @Test func rejectsAddressThatCouldInjectCorefileContent() {
        #expect(throws: ContainerizationError.self) {
            try K8sHelper.coreDNSCorefile(corefile, bindAddress: "192.168.66.4\n    log")
        }
    }

    @Test func rejectsUnexpectedCorefileShape() {
        #expect(throws: ContainerizationError.self) {
            try K8sHelper.coreDNSCorefile("example.org:53 {\n}\n", bindAddress: "192.168.66.4")
        }
    }
}
