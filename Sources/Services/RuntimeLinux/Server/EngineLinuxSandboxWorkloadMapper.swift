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
import ContainerRuntimeLinuxClient
import Containerization
import ContainerizationError
import Foundation
import Logging
import SystemPackage

enum EngineLinuxSandboxWorkloadMapper {
    static func configure(
        _ workload: inout LinuxPod.ContainerConfiguration,
        from config: ContainerConfiguration,
        runtimeData: Data?,
        dynamicEnvironment: [String: String],
        networkEndpoints: [WorkloadNetworkEndpoint],
        stdio: [FileHandle?],
        loggingCapture: ContainerLogRuntimeCapture,
        log: Logger
    ) throws {
        workload.cpus = config.resources.cpus
        workload.cpuQuotaInMicroseconds = config.resources.cpuQuotaInMicroseconds
        workload.cpuPeriodInMicroseconds = config.resources.cpuPeriodInMicroseconds
        workload.cpuSet = config.resources.cpuSet
        workload.memoryInBytes = config.resources.memoryInBytes

        if let runtimeData {
            let linuxData = try JSONDecoder().decode(LinuxRuntimeData.self, from: runtimeData)
            let deviceMapping = try RuntimeService.resolveDeviceMappings(linuxData.devices)
            let gpu = try RuntimeService.resolveGPURequests(linuxData.gpuRequests)
            guard !gpu.enabled else {
                throw ContainerizationError(
                    .unsupported,
                    message: "GPU workloads require graphics on the shared sandbox launch configuration"
                )
            }
            workload.blockIO = linuxData.blockIO.map(RuntimeService.toContainerizationBlockIO)
            workload.pidsLimit = linuxData.pidsLimit
            workload.memoryReservationInBytes = linuxData.memoryReservationInBytes
            workload.memorySwapLimitInBytes = linuxData.memorySwapLimitInBytes
            workload.cpuShares = linuxData.cpuShares
            workload.cgroupParent = linuxData.cgroupParent
            workload.devices.append(contentsOf: deviceMapping.devices)
            workload.guestDevices.append(contentsOf: gpu.guestDevices)
            workload.deviceCgroupRules.append(
                contentsOf: linuxData.deviceCgroupRules + deviceMapping.cgroupRules
            )
        }

        workload.sysctl = try RuntimeService.resolvedSysctls(config: config)
        workload.annotations = config.annotations
        workload.useInit = config.useInit
        workload.pidNamespace = config.hostPIDNamespace ? .host : .privateNamespace
        workload.cgroupNamespace = config.hostCgroupNamespace ? .host : .privateNamespace
        workload.ipcNamespace = config.hostIPCNamespace ? .host : .privateNamespace
        workload.utsNamespace = config.hostUTSNamespace ? .host : .privateNamespace
        workload.userNamespace = config.privateUserNamespace ? .privateNamespace : .host
        workload.networkNamespace = config.hostNetwork ? .host : .privateNamespace
        let effectiveNetworkEndpoints = config.hostNetwork ? [] : networkEndpoints
        workload.networkEndpoints = effectiveNetworkEndpoints

        if let maskedPaths = config.maskedPaths {
            workload.maskedPaths = maskedPaths
        }
        if let readonlyPaths = config.readonlyPaths {
            workload.readonlyPaths = readonlyPaths
        }

        for mount in config.mounts {
            if try mount.isSocket() {
                let attributes = try? FileManager.default.attributesOfItem(atPath: mount.source)
                let permissions = (attributes?[.posixPermissions] as? NSNumber)
                    .map { FilePermissions(rawValue: mode_t($0.intValue)) }
                workload.sockets.append(
                    UnixSocketConfiguration(
                        source: URL(filePath: mount.source),
                        destination: URL(filePath: mount.destination),
                        permissions: permissions,
                        direction: .into
                    )
                )
            } else {
                workload.mounts.append(mount.asMount)
            }
        }

        for publishedSocket in config.publishedSockets {
            workload.sockets.append(
                UnixSocketConfiguration(
                    source: URL(filePath: publishedSocket.containerPath.string),
                    destination: URL(filePath: publishedSocket.hostPath.string),
                    permissions: publishedSocket.permissions,
                    direction: .outOf
                )
            )
        }

        if let socketURL = RuntimeService.sshAuthSocketHostUrl(
            config: config,
            dynamicEnv: dynamicEnvironment,
            log: log
        ) {
            let socketPath = socketURL.path(percentEncoded: false)
            let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)
                .map { FilePermissions(rawValue: mode_t($0.intValue)) }
            workload.sockets.append(
                UnixSocketConfiguration(
                    source: socketURL,
                    destination: URL(fileURLWithPath: RuntimeService.sshAuthSocketGuestPath),
                    permissions: permissions,
                    direction: .into
                )
            )
        }

