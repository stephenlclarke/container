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
import ContainerizationOCI
import Foundation

private struct DockerImageGroup {
    let digest: String
    let descriptor: Descriptor
    let resources: [ImageResource]
    let variant: ImageResource.Variant?

    var creationDate: Date {
        resources.map(\.creationDate).min()
            ?? Date(timeIntervalSince1970: 0)
    }

    var repoTags: [String] {
        resources.map(\.displayReference)
            .filter { !$0.contains("@") }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    var repoDigests: [String] {
        Set(repoTags.map { "\(ContainerDockerLoggingBackend.repositoryName($0))@\(digest)" })
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    var referenceAliases: Set<String> {
        Set(
            resources.flatMap { [$0.name, $0.displayReference] }
                + repoTags
                + repoDigests
                + [digest]
        )
    }
}

extension ContainerDockerLoggingBackend:
    DockerEngineDiscoveryBackend,
    DockerImageDiscoveryBackend,
    DockerLoggingSharedResponseBackend
{
    public func systemVersionJSON() async throws -> Data {
        try Self.jsonData(
            Self.systemVersionObject(serverVersion: serverVersion)
        )
    }

    public func containerListJSON(
        request: DockerContainerListRequest
    ) async throws -> Data {
        do {
            let snapshots = try await containers.list()
            return try Self.jsonArrayData(
                Self.containerListObjects(
                    snapshots: snapshots,
                    request: request
                )
            )
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

    public func imageListJSON(
        request: DockerImageListRequest
    ) async throws -> Data {
        do {
            async let resources = imageResourceProvider()
            async let snapshots = containers.list()
            return try Self.jsonArrayData(
                Self.imageListObjects(
                    resources: try await resources,
                    snapshots: try await snapshots,
                    request: request
                )
            )
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

    public func imageInspectJSON(name: String) async throws -> Data {
        do {
            let groups = Self.imageGroups(
                try await imageResourceProvider()
            )
            guard let group = Self.resolveImageReference(name, in: groups) else {
                throw DockerLoggingBackendError.imageNotFound(name)
            }
            return try Self.jsonData(Self.imageInspectObject(group))
        } catch {
            throw Self.map(error, containerID: nil)
        }
    }

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
            let resolvedID = try await containers.resolveDockerContainerIdentifier(
                containerID
            )
            let base = try await containers.engineInspectBase(
                containerID: resolvedID
            )
            return try Self.jsonData(Self.inspectObject(base))
        } catch {
            throw Self.map(error, containerID: containerID)
        }
    }

    private static func systemVersionObject(
        serverVersion: String
    ) -> [String: Any] {
        let details = [
            "ApiVersion": "1.53",
            "Arch": "arm64",
            "BuildTime": "",
            "Experimental": "false",
            "GitCommit": serverVersion,
            "GoVersion": "",
            "KernelVersion": "",
            "MinAPIVersion": "1.44",
            "Os": "linux",
        ]
        return [
            "Platform": ["Name": "container Engine"],
            "Components": [[
                "Name": "Engine",
                "Version": serverVersion,
                "Details": details,
            ]],
            "Version": serverVersion,
            "ApiVersion": "1.53",
            "MinAPIVersion": "1.44",
            "GitCommit": serverVersion,
            "GoVersion": "",
            "Os": "linux",
            "Arch": "arm64",
            "KernelVersion": "",
            "BuildTime": "",
        ]
    }

    static func containerListObjects(
        snapshots: [ContainerSnapshot],
        request: DockerContainerListRequest,
        now: Date = Date()
    ) throws -> [[String: Any]] {
        var references = [String: ContainerSnapshot]()
        for snapshot in snapshots {
            references[snapshot.id] = snapshot
            references[dockerContainerID(snapshot)] = snapshot
            references[dockerContainerName(snapshot)] = snapshot
        }
        var selected = snapshots
            .filter { request.all || isRunning($0) }
            .sorted {
                if $0.configuration.creationDate != $1.configuration.creationDate {
                    return $0.configuration.creationDate > $1.configuration.creationDate
                }
                return utf8Less(dockerContainerID($0), dockerContainerID($1))
            }
        for (name, values) in request.filters where !values.isEmpty {
            selected = try selected.filter { snapshot in
                try values.contains { value in
                    try matchesContainerListFilter(
                        name: name,
                        value: value,
                        snapshot: snapshot,
                        references: references
                    )
                }
            }
        }
        if let limit = request.limit, limit > 0 {
            selected = Array(selected.prefix(limit))
        }
        return selected.map {
            containerListObject($0, includeSize: request.size, now: now)
        }
    }

    static func imageListObjects(
        resources: [ImageResource],
        snapshots: [ContainerSnapshot],
        request: DockerImageListRequest
    ) throws -> [[String: Any]] {
        let allGroups = imageGroups(resources)
        var selected = allGroups
        for (name, values) in request.filters where !values.isEmpty {
            selected = try selected.filter { group in
                try values.contains { value in
                    try matchesImageListFilter(
                        name: name,
                        value: value,
                        group: group,
                        allGroups: allGroups
                    )
                }
            }
        }
        selected.sort {
            if $0.creationDate != $1.creationDate {
                return $0.creationDate > $1.creationDate
            }
            return utf8Less($0.digest, $1.digest)
        }
        return try selected.map {
            try imageListObject($0, snapshots: snapshots)
        }
    }

    private static func imageListObject(
        _ group: DockerImageGroup,
        snapshots: [ContainerSnapshot]
    ) throws -> [String: Any] {
        let aliases = group.referenceAliases
        let containers = snapshots.count {
            let image = $0.configuration.image
            return image.digest == group.digest
                || aliases.contains(image.reference)
        }
        return [
            "Containers": containers,
            "Created": Int64(group.creationDate.timeIntervalSince1970),
            "Descriptor": descriptorObject(group.descriptor),
            "Id": group.digest,
            "Labels": group.variant?.imageConfigLabels ?? [:],
            "ParentId": "",
            "RepoDigests": group.repoDigests,
            "RepoTags": group.repoTags,
            "SharedSize": -1,
            "Size": group.variant?.size ?? group.descriptor.size,
        ]
    }

    private static func imageInspectObject(
        _ group: DockerImageGroup
    ) throws -> [String: Any] {
        guard let variant = group.variant else {
            throw DockerLoggingBackendError.server(
                "image \(group.digest) has no runnable platform variant"
            )
        }
        var config = try encodableJSONObject(variant.config.config)
        if let healthCheck = variant.healthCheck {
            config["Healthcheck"] = try encodableJSONObject(healthCheck)
        }
        let pullRepositories = Set(group.repoTags.map(repositoryName))
            .sorted(by: utf8Less)
            .map { ["Repository": $0] }
        return [
            "Architecture": variant.config.architecture,
            "Comment": variant.config.history?.compactMap(\.comment).last ?? "",
            "Config": config,
            "Created": variant.config.created ?? dockerDate(group.creationDate),
            "Descriptor": descriptorObject(group.descriptor),
            "Id": group.digest,
            "Identity": ["Pull": pullRepositories],
            "Metadata": ["LastTagTime": "0001-01-01T00:00:00Z"],
            "Os": variant.config.os,
            "RepoDigests": group.repoDigests,
            "RepoTags": group.repoTags,
            "RootFS": [
                "Layers": variant.config.rootfs.diffIDs,
                "Type": variant.config.rootfs.type,
            ],
            "Size": variant.size,
            "Variant": variant.config.variant ?? variant.platform.variant ?? "",
        ]
    }

    private static func imageGroups(
        _ resources: [ImageResource]
    ) -> [DockerImageGroup] {
        Dictionary(grouping: resources) {
            $0.configuration.descriptor.digest
        }.compactMap { digest, groupedResources in
            guard let descriptor = groupedResources.first?.configuration.descriptor else {
                return nil
            }
            let variants = groupedResources.flatMap(\.variants)
            let variant = variants.first { $0.platform == .current }
                ?? variants.first { $0.platform.os == "linux" }
                ?? variants.first
            return DockerImageGroup(
                digest: digest,
                descriptor: descriptor,
                resources: groupedResources,
                variant: variant
            )
        }
    }

    private static func matchesImageListFilter(
        name: String,
        value: String,
        group: DockerImageGroup,
        allGroups: [DockerImageGroup]
    ) throws -> Bool {
        switch name {
        case "reference":
            return group.referenceAliases.contains {
                wildcardMatch(pattern: value, value: $0)
            }
        case "label":
            let components = value.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let labels = group.variant?.imageConfigLabels ?? [:]
            guard let actual = labels[String(components[0])] else {
                return false
            }
            return components.count == 1 || actual == String(components[1])
        case "dangling":
            guard let requested = dockerBool(value) else {
                throw DockerLoggingBackendError.invalidParameter(
                    "invalid filter 'dangling=[\(value)]'"
                )
            }
            return group.repoTags.isEmpty == requested
        case "before", "since":
            guard let reference = resolveImageReference(value, in: allGroups) else {
                throw DockerLoggingBackendError.imageNotFound(value)
            }
            if name == "before" {
                return group.creationDate < reference.creationDate
            }
            return group.creationDate > reference.creationDate
        default:
            throw DockerLoggingBackendError.invalidParameter(
                "invalid filter '\(name)'"
            )
        }
    }

    private static func resolveImageReference(
        _ name: String,
        in groups: [DockerImageGroup]
    ) -> DockerImageGroup? {
        let defaultTagName = hasExplicitImageTag(name) ? nil : "\(name):latest"
        let exact = groups.filter {
            $0.referenceAliases.contains(name)
                || defaultTagName.map($0.referenceAliases.contains) == true
        }
        if exact.count == 1 {
            return exact[0]
        }

        let digestPrefix: String
        if name.hasPrefix("sha256:") {
            digestPrefix = name
        } else if name.allSatisfy(\.isHexDigit) {
            digestPrefix = "sha256:\(name)"
        } else {
            return nil
        }
        let digestMatches = groups.filter { $0.digest.hasPrefix(digestPrefix) }
        return digestMatches.count == 1 ? digestMatches[0] : nil
    }

    private static func hasExplicitImageTag(_ reference: String) -> Bool {
        if reference.contains("@") {
            return true
        }
        let lastComponent = reference.split(separator: "/").last ?? ""
        return lastComponent.contains(":")
    }

    fileprivate static func repositoryName(_ reference: String) -> String {
        let withoutDigest = reference.split(separator: "@", maxSplits: 1)
            .first.map(String.init) ?? reference
        guard let slash = withoutDigest.lastIndex(of: "/") else {
            return withoutDigest.split(separator: ":", maxSplits: 1)
                .first.map(String.init) ?? withoutDigest
        }
        let suffix = withoutDigest[withoutDigest.index(after: slash)...]
        guard let colon = suffix.lastIndex(of: ":") else {
            return withoutDigest
        }
        let absoluteColon = withoutDigest.index(
            slash,
            offsetBy: suffix.distance(from: suffix.startIndex, to: colon) + 1
        )
        return String(withoutDigest[..<absoluteColon])
    }

    private static func wildcardMatch(
        pattern: String,
        value: String
    ) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: #"\*"#, with: ".*")
            .replacingOccurrences(of: #"\?"#, with: ".")
        guard let expression = try? NSRegularExpression(pattern: "^\(escaped)$") else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func dockerBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true":
            true
        case "0", "false":
            false
        default:
            nil
        }
    }

    private static func descriptorObject(
        _ descriptor: Descriptor
    ) -> [String: Any] {
        [
            "digest": descriptor.digest,
            "mediaType": descriptor.mediaType,
            "size": descriptor.size,
        ]
    }

    private static func encodableJSONObject<T: Encodable>(
        _ value: T?
    ) throws -> [String: Any] {
        guard let value else {
            return [:]
        }
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw DockerLoggingBackendError.server(
                "Container image metadata is not a JSON object"
            )
        }
        return object
    }

    private static func containerListObject(
        _ snapshot: ContainerSnapshot,
        includeSize: Bool,
        now: Date
    ) -> [String: Any] {
        let configuration = snapshot.configuration
        var result: [String: Any] = [
            "Id": dockerContainerID(snapshot),
            "Names": ["/\(dockerContainerName(snapshot))"],
            "Image": configuration.image.reference,
            "ImageID": configuration.image.digest,
            "Command": commandString(configuration.initProcess),
            "Created": Int64(configuration.creationDate.timeIntervalSince1970),
            "Ports": portSummaries(configuration),
            "Labels": configuration.labels,
            "State": dockerStatus(snapshot),
            "Status": containerListStatus(snapshot, now: now),
            "HostConfig": ["NetworkMode": networkMode(configuration)],
            "NetworkSettings": [
                "Networks": listNetworks(snapshot),
            ],
            "Mounts": configuration.mounts.map(mountPointObject),
            "Health": [
                "Status": (snapshot.health ?? .none).rawValue,
                "FailingStreak": 0,
            ],
            "ImageManifestDescriptor": NSNull(),
        ]
        if includeSize {
            result["SizeRw"] = 0
            result["SizeRootFs"] = 0
        }
        return result
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
            "Id": dockerContainerID(snapshot),
            "Created": dockerDate(configuration.creationDate),
            "Path": configuration.initProcess.executable,
            "Args": configuration.initProcess.arguments,
            "State": stateObject(snapshot, error: base.stateError),
            "Image": configuration.image.digest,
            "ResolvConfPath": "",
            "HostnamePath": "",
            "HostsPath": "",
            "LogPath": "",
            "Name": "/\(dockerContainerName(snapshot))",
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
        _ snapshot: ContainerSnapshot,
        error: String
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
            // Docker reports a rejected start as a created container with exit code 128,
            // even though no native init process was ever started.
            "ExitCode": snapshot.exitCode ?? (error.isEmpty ? 0 : 128),
            "Error": error,
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
                    (0 ..< port.count).map {
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
            for offset in 0 ..< port.count {
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

    private static func isRunning(_ snapshot: ContainerSnapshot) -> Bool {
        snapshot.status == .running
            || snapshot.status == .paused
            || snapshot.status == .stopping
    }

    private static func matchesContainerListFilter(
        name: String,
        value: String,
        snapshot: ContainerSnapshot,
        references: [String: ContainerSnapshot]
    ) throws -> Bool {
        let configuration = snapshot.configuration
        switch name {
        case "id":
            return dockerContainerID(snapshot).hasPrefix(value)
        case "name":
            return matchesPattern(value, in: "/\(dockerContainerName(snapshot))")
        case "label":
            let parts = value.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let key = String(parts[0])
            guard let actual = configuration.labels[key] else {
                return false
            }
            return parts.count == 1 || actual == String(parts[1])
        case "status":
            return dockerStatus(snapshot) == value
        case "exited":
            return snapshot.exitCode.map(String.init) == value
        case "ancestor":
            return configuration.image.reference == value
                || configuration.image.digest == value
                || configuration.image.digest.hasPrefix(value)
        case "before", "since":
            guard let reference = resolveListReference(value, in: references) else {
                return false
            }
            if name == "before" {
                return configuration.creationDate < reference.configuration.creationDate
            }
            return configuration.creationDate > reference.configuration.creationDate
        case "network":
            return networkMode(configuration) == value
                || configuration.networks.contains { $0.network == value }
                || snapshot.networks.contains { $0.network == value }
        case "volume":
            return configuration.mounts.contains {
                $0.source == value
                    || $0.destination == value
                    || $0.volumeName == value
            }
        case "publish", "expose":
            return portFilterMatches(value, configuration: configuration)
        case "health":
            return (snapshot.health ?? .none).rawValue == value
        case "is-task":
            return value.lowercased() == "false"
        case "isolation":
            return value == "" || value == "default"
        default:
            throw DockerLoggingBackendError.invalidParameter(
                "Invalid filter '\(name)'"
            )
        }
    }

    private static func resolveListReference(
        _ value: String,
        in references: [String: ContainerSnapshot]
    ) -> ContainerSnapshot? {
        references[value]
            ?? references.values.first { dockerContainerID($0).hasPrefix(value) }
    }

    private static func dockerContainerID(_ snapshot: ContainerSnapshot) -> String {
        snapshot.configuration.dockerID ?? snapshot.id
    }

    private static func dockerContainerName(_ snapshot: ContainerSnapshot) -> String {
        snapshot.configuration.dockerName ?? snapshot.id
    }

    private static func matchesPattern(_ pattern: String, in value: String) -> Bool {
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ) != nil
        else {
            return value.contains(pattern)
        }
        return true
    }

    private static func portFilterMatches(
        _ value: String,
        configuration: ContainerConfiguration
    ) -> Bool {
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let protocolName = components.count == 2 ? String(components[1]) : nil
        let range = components[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard
            let lower = UInt16(range[0]),
            let upper = UInt16(range.count == 2 ? range[1] : range[0]),
            lower <= upper
        else {
            return false
        }
        let ports = Set(
            configuration.exposedPorts
                + configuration.publishedPorts.flatMap { port in
                    (0 ..< port.count).map {
                        "\(port.containerPort + $0)/\(port.proto.rawValue)"
                    }
                }
        )
        return ports.contains { port in
            let parts = port.split(separator: "/", maxSplits: 1)
            guard let number = UInt16(parts[0]) else {
                return false
            }
            let matchesProtocol = protocolName.map {
                parts.count == 2 && parts[1] == Substring($0)
            } ?? true
            return lower ... upper ~= number && matchesProtocol
        }
    }

    private static func commandString(
        _ process: ProcessConfiguration
    ) -> String {
        ([process.executable] + process.arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
        )
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy({ safe.contains($0) })
        else {
            return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return value
    }

    private static func portSummaries(
        _ configuration: ContainerConfiguration
    ) -> [[String: Any]] {
        var result = [[String: Any]]()
        var published = Set<String>()
        for port in configuration.publishedPorts {
            for offset in 0 ..< port.count {
                let privatePort = port.containerPort + offset
                let protocolName = port.proto.rawValue
                published.insert("\(privatePort)/\(protocolName)")
                result.append([
                    "IP": String(describing: port.hostAddress),
                    "PrivatePort": privatePort,
                    "PublicPort": port.hostPort + offset,
                    "Type": protocolName,
                ])
            }
        }
        for exposed in configuration.exposedPorts.sorted(by: utf8Less)
            where !published.contains(exposed)
        {
            let parts = exposed.split(separator: "/", maxSplits: 1)
            guard let privatePort = UInt16(parts[0]) else {
                continue
            }
            result.append([
                "PrivatePort": privatePort,
                "Type": parts.count == 2 ? String(parts[1]) : "tcp",
            ])
        }
        return result
    }

    private static func listNetworks(
        _ snapshot: ContainerSnapshot
    ) -> [String: Any] {
        var result = Dictionary(
            uniqueKeysWithValues: snapshot.networks.map {
                ($0.network, endpointSettingsObject($0))
            }
        )
        for attachment in snapshot.configuration.networks
            where result[attachment.network] == nil
        {
            result[attachment.network] = [
                "IPAMConfig": NSNull(),
                "Links": NSNull(),
                "Aliases": attachment.options.aliases,
                "MacAddress": attachment.options.macAddress
                    .map(String.init(describing:)) ?? "",
                "DriverOpts": NSNull(),
                "NetworkID": attachment.network,
                "EndpointID": "",
                "Gateway": "",
                "IPAddress": "",
                "IPPrefixLen": 0,
                "IPv6Gateway": "",
                "GlobalIPv6Address": "",
                "GlobalIPv6PrefixLen": 0,
                "DNSNames": [attachment.options.hostname]
                    + attachment.options.aliases,
            ]
        }
        return result
    }

    private static func containerListStatus(
        _ snapshot: ContainerSnapshot,
        now: Date
    ) -> String {
        switch dockerStatus(snapshot) {
        case "created":
            return "Created"
        case "running", "paused":
            let age = humanDuration(
                from: snapshot.startedDate ?? snapshot.configuration.creationDate,
                to: now
            )
            return snapshot.status == .paused ? "Up \(age) (Paused)" : "Up \(age)"
        case "exited":
            let age = humanDuration(
                from: snapshot.exitedDate ?? snapshot.startedDate
                    ?? snapshot.configuration.creationDate,
                to: now
            )
            return "Exited (\(snapshot.exitCode ?? 0)) \(age) ago"
        case "dead":
            return "Dead"
        default:
            return dockerStatus(snapshot)
        }
    }

    private static func humanDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        switch seconds {
        case 0:
            return "Less than a second"
        case 1:
            return "1 second"
        case 2 ..< 60:
            return "\(seconds) seconds"
        case 60 ..< 120:
            return "About a minute"
        case 120 ..< 3600:
            return "\(seconds / 60) minutes"
        case 3600 ..< 7200:
            return "About an hour"
        case 7200 ..< 172_800:
            return "\(seconds / 3600) hours"
        case 172_800 ..< 1_209_600:
            return "\(seconds / 86400) days"
        case 1_209_600 ..< 5_184_000:
            return "\(seconds / 604_800) weeks"
        case 5_184_000 ..< 63_072_000:
            return "\(seconds / 2_592_000) months"
        default:
            return "\(seconds / 31_536_000) years"
        }
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

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
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

    private static func jsonArrayData(
        _ objects: [[String: Any]]
    ) throws -> Data {
        guard JSONSerialization.isValidJSONObject(objects) else {
            throw DockerLoggingBackendError.server(
                "Container Engine response is not JSON encodable"
            )
        }
        return try JSONSerialization.data(
            withJSONObject: objects,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
