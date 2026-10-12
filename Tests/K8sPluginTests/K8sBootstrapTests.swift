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

import Testing
import Yams

@testable import ContainerK8s

@Suite("K8s bootstrap configuration")
struct K8sBootstrapTests {
    private let vmIP = "192.168.64.2"

    private func assertControlPlaneEndpoint(arguments: [String], workers: UInt, expected: String) throws {
        let command = try K8sCreate.parse(arguments)
        #expect(command.workers == workers)

        let endpoint = K8sCreate.controlPlaneEndpoint(vmIP: vmIP, workers: command.workers)
        #expect(endpoint == expected)

        let yaml = try K8sHelper.initConfigYAML(
            nodeImage: K8sHelper.nodeImage,
            advertiseAddress: vmIP,
            certSANs: ["127.0.0.1"],
            controlPlaneEndpoint: endpoint)
        #expect(yaml.contains("controlPlaneEndpoint: \(expected)"))
        #expect(yaml.contains("advertiseAddress: \(vmIP)"))
        #expect(yaml.contains("  - 127.0.0.1"))
        for document in yaml.components(separatedBy: "\n---\n") {
            #expect((try? Yams.load(yaml: document)) != nil)
        }
    }

    @Test func nodeLocalEndpointUsesClusterPort() {
        #expect(K8sHelper.nodeLocalControlPlaneEndpoint == "127.0.0.1:6443")
    }

    @Test func defaultWorkerCountKeepsNodeLocalEndpoint() throws {
        try assertControlPlaneEndpoint(arguments: [], workers: 0, expected: "127.0.0.1:6443")
    }

    @Test func explicitZeroWorkersKeepsNodeLocalEndpoint() throws {
        try assertControlPlaneEndpoint(arguments: ["--workers", "0"], workers: 0, expected: "127.0.0.1:6443")
    }

    @Test(arguments: [UInt(1), UInt(3)])
    func workersUseTheControlPlaneVMEndpoint(workerCount: UInt) throws {
        try assertControlPlaneEndpoint(
            arguments: ["--workers", "\(workerCount)"],
            workers: workerCount,
            expected: "\(vmIP):6443")
    }
}
