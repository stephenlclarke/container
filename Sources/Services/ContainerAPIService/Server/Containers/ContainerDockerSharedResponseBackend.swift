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

import ContainerEngineLogging
import ContainerResource
import ContainerRuntimeLinuxClient
import Foundation

extension ContainerDockerLoggingBackend: DockerLoggingSharedResponseBackend {
    public func systemInfoBaseJSON() async throws -> Data {
        do {
            async let snapshots = containers.list()
            async let imageCount = imageCountProvider()
            async let rootPath = containers.engineContainerRootPath()
            return try Self.jsonData(
                Self.systemInfoObject(
                    snapshots: try await snapshots,
                    imageCount: try await imageCount,
                    rootPath: await rootPath,
                    engineIdentity: engineIdentity,
                    serverVersion: serverVersion
                )
            )
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

    public func containerInspectBaseJSON(
        containerID: String
    ) async throws -> Data {
        do {
            let base = try await containers.engineInspectBase(
                containerID: containerID
            )
            return try Self.jsonData(Self.inspectObject(base))
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    private static func systemInfoObject(
        snapshots: [ContainerSnapshot],
        imageCount: Int,
        rootPath: String,
        engineIdentity: String,
        serverVersion: String
    ) -> [String: Any] {
        let running = snapshots.count {
            $0.status == .running || $0.status == .stopping
        }
        let paused = snapshots.count { $0.status == .paused }
        let stopped = snapshots.count - running - paused
        return [
            "ID": engineIdentity,
            "Containers": snapshots.count,
            "ContainersRunning": running,
            "ContainersPaused": paused,
            "ContainersStopped": stopped,
            "Images": imageCount,
            "Driver": "apple-container",
            "DriverStatus": [],
            "SystemStatus": [],
            "Plugins": [
                "Volume": ["local"],
                "Network": ["bridge", "host", "none"],
                "Authorization": [],
                "Log": [],
            ],
            "MemoryLimit": true,
            "SwapLimit": true,
            "CpuCfsPeriod": true,
            "CpuCfsQuota": true,
            "CPUShares": true,
            "CPUSet": true,
            "PidsLimit": true,
            "IPv4Forwarding": true,
            "Debug": false,
            "NFd": 0,
            "OomKillDisable": false,
            "NGoroutines": 0,
            "SystemTime": dockerDate(Date()),
            "LoggingDriver": "",
            "CgroupDriver": "cgroupfs",
            "CgroupVersion": "2",
            "NEventsListener": 0,
            "KernelVersion": "",
            "OperatingSystem": "Apple container Linux virtual machines",
            "OSVersion": "",
            "OSType": "linux",
            "Architecture": "aarch64",
            "IndexServerAddress": "https://index.docker.io/v1/",
            "RegistryConfig": registryConfiguration(),
            "NCPU": ProcessInfo.processInfo.activeProcessorCount,
            "MemTotal": boundedInt64(ProcessInfo.processInfo.physicalMemory),
            "GenericResources": [],
            "DockerRootDir": rootPath,
            "HttpProxy": "",
            "HttpsProxy": "",
            "NoProxy": "",
            "Name": Host.current().localizedName ?? "container",
            "Labels": [],
            "ExperimentalBuild": false,
            "ServerVersion": serverVersion,
            "Runtimes": [
                "container-runtime-linux": ["path": "container-runtime-linux"]
            ],
            "DefaultRuntime": "container-runtime-linux",
            "Swarm": inactiveSwarm(),
            "LiveRestoreEnabled": false,
            "Isolation": "",
            "InitBinary": "vminitd",
            "ContainerdCommit": ["ID": ""],
            "RuncCommit": ["ID": ""],
            "InitCommit": ["ID": ""],
            "SecurityOptions": [],
            "DefaultAddressPools": [],
            "CDISpecDirs": [],
            "Warnings": [],
        ]
    }

    private static func inspectObject(
        _ base: ContainerEngineInspectBase
    ) -> [String: Any] {
        let snapshot = base.snapshot
        let configuration = snapshot.configuration
        let runtime = base.runtimeData.flatMap {
            try? JSONDecoder().decode(LinuxRuntimeData.self, from: $0)
        }
        return [
            "Id": snapshot.id,
            "Created": dockerDate(configuration.creationDate),
            "Path": configuration.initProcess.executable,
            "Args": configuration.initProcess.arguments,
            "State": stateObject(snapshot),
            "Image": configuration.image.digest,
            "ResolvConfPath": "",
            "HostnamePath": "",
            "HostsPath": "",
            "LogPath": "",
            "Name": "/\(snapshot.id)",
            "RestartCount": 0,
            "Driver": "apple-container",
            "Platform": String(describing: configuration.platform.os),
            "MountLabel": "",
            "ProcessLabel": "",
            "AppArmorProfile": "",
            "ExecIDs": NSNull(),
            "HostConfig": hostConfigObject(
                configuration,
                options: base.options,
                runtime: runtime
            ),
            "GraphDriver": [
                "Data": [String: String](),
                "Name": "apple-container",
            ],
            "Mounts": configuration.mounts.map(mountPointObject),
            "Config": configObject(configuration),
            "NetworkSettings": networkSettingsObject(snapshot),
        ]
    }

    private static func stateObject(
        _ snapshot: ContainerSnapshot
    ) -> [String: Any] {
        let active =
            snapshot.status == .running
            || snapshot.status == .paused
            || snapshot.status == .stopping
        var result: [String: Any] = [
            "Status": dockerStatus(snapshot),
            "Running": active,
            "Paused": snapshot.status == .paused,
            "Restarting": false,
            "OOMKilled": false,
            "Dead": snapshot.status == .unknown,
            "Pid": active ? 1 : 0,
            "ExitCode": snapshot.exitCode ?? 0,
            "Error": "",
            "StartedAt": snapshot.startedDate.map(dockerDate)
                ?? "0001-01-01T00:00:00Z",
            "FinishedAt": snapshot.exitedDate.map(dockerDate)
                ?? "0001-01-01T00:00:00Z",
        ]
        if let health = snapshot.health, health != .none {
            result["Health"] = [
                "Status": health.rawValue,
                "FailingStreak": 0,
                "Log": [],
            ]
        }
        return result
    }

    private static func configObject(
        _ configuration: ContainerConfiguration
    ) -> [String: Any] {
        let process = configuration.initProcess
        let exposed = Set(
            configuration.exposedPorts
                + configuration.publishedPorts.flatMap { port in
                    (0..<port.count).map {
                        "\(port.containerPort + $0)/\(port.proto.rawValue)"
                    }
                }
        )
        let volumes = configuration.mounts.reduce(into: [String: Any]()) {
            if $1.isVolume {
                $0[$1.destination] = [String: String]()
            }
        }
        var result: [String: Any] = [
            "Hostname": configuration.hostname ?? configuration.id,
            "Domainname": configuration.domainname ?? "",
            "User": process.user.description,
            "AttachStdin": true,
            "AttachStdout": true,
            "AttachStderr": true,
            "ExposedPorts": Dictionary(
                uniqueKeysWithValues: exposed.sorted().map {
                    ($0, [String: String]())
                }
            ),
            "Tty": process.terminal,
            "OpenStdin": true,
            "StdinOnce": false,
            "Env": process.environment,
            "Cmd": process.arguments,
            "Image": configuration.image.reference,
            "Volumes": volumes,
            "WorkingDir": process.workingDirectory,
            "Entrypoint": [process.executable],
            "NetworkDisabled": false,
            "MacAddress": configuration.networks.first?.options.macAddress
                .map(String.init(describing:)) ?? "",
            "OnBuild": NSNull(),
            "Labels": configuration.labels,
            "StopSignal": configuration.stopSignal ?? "",
            "Shell": [],
        ]
        if let timeout = configuration.stopTimeoutInSeconds {
            result["StopTimeout"] = timeout
        } else {
            result["StopTimeout"] = NSNull()
        }
        if let health = configuration.healthCheck {
            result["Healthcheck"] = healthcheckObject(health)
        }
        return result
    }

    private static func hostConfigObject(
        _ configuration: ContainerConfiguration,
        options: ContainerCreateOptions,
        runtime: LinuxRuntimeData?
    ) -> [String: Any] {
        let process = configuration.initProcess
        let result: [String: Any] = [
            "Binds": configuration.mounts.compactMap(bindString),
            "ContainerIDFile": "",
            "LogConfig": ["Type": "", "Config": [String: String]()],
            "NetworkMode": networkMode(configuration),
            "PortBindings": portBindings(configuration.publishedPorts),
            "RestartPolicy": [
                "Name": options.restartPolicy.mode.rawValue,
                "MaximumRetryCount": options.restartPolicy.maximumRetryCount ?? 0,
            ],
            "AutoRemove": options.autoRemove,
            "VolumeDriver": "local",
            "VolumesFrom": [],
            "ConsoleSize": [0, 0],
            "Annotations": configuration.annotations,
            "CapAdd": configuration.capAdd,
            "CapDrop": configuration.capDrop,
            "CgroupnsMode": configuration.hostCgroupNamespace ? "host" : "private",
            "Dns": configuration.dns?.nameservers ?? [],
            "DnsOptions": configuration.dns?.options ?? [],
            "DnsSearch": configuration.dns?.searchDomains ?? [],
            "ExtraHosts": configuration.hosts.flatMap { host in
                host.hostnames.map { "\($0):\(host.ipAddress)" }
            },
            "GroupAdd": process.supplementalGroups.map(String.init)
                + process.supplementalGroupNames,
            "IpcMode": configuration.hostIPCNamespace ? "host" : "private",
            "Cgroup": "",
            "Links": [],
            "OomScoreAdj": process.oomScoreAdj ?? 0,
            "PidMode": configuration.hostPIDNamespace ? "host" : "",
            "Privileged": process.privileged,
            "PublishAllPorts": false,
            "ReadonlyRootfs": configuration.readOnly,
            "SecurityOpt": securityOptions(configuration),
            "StorageOpt": [String: String](),
            "Tmpfs": tmpfs(configuration.mounts),
            "UTSMode": configuration.hostUTSNamespace ? "host" : "",
            "UsernsMode": configuration.privateUserNamespace ? "private" : "host",
            "ShmSize": boundedInt64(configuration.shmSize ?? 64 * 1_024 * 1_024),
            "Sysctls": configuration.sysctls,
            "Runtime": configuration.runtimeHandler,
            "Isolation": "",
            "CpuShares": boundedInt64(runtime?.cpuShares ?? 0),
            "Memory": boundedInt64(configuration.resources.memoryInBytes),
            "NanoCpus": nanoCPUs(configuration.resources),
            "CgroupParent": runtime?.cgroupParent ?? "",
            "BlkioWeight": 0,
            "BlkioWeightDevice": [],
            "BlkioDeviceReadBps": [],
            "BlkioDeviceWriteBps": [],
            "BlkioDeviceReadIOps": [],
            "BlkioDeviceWriteIOps": [],
            "CpuPeriod": boundedInt64(
                configuration.resources.cpuPeriodInMicroseconds ?? 0
            ),
            "CpuQuota": configuration.resources.cpuQuotaInMicroseconds ?? 0,
            "CpuRealtimePeriod": 0,
            "CpuRealtimeRuntime": 0,
            "CpusetCpus": configuration.resources.cpuSet ?? "",
            "CpusetMems": "",
            "Devices": runtime?.devices.map(deviceObject) ?? [],
            "DeviceCgroupRules": runtime?.deviceCgroupRules.map(String.init(describing:))
                ?? [],
            "DeviceRequests": runtime?.gpuRequests.map(deviceRequestObject) ?? [],
            "MemoryReservation": runtime?.memoryReservationInBytes ?? 0,
            "MemorySwap": runtime?.memorySwapLimitInBytes ?? 0,
            "MemorySwappiness": NSNull(),
            "OomKillDisable": NSNull(),
            "PidsLimit": runtime?.pidsLimit as Any? ?? NSNull(),
            "Ulimits": process.rlimits.map(ulimitObject),
            "CPUCount": 0,
            "CPUPercent": 0,
            "IOMaximumIOps": 0,
            "IOMaximumBandwidth": 0,
            "Mounts": configuration.mounts.map(mountRequestObject),
            "MaskedPaths": configuration.maskedPaths ?? [],
            "ReadonlyPaths": configuration.readonlyPaths ?? [],
            "Init": configuration.useInit,
        ]
        return result
    }

    private static func networkSettingsObject(
        _ snapshot: ContainerSnapshot
    ) -> [String: Any] {
        let first = snapshot.networks.first
        return [
            "Bridge": "",
            "SandboxID": snapshot.status == .running ? snapshot.id : "",
            "SandboxKey": "",
            "Ports": portBindings(snapshot.configuration.publishedPorts),
            "HairpinMode": false,
            "LinkLocalIPv6Address": "",
            "LinkLocalIPv6PrefixLen": 0,
            "SecondaryIPAddresses": NSNull(),
            "SecondaryIPv6Addresses": NSNull(),
            "EndpointID": "",
            "Gateway": first.map { String(describing: $0.ipv4Gateway) } ?? "",
            "GlobalIPv6Address": first?.ipv6Address.map(cidrAddress) ?? "",
            "GlobalIPv6PrefixLen": first?.ipv6Address.map(cidrPrefixLength) ?? 0,
            "IPAddress": first.map { cidrAddress($0.ipv4Address) } ?? "",
            "IPPrefixLen": first.map { cidrPrefixLength($0.ipv4Address) } ?? 0,
            "IPv6Gateway": first?.ipv6Gateway.map(String.init(describing:)) ?? "",
            "MacAddress": first?.macAddress.map(String.init(describing:)) ?? "",
            "Networks": Dictionary(
                uniqueKeysWithValues: snapshot.networks.map {
                    ($0.network, endpointSettingsObject($0))
                }
            ),
        ]
    }

    private static func endpointSettingsObject(
        _ attachment: Attachment
    ) -> [String: Any] {
        [
            "IPAMConfig": NSNull(),
            "Links": NSNull(),
            "Aliases": attachment.aliases,
            "MacAddress": attachment.macAddress.map(String.init(describing:)) ?? "",
            "DriverOpts": NSNull(),
            "NetworkID": attachment.network,
            "EndpointID": "",
            "Gateway": String(describing: attachment.ipv4Gateway),
            "IPAddress": cidrAddress(attachment.ipv4Address),
            "IPPrefixLen": cidrPrefixLength(attachment.ipv4Address),
            "IPv6Gateway": attachment.ipv6Gateway.map(String.init(describing:)) ?? "",
            "GlobalIPv6Address": attachment.ipv6Address.map(cidrAddress) ?? "",
            "GlobalIPv6PrefixLen": attachment.ipv6Address.map(cidrPrefixLength) ?? 0,
            "DNSNames": [attachment.hostname] + attachment.aliases,
        ]
    }

    private static func mountPointObject(_ mount: Filesystem) -> [String: Any] {
        [
            "Type": mountType(mount),
            "Name": mount.volumeName ?? "",
            "Source": mount.isTmpfs ? "" : mount.source,
            "Destination": mount.destination,
            "Driver": mount.isVolume ? "local" : "",
            "Mode": mount.options.joined(separator: ","),
            "RW": !mount.options.readonly,
            "Propagation": "",
        ]
    }

    private static func mountRequestObject(_ mount: Filesystem) -> [String: Any] {
        var result: [String: Any] = [
            "Type": mountType(mount),
            "Source": mount.volumeName ?? (mount.isTmpfs ? "" : mount.source),
            "Target": mount.destination,
            "ReadOnly": mount.options.readonly,
            "Consistency": "default",
        ]
        if let subpath = mount.sourceSubpath {
            result["VolumeOptions"] = ["Subpath": subpath]
        }
        return result
    }

    private static func bindString(_ mount: Filesystem) -> String? {
        guard mount.isVirtiofs else {
            return nil
        }
        let mode =
            mount.options.isEmpty
            ? ""
            : ":\(mount.options.joined(separator: ","))"
        return "\(mount.source):\(mount.destination)\(mode)"
    }

    private static func mountType(_ mount: Filesystem) -> String {
        if mount.isTmpfs {
            return "tmpfs"
        }
        if mount.isVolume || mount.isBlock {
            return "volume"
        }
        return "bind"
    }

    private static func tmpfs(_ mounts: [Filesystem]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: mounts.filter(\.isTmpfs).map {
                ($0.destination, $0.options.joined(separator: ","))
            }
        )
    }

    private static func networkMode(
        _ configuration: ContainerConfiguration
    ) -> String {
        if configuration.hostNetwork {
            return "host"
        }
        return configuration.networks.first?.network ?? "default"
    }

    private static func portBindings(
        _ ports: [PublishPort]
    ) -> [String: Any] {
        var result = [String: Any]()
        for port in ports {
            for offset in 0..<port.count {
                let key = "\(port.containerPort + offset)/\(port.proto.rawValue)"
                result[key] = [
                    [
                        "HostIp": String(describing: port.hostAddress),
                        "HostPort": String(port.hostPort + offset),
                    ]
                ]
            }
        }
        return result
    }

    private static func securityOptions(
        _ configuration: ContainerConfiguration
    ) -> [String] {
        var result = [String]()
        if configuration.initProcess.noNewPrivileges {
            result.append("no-new-privileges")
        }
        if configuration.unconfinedSystemPaths {
            result.append("systempaths=unconfined")
        }
        return result
    }

    private static func healthcheckObject(
        _ health: ContainerHealthCheck
    ) -> [String: Any] {
        var result: [String: Any] = [
            "Test": [health.process.executable] + health.process.arguments,
            "Interval": boundedInt64(health.intervalInNanoseconds),
            "Timeout": boundedInt64(health.timeoutInNanoseconds),
            "Retries": health.retries,
            "StartPeriod": boundedInt64(health.startPeriodInNanoseconds),
        ]
        if let interval = health.startIntervalInNanoseconds {
            result["StartInterval"] = boundedInt64(interval)
        }
        return result
    }

    private static func deviceObject(
        _ device: LinuxDeviceMapping
    ) -> [String: Any] {
        [
            "PathOnHost": device.source,
            "PathInContainer": device.target,
            "CgroupPermissions": device.permissions,
        ]
    }

    private static func deviceRequestObject(
        _ request: LinuxGPURequest
    ) -> [String: Any] {
        [
            "Driver": request.driver,
            "Count": request.count,
            "DeviceIDs": request.deviceIDs,
            "Capabilities": request.capabilities.map { [$0] },
            "Options": request.options,
        ]
    }

    private static func ulimitObject(
        _ limit: ProcessConfiguration.Rlimit
    ) -> [String: Any] {
        [
            "Name": limit.limit,
            "Soft": boundedInt64(limit.soft),
            "Hard": boundedInt64(limit.hard),
        ]
    }

    private static func nanoCPUs(
        _ resources: ContainerConfiguration.Resources
    ) -> Int64 {
        guard
            let quota = resources.cpuQuotaInMicroseconds,
            let period = resources.cpuPeriodInMicroseconds,
            period > 0
        else {
            return 0
        }
        let value = Double(quota) / Double(period) * 1_000_000_000
        guard value.isFinite, value > 0 else {
            return 0
        }
        return Int64(min(value.rounded(), Double(Int64.max)))
    }

    private static func dockerStatus(_ snapshot: ContainerSnapshot) -> String {
        switch snapshot.status {
        case .stopped:
            return snapshot.startedDate == nil ? "created" : "exited"
        case .stopping:
            return "running"
        case .unknown:
            return "dead"
        case .running, .paused:
            return snapshot.status.rawValue
        }
    }

    private static func cidrAddress(_ value: some CustomStringConvertible) -> String {
        value.description.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? ""
    }

    private static func cidrPrefixLength(
        _ value: some CustomStringConvertible
    ) -> Int {
        let components = value.description.split(separator: "/", maxSplits: 1)
        return components.count == 2 ? Int(components[1]) ?? 0 : 0
    }

    private static func dockerDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func boundedInt64(_ value: UInt64) -> Int64 {
        Int64(min(value, UInt64(Int64.max)))
    }

    private static func registryConfiguration() -> [String: Any] {
        [
            "AllowNondistributableArtifactsCIDRs": [],
            "AllowNondistributableArtifactsHostnames": [],
            "IndexConfigs": [
                "docker.io": [
                    "Name": "docker.io",
                    "Mirrors": [],
                    "Secure": true,
                    "Official": true,
                ]
            ],
            "InsecureRegistryCIDRs": [],
            "Mirrors": [],
        ]
    }

    private static func inactiveSwarm() -> [String: Any] {
        [
            "NodeID": "",
            "NodeAddr": "",
            "LocalNodeState": "inactive",
            "ControlAvailable": false,
            "Error": "",
            "RemoteManagers": NSNull(),
            "Nodes": 0,
            "Managers": 0,
            "Cluster": NSNull(),
        ]
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DockerLoggingBackendError.server(
                "Container Engine response is not JSON encodable"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
