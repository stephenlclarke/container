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
import ContainerizationOCI
import Darwin
import Foundation
import Logging

extension K8sHelper {

    public static func prepareNode(nodeID: String, client: ContainerClient, log: Logger) async throws {
        log.info("Preparing node", metadata: ["id": "\(nodeID)"])
        let result = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", nodePrepScript], client: client)
        guard result.code == 0 else {
            throw ContainerizationError(.internalError, message: "node prep failed on \(nodeID): \(result.output)")
        }
    }

    static func bootstrapControlPlane(
        nodeID: String, apiServerSANs: [String], advertiseAddress: String,
        controlPlaneEndpoint: String,
        schedulable: Bool, client: ContainerClient, log: Logger
    ) async throws {
        let configYAML = initConfigYAML(
            advertiseAddress: advertiseAddress, certSANs: apiServerSANs,
            controlPlaneEndpoint: controlPlaneEndpoint)
        var r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "mkdir -p /kind && cat > /kind/kubeadm.conf <<'EOF'\n\(configYAML)\nEOF"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "write kubeadm config failed on \(nodeID): \(r.output)")
        }

        log.info("Running kubeadm init", metadata: ["node": "\(nodeID)"])
        r = try await execCapture(
            containerId: nodeID, executable: kubeadmPath,
            arguments: [
                "init", "--config", "/kind/kubeadm.conf",
                "--ignore-preflight-errors", ignorePreflightErrors,
            ],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "kubeadm init failed on \(nodeID): \(r.output)")
        }

        r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", "mkdir -p /root/.kube && cp \(kubeconfigPath) /root/.kube/config"],
            client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "failed to install root kubeconfig on \(nodeID): \(r.output)")
        }

        try await configureCoreDNS(
            nodeID: nodeID,
            advertiseAddress: advertiseAddress,
            client: client,
            log: log
        )

        if schedulable {
            log.info("Removing control-plane taint for single-node scheduling", metadata: ["node": "\(nodeID)"])
            _ = try await runProbe(
                client: client, containerId: nodeID,
                arguments: ["taint", "nodes", "--all", "node-role.kubernetes.io/control-plane-"])
        }

        log.info("Applying kindnet CNI", metadata: ["node": "\(nodeID)"])
        let manifest = try await loadKindnetManifest(log: log)
        let apply =
            "cat > /tmp/kindnet.yaml <<'EOF'\n\(manifest)\nEOF\n"
            + "\(kubeconfigEnv) kubectl apply -f /tmp/kindnet.yaml"
        r = try await execCapture(
            containerId: nodeID, executable: "/bin/sh",
            arguments: ["-c", apply], client: client)
        guard r.code == 0 else {
            throw ContainerizationError(.internalError, message: "apply CNI failed on \(nodeID): \(r.output)")
        }
    }

    private static func configureCoreDNS(
        nodeID: String,
        advertiseAddress: String,
        client: ContainerClient,
        log: Logger
    ) async throws {
        log.info("Configuring CoreDNS for the single-node resolver", metadata: ["node": "\(nodeID)"])

        var result = try await execCapture(
            containerId: nodeID,
            executable: kubectlPath,
            arguments: [
                "--kubeconfig", kubeconfigPath,
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
        result = try await execCapture(
            containerId: nodeID,
            executable: kubectlPath,
            arguments: [
                "--kubeconfig", kubeconfigPath,
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
        result = try await execCapture(
            containerId: nodeID,
            executable: kubectlPath,
            arguments: [
                "--kubeconfig", kubeconfigPath,
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

    static func createJoinToken(nodeID: String, client: ContainerClient) async throws -> (token: String, caCertHash: String) {
        let (code, output) = try await execCapture(
            containerId: nodeID, executable: kubeadmPath,
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

    private static func loadKindnetManifest(log: Logger) async throws -> String {
        let pluginLoader = try await Utility.createPluginLoader(log: log)
        guard let plugin = pluginLoader.findPlugin(forExecutable: CommandLine.executablePath),
            let resourceURL = plugin.resourceURL
        else {
            throw ContainerizationError(.internalError, message: "unable to locate k8s plugin installation or resources")
        }
        let url = resourceURL.appendingPathComponent("kindnet.yaml")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "kindnet manifest resource missing at \(url.path)")
        }
        return contents
    }

    private static var nodePrepScript: String {
        """
        set -e
        mkdir -p /etc/containerd/conf.d
        cat > /etc/containerd/conf.d/native-snapshotter.toml <<'EOF'
        [plugins.'io.containerd.cri.v1.images']
          snapshotter = "native"
        EOF
        sysctl -w net.ipv4.ip_forward=1                 2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-iptables=1  2>/dev/null || true
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 2>/dev/null || true
        systemctl restart containerd
        ctr -n k8s.io images tag registry.k8s.io/pause:3.10 registry.k8s.io/pause:3.10.1 2>/dev/null || true
        /usr/sbin/iptables-nft -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        /usr/sbin/iptables-nft -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220
        """
    }

    static func initConfigYAML(
        advertiseAddress: String, certSANs: [String], controlPlaneEndpoint: String
    ) -> String {
        let sans = certSANs.map { "  - \($0)" }.joined(separator: "\n")
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
            controlPlaneEndpoint: \(controlPlaneEndpoint)
            kubernetesVersion: \(kubernetesVersion())
            networking:
              podSubnet: \(podSubnet)
            apiServer:
              certSANs:
            \(sans)
            ---
            apiVersion: kubelet.config.k8s.io/v1beta1
            kind: KubeletConfiguration
            cgroupDriver: systemd
            failSwapOn: false
            """
    }

    private static func kubernetesVersion() -> String {
        let nameAndTag = nodeImage.split(separator: "@").first.map(String.init) ?? nodeImage
        guard let ref = try? Reference.parse(nameAndTag), let tag = ref.tag else { return "v1.35" }
        return tag
    }
}
