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

import ContainerAPIClient
import ContainerPlugin
import ContainerizationError
import Darwin
import Foundation
import Logging

extension ClusterBootstrapper {
    typealias CNIManifestExecutor = (
        _ containerID: String,
        _ executable: String,
        _ arguments: [String],
        _ client: ContainerClient,
        _ standardInput: Data
    ) async throws -> (code: Int32, output: String)

    func bootstrapControlPlane(
        nodeID: String, apiServerSANs: [String], advertiseAddress: String,
        schedulable: Bool, client: ContainerClient, log: Logger
    ) async throws {
        let configYAML = Self.initConfigYAML(
            kubernetesVersion: kubernetesVersion, advertiseAddress: advertiseAddress, certSANs: apiServerSANs,
            sharedImageStore: sharedImageStore,
            controlPlaneEndpoint: workers.isEmpty ? ClusterHelper.nodeLocalControlPlaneEndpoint : "\(advertiseAddress):\(ClusterHelper.clusterContainerPort)")
        var r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "cat > /etc/kubernetes/kubeadm-config.yaml <<'EOF'\n\(configYAML)\nEOF"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "write kubeadm config failed on \(nodeID): \(r.output)")
        }

        log.info("Running kubeadm init", metadata: ["node": "\(nodeID)"])
        r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: ClusterHelper.kubeadmPath,
            arguments: [
                "init", "--config", "/etc/kubernetes/kubeadm-config.yaml",
                "--ignore-preflight-errors", ClusterHelper.ignorePreflightErrors,
            ],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm init failed on \(nodeID): \(r.output)")
        }

        r = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "mkdir -p /root/.kube && cp \(ClusterHelper.kubeconfigPath) /root/.kube/config"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "failed to install root kubeconfig on \(nodeID): \(r.output)")
        }

        if schedulable {
            log.info("Removing control-plane taint for single-node scheduling", metadata: ["node": "\(nodeID)"])
            let taintCode = try await ClusterHelper.runProbe(
                client: client, containerId: nodeID,
                arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])
            guard taintCode == 0 else {
                throw ContainerizationError(.internalError, message: "failed to remove control-plane taint on \(nodeID)")
            }
        }

        if workers.isEmpty {
            try await Self.configureCoreDNS(nodeID: nodeID, advertiseAddress: advertiseAddress, client: client, log: log)
        }

        if skipCNI {
            log.info("Skipping CNI installation", metadata: ["node": "\(nodeID)"])
        } else {
            log.info("Applying CNI manifest", metadata: ["node": "\(nodeID)"])
            let manifest: String
            if let cniManifest { manifest = cniManifest } else { manifest = try await Self.loadCNIManifest(path: cni, log: log) }
            try await Self.applyCNIManifest(nodeID: nodeID, manifest: manifest, client: client, log: log) { id, executable, arguments, client, input in
                try await ClusterHelper.execCapture(containerId: id, executable: executable, arguments: arguments, client: client, standardInput: input)
            }
        }
    }

    static func applyCNIManifest(
        nodeID: String,
        manifest: String?,
        client: ContainerClient,
        log: Logger,
        execute: CNIManifestExecutor
    ) async throws {
        log.info("Applying CNI manifest", metadata: ["node": "\(nodeID)"])
        let resolvedManifest = try await resolveCNIManifest(customManifest: manifest, log: log)
        let apply = cniApplyInvocation(manifest: resolvedManifest)
        let result = try await execute(
            nodeID, apply.executable, apply.arguments, client, apply.standardInput)
        guard result.code == 0 else {
            throw ContainerizationError(.internalError, message: "apply CNI failed on \(nodeID): \(result.output)")
        }
    }

    static func cniApplyInvocation(manifest: String) -> (executable: String, arguments: [String], standardInput: Data) {
        (
            executable: ClusterHelper.kubectlPath,
            arguments: ["--kubeconfig", ClusterHelper.kubeconfigPath, "apply", "-f", "-"],
            standardInput: Data(manifest.utf8)
        )
    }

    private static func configureCoreDNS(
        nodeID: String,
        advertiseAddress: String,
        client: ContainerClient,
        log: Logger
    ) async throws {
        log.info("Configuring CoreDNS for the single-node resolver", metadata: ["node": "\(nodeID)"])

        var result = try await ClusterHelper.execCapture(
            containerId: nodeID,
            executable: ClusterHelper.kubectlPath,
            arguments: [
                "--kubeconfig", ClusterHelper.kubeconfigPath,
                "get", "configmap", "coredns", "-n", "kube-system",
                "-o", "jsonpath={.data.Corefile}",
            ],
            client: client
        )
        guard result.code == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "read CoreDNS configuration failed on \(nodeID): \(result.output)"
            )
        }

        let corefile = try coreDNSCorefile(result.output, bindAddress: advertiseAddress)
        let configPatch = try jsonString(["data": ["Corefile": corefile]])
        result = try await ClusterHelper.execCapture(
            containerId: nodeID,
            executable: ClusterHelper.kubectlPath,
            arguments: [
                "--kubeconfig", ClusterHelper.kubeconfigPath,
                "patch", "configmap", "coredns", "-n", "kube-system",
                "--type", "merge", "--patch", configPatch,
            ],
            client: client
        )
        guard result.code == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "patch CoreDNS configuration failed on \(nodeID): \(result.output)"
            )
        }

        // The node resolver listens on loopback. Running CoreDNS on the pod network
        // makes that address resolve back to CoreDNS itself and trips the loop plugin.
        // Host networking preserves access to the node resolver; binding only the
        // advertised address keeps CoreDNS from claiming the loopback listener.
        let deploymentPatch: [String: Any] = [
            "spec": [
                "replicas": 1,
                "template": [
                    "spec": [
                        "dnsPolicy": "Default",
                        "hostNetwork": true,
                    ]
                ],
            ]
        ]
        let deploymentPatchJSON = try jsonString(deploymentPatch)
        result = try await ClusterHelper.execCapture(
            containerId: nodeID,
            executable: ClusterHelper.kubectlPath,
            arguments: [
                "--kubeconfig", ClusterHelper.kubeconfigPath,
                "patch", "deployment", "coredns", "-n", "kube-system",
                "--type", "strategic", "--patch", deploymentPatchJSON,
            ],
            client: client
        )
        guard result.code == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "patch CoreDNS deployment failed on \(nodeID): \(result.output)"
            )
        }
    }

    static func coreDNSCorefile(_ corefile: String, bindAddress: String) throws -> String {
        var address = in_addr()
        guard bindAddress.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw ContainerizationError(.invalidArgument, message: "invalid CoreDNS bind address: \(bindAddress)")
        }

        let serverBlock = ".:53 {"
        let bindDirective = "    bind \(bindAddress)"
        guard corefile.contains(serverBlock) else {
            throw ContainerizationError(.internalError, message: "CoreDNS configuration is missing the root server block")
        }
        guard !corefile.contains(bindDirective) else { return corefile }
        return corefile.replacingOccurrences(
            of: serverBlock,
            with: "\(serverBlock)\n\(bindDirective)",
            options: [],
            range: corefile.startIndex..<corefile.endIndex
        )
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "failed to encode Kubernetes patch")
        }
        return value
    }

    func createJoinToken(nodeID: String, client: ContainerClient) async throws -> (token: String, caCertHash: String) {
        let (code, output) = try await ClusterHelper.execCapture(
            containerId: nodeID, executable: ClusterHelper.kubeadmPath,
            arguments: ["token", "create", "--print-join-command"],
            client: client)
        guard code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm token create failed on \(nodeID): \(output)")
        }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
        guard let tokenIdx = parts.firstIndex(of: "--token"), tokenIdx + 1 < parts.count,
            let hashIdx = parts.firstIndex(of: "--discovery-token-ca-cert-hash"), hashIdx + 1 < parts.count
        else {
            throw ContainerizationError(.internalError, message: "could not parse join command output from kubeadm on \(nodeID)")
        }
        return (token: parts[tokenIdx + 1], caCertHash: parts[hashIdx + 1])
    }

    static func loadCNIManifest(path: String?, log: Logger) async throws -> String {
        try await resolveCNIManifest(customManifest: ClusterCreate.snapshotCNIManifest(at: path), log: log)
    }

    static func resolveCNIManifest(customManifest: String?, log: Logger) async throws -> String {
        if let customManifest { return customManifest }
        return try await loadKindnetManifest(log: log)
    }

    private static func loadKindnetManifest(log: Logger) async throws -> String {
        let url = try await ClusterHelper.pluginResourceURL(log: log).appendingPathComponent("kindnet.yaml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing at \(url.path)")
        }
        return contents
    }

    static func initConfigYAML(
        kubernetesVersion: String, advertiseAddress: String, certSANs: [String], sharedImageStore: Bool, controlPlaneEndpoint: String? = nil
    ) -> String {
        let sans = certSANs.map { "  - \($0)" }.joined(separator: "\n")
        var kubelet = """
            apiVersion: kubelet.config.k8s.io/v1beta1
            kind: KubeletConfiguration
            cgroupDriver: systemd
            failSwapOn: false
            """
        if sharedImageStore {
            kubelet += "\nimageServiceEndpoint: unix://\(ClusterHelper.nodeImageServiceSocketPath)"
        }
        let endpoint = controlPlaneEndpoint.map { "controlPlaneEndpoint: \($0)\n" } ?? ""
        return """
            apiVersion: kubeadm.k8s.io/v1beta4
            kind: InitConfiguration
            localAPIEndpoint:
              advertiseAddress: \(advertiseAddress)
              bindPort: 6443
            nodeRegistration:
              criSocket: unix:///run/containerd/containerd.sock
            ---
            apiVersion: kubeadm.k8s.io/v1beta4
            kind: ClusterConfiguration
            \(endpoint)kubernetesVersion: \(kubernetesVersion)
            networking:
              podSubnet: \(ClusterHelper.podSubnet)
            apiServer:
              certSANs:
            \(sans)
            ---
            \(kubelet)
            """
    }
}