        if let shmSize = config.shmSize {
            for index in workload.mounts.indices where workload.mounts[index].destination == "/dev/shm" {
                workload.mounts[index].options.removeAll { $0.hasPrefix("size=") }
                workload.mounts[index].options.append("size=\(shmSize)")
            }
        }

        workload.hostname = RuntimeService.resolvedHostname(config: config)
        if let dns = config.dns {
            workload.dns = DNS(
                nameservers: dns.nameservers,
                domain: dns.domain,
                searchDomains: dns.searchDomains,
                options: dns.options
            )
        }
        let primaryAddress = effectiveNetworkEndpoints.lazy
            .flatMap(\.interface.addresses)
            .first { $0.scope == .global }?
            .address.address.description
        let gatewayAddress = effectiveNetworkEndpoints.lazy
            .flatMap(\.interface.routes)
            .compactMap(\.nextHop)
            .first?
            .description
        workload.hosts = Hosts(
            entries: try RuntimeService.resolvedHosts(
                hostname: workload.hostname ?? config.id,
                primaryAddress: primaryAddress,
                gatewayAddress: gatewayAddress,
                extraHosts: config.hosts
            )
        )

        try configureProcess(
            &workload,
            from: config,
            stdio: stdio,
            loggingCapture: loggingCapture
        )
    }

    private static func configureProcess(
        _ workload: inout LinuxPod.ContainerConfiguration,
        from config: ContainerConfiguration,
        stdio: [FileHandle?],
        loggingCapture: ContainerLogRuntimeCapture
    ) throws {
        let process = config.initProcess
        workload.process.arguments = [process.executable] + process.arguments
        workload.process.environmentVariables = process.environment
        if config.ssh,
            !workload.process.environmentVariables.contains(
                where: { $0.starts(with: "\(RuntimeService.sshAuthSocketEnvVar)=") }
            )
        {
            workload.process.environmentVariables.append(
                "\(RuntimeService.sshAuthSocketEnvVar)=\(RuntimeService.sshAuthSocketGuestPath)"
            )
        }
        workload.process.terminal = process.terminal
        workload.process.workingDirectory = process.workingDirectory
        workload.process.oomScoreAdj = process.oomScoreAdj
        workload.process.noNewPrivileges = process.noNewPrivileges
        workload.process.rlimits = try process.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        workload.process.capabilities =
            process.privileged
            ? .allCapabilities
            : try RuntimeService.effectiveCapabilities(
                capAdd: config.capAdd,
                capDrop: config.capDrop
            )
        if process.privileged || config.unconfinedSystemPaths {
            workload.maskedPaths = []
            workload.readonlyPaths = []
        }
        switch process.user {
        case .raw(let name):
            workload.process.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: process.supplementalGroups,
                additionalGroupNames: process.supplementalGroupNames,
                username: name
            )
        case .id(let uid, let gid):
            workload.process.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: process.supplementalGroups,
                additionalGroupNames: process.supplementalGroupNames,
                username: ""
            )
        }

        let handles = normalizedStdio(stdio)
        workload.process.stdin = handles[0].map(AttachableInput.init)
        workload.process.stdout = AttachableOutput(
            initial: handles[1],
            persistent: loggingCapture.stdout
        )
        workload.process.stderr =
            process.terminal
            ? nil
            : AttachableOutput(
                initial: handles[2],
                persistent: loggingCapture.stderr
            )
    }

    private static func normalizedStdio(_ stdio: [FileHandle?]) -> [FileHandle?] {
        var handles = Array(stdio.prefix(3))
        while handles.count < 3 {
            handles.append(nil)
        }
        return handles
    }
}
