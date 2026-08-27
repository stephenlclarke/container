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

import ContainerEngineRuntimeSPI
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

// MARK: - Collection capacity hints
// Dictionary(minimumCapacity:) and reserveCapacity() are used in this file to
// pre-allocate storage when the final collection size is known from the input.
// This avoids incremental reallocation overhead in hot-path parser methods.

public struct Utility {
    static let publishedPortCountLimit = 64

    enum NetworkSelection {
        case none
        case host
        case attachments([Parser.ParsedNetwork])
    }

    /// Run independent preparation operations as structured child tasks so a
    /// failure cancels and awaits the remaining work before returning.
    static func prepareConcurrently<A: Sendable, B: Sendable, C: Sendable>(
        _ first: @escaping @Sendable () async throws -> A,
        _ second: @escaping @Sendable () async throws -> B,
        _ third: @escaping @Sendable () async throws -> C
    ) async throws -> (A, B, C) {
        async let firstResult = first()
        async let secondResult = second()
        async let thirdResult = third()
        return try await (firstResult, secondResult, thirdResult)
    }

    /// Divide the user-visible download budget between the workload and init
    /// image pipelines. A budget of one keeps the image pulls serial while the
    /// independent kernel fetch can still overlap them.
    static func imageDownloadLimits(
        maxConcurrentDownloads: Int
    ) throws -> (workload: Int, initImage: Int?) {
        guard maxConcurrentDownloads > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "maximum number of concurrent downloads must be greater than 0, got \(maxConcurrentDownloads)"
            )
        }
        guard maxConcurrentDownloads > 1 else {
            return (workload: 1, initImage: nil)
        }
        return (
            workload: (maxConcurrentDownloads + 1) / 2,
            initImage: maxConcurrentDownloads / 2
        )
    }

    public static func createContainerID(name: String?) -> String {
        guard let name else {
            return UUID().uuidString.lowercased()
        }
        return name
    }

    /// Docker Engine exposes a stable 256-bit hexadecimal container identity
    /// that is distinct from the requested container name. Keep the native
    /// resource identifier unchanged and mint this protocol identity only for
    /// Docker-created containers.
    public static func createDockerContainerID() -> String {
        [UUID(), UUID()]
            .map { $0.uuidString.replacingOccurrences(of: "-", with: "") }
            .joined()
            .lowercased()
    }

    public static func imageReferenceAliases(
        _ reference: String,
        containerSystemConfig: ContainerSystemConfig
    ) throws -> Set<String> {
        let localReference = try Reference.parse(reference)
        localReference.normalize()
        return [
            reference,
            localReference.description,
            try ClientImage.normalizeReference(reference, containerSystemConfig: containerSystemConfig),
        ]
    }

    public static func isInfraImage(name: String, containerSystemConfig: ContainerSystemConfig) throws -> Bool {
        for infraImage in [containerSystemConfig.build.image, containerSystemConfig.vminit.image] {
            if try imageReferenceAliases(infraImage, containerSystemConfig: containerSystemConfig).contains(name) {
                return true
            }
        }
        return false
    }

    public static func trimDigest(digest: String) -> String {
        var hex = digest
        if let colonIndex = digest.firstIndex(of: ":") {
            hex = String(digest[digest.index(after: colonIndex)...])
        }
        return String(hex.prefix(12))
    }

    /// Projects an unpacked OCI image snapshot into a read-only container mount.
    static func imageMountFilesystem(parsed: ParsedImageMount, snapshot: Filesystem) throws -> Filesystem {
        guard snapshot.isBlock else {
            throw ContainerizationError(
                .invalidState,
                message: "image mount snapshot must be a block filesystem"
            )
        }
        var filesystem = snapshot
        filesystem.destination = parsed.destination
        filesystem.options = parsed.options
        if !filesystem.options.contains("ro") {
            filesystem.options.append("ro")
        }
        filesystem.sourceSubpath = parsed.subpath
        return filesystem
    }

    public static func validEntityName(_ name: String) throws {
        let pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#
        let regex = try Regex(pattern)
        if try regex.firstMatch(in: name) == nil {
            throw ContainerizationError(.invalidArgument, message: "invalid entity name \(name)")
        }
    }

    public static func validMACAddress(_ macAddress: String) throws {
        let pattern = #"^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$"#
        let regex = try Regex(pattern)
        if try regex.firstMatch(in: macAddress) == nil {
            throw ContainerizationError(.invalidArgument, message: "invalid MAC address format \(macAddress), expected format: XX:XX:XX:XX:XX:XX")
        }
    }

    public static func containerConfigFromFlags(
        id: String,
        image: String,
        arguments: [String],
        process: Flags.Process,
        management: Flags.Management,
        resource: Flags.Resource,
        registry: Flags.Registry,
        imageFetch: Flags.ImageFetch,
        loggingRequest: ContainerLogRequest? = nil,
        containerSystemConfig: ContainerSystemConfig,
        progressUpdate: ProgressUpdateHandler?,
        log: Logger
    ) async throws -> (ContainerConfiguration, Kernel, String?) {
        let requestedIsolation = try Parser.isolation(management.isolation)
        let requestedPlatform = try DefaultPlatform.resolveWithDefaults(
            platform: management.platform,
            os: management.os,
            arch: management.arch,
            log: log
        )
        try validateIsolationCompatibility(
            requestedIsolation: requestedIsolation,
            requestedPlatform: requestedPlatform,
            management: management
        )
        let resources = try Parser.resources(
            cpus: resource.cpus,
            memory: resource.memory,
            cpuPeriod: resource.cpuPeriod,
            cpuQuota: resource.cpuQuota,
            cpuSet: resource.cpuSet,
            memoryReclaimFloor: resource.memoryReclaimFloor,
            memoryReclaimHeadroom: resource.memoryReclaimHeadroom,
            memoryReclaimHysteresis: resource.memoryReclaimHysteresis,
            memoryReclaimInterval: resource.memoryReclaimInterval,
            memoryReclaimCooldown: resource.memoryReclaimCooldown,
            defaultCPUs: containerSystemConfig.container.cpus,
            defaultMemory: containerSystemConfig.container.memory
        )
        if requestedIsolation == .sharedVM,
            resources.adaptiveMemoryReclamation != nil
        {
            throw ContainerizationError(
                .unsupported,
                message: "adaptive memory reclamation requires --isolation dedicated-vm"
            )
        }
        let scheme = try RequestScheme(registry.scheme)
        let imageDownloadLimits = try imageDownloadLimits(
            maxConcurrentDownloads: imageFetch.maxConcurrentDownloads
        )
        let kernelPath = management.kernel
        let kernelArguments = management.kernelArgs

        // Each image pipeline needs its own coordinator: one pipeline moving
        // to its unpack phase must not suppress progress from the other.
        let imageTaskManager = ProgressTaskCoordinator()
        let initTaskManager = ProgressTaskCoordinator()
        let mountTaskManager = ProgressTaskCoordinator()
        let initImageRef = management.initImage ?? containerSystemConfig.vminit.image
        let prepareInitImage: @Sendable (Int) async throws -> Void = { downloadLimit in
            await progressUpdate?([
                .setDescription("Fetching init image"),
                .setItemsName("blobs"),
            ])
            let fetchTask = await initTaskManager.startTask()
            let initImage = try await ClientImage.fetch(
                reference: initImageRef,
                platform: .current,
                scheme: scheme,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: progressUpdate.map {
                    ProgressTaskCoordinator.handler(for: fetchTask, from: $0)
                },
                maxConcurrentDownloads: downloadLimit
            )

            await progressUpdate?([
                .setDescription("Unpacking init image"),
                .setItemsName("entries"),
            ])
            let unpackTask = await initTaskManager.startTask()
            try await initImage.getCreateSnapshot(
                platform: .current,
                progressUpdate: progressUpdate.map {
                    ProgressTaskCoordinator.handler(for: unpackTask, from: $0)
                }
            )
            await initTaskManager.finish()
        }
        let (img, kernel, _) = try await prepareConcurrently(
            {
                await progressUpdate?([
                    .setDescription("Fetching image"),
                    .setItemsName("blobs"),
                ])
                let fetchTask = await imageTaskManager.startTask()
                let workloadImage = try await ClientImage.fetch(
                    reference: image,
                    platform: requestedPlatform,
                    scheme: scheme,
                    containerSystemConfig: containerSystemConfig,
                    progressUpdate: progressUpdate.map {
                        ProgressTaskCoordinator.handler(for: fetchTask, from: $0)
                    },
                    maxConcurrentDownloads: imageDownloadLimits.workload
                )

                await progressUpdate?([
                    .setDescription("Unpacking image"),
                    .setItemsName("entries"),
                ])
                let unpackTask = await imageTaskManager.startTask()
                try await workloadImage.getCreateSnapshot(
                    platform: requestedPlatform,
                    progressUpdate: progressUpdate.map {
                        ProgressTaskCoordinator.handler(for: unpackTask, from: $0)
                    }
                )
                await imageTaskManager.finish()
                return workloadImage
            },
            {
                await progressUpdate?([
                    .setDescription("Fetching kernel"),
                    .setItemsName("binary"),
                ])
                return try await self.getKernel(path: kernelPath, arguments: kernelArguments)
            },
            {
                guard let initImageDownloadLimit = imageDownloadLimits.initImage else {
                    return
                }
                try await prepareInitImage(initImageDownloadLimit)
            }
        )
        if imageDownloadLimits.initImage == nil {
            try await prepareInitImage(imageDownloadLimits.workload)
        }

        let imageConfig = try await img.config(for: requestedPlatform).config
        let description = img.description
        let pc = try Parser.process(
            arguments: arguments,
            processFlags: process,
            managementFlags: management,
            config: imageConfig
        )
        try validateSharedProcessCompatibility(
            requestedIsolation: requestedIsolation,
            process: pc
        )

        var config = ContainerConfiguration(id: id, image: description, process: pc)
        config.platform = requestedPlatform
        config.requestedIsolation = requestedIsolation
        config.effectiveIsolation = requestedIsolation ?? .dedicatedVM
        config.sandboxID =
            requestedIsolation == .sharedVM
            ? "engine-linux-sandbox" : nil

        config.resources = resources
        config.logging = try Self.loggingConfiguration(
            request: loggingRequest,
            legacyDriver: management.logDriver,
            legacyOptions: management.logOpt
        )
        config.healthCheck = try Parser.healthCheck(
            command: management.healthCommand,
            interval: management.healthInterval,
            retries: management.healthRetries,
            startInterval: management.healthStartInterval,
            startPeriod: management.healthStartPeriod,
            timeout: management.healthTimeout,
            disabled: management.noHealthCheck,
            baseProcess: pc
        )
        if requestedIsolation == .sharedVM, config.healthCheck != nil {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not yet support health checks"
            )
        }

        let tmpfs = try Parser.tmpfsMounts(management.tmpFs)
        let volumesOrFs = try Parser.volumes(management.volumes)
        let mountsOrFs = try Parser.mounts(management.mounts)

        var resolvedMounts: [Filesystem] = []
        resolvedMounts.append(contentsOf: tmpfs)

        // Resolve volumes and filesystems
        for item in (volumesOrFs + mountsOrFs) {
            switch item {
            case .filesystem(let fs):
                resolvedMounts.append(fs)
            case .volume(let parsed):
                let volume = try await getOrCreateVolume(parsed: parsed, log: log)
                let volumeMount = Filesystem.volume(
                    name: parsed.name,
                    format: volume.format,
                    source: volume.source,
                    destination: parsed.destination,
                    options: parsed.options,
                    subpath: parsed.subpath
                )
                resolvedMounts.append(volumeMount)
            case .image(let parsed):
                let mountedImage = try await ClientImage.get(
                    reference: parsed.reference,
                    containerSystemConfig: containerSystemConfig
                )
                await progressUpdate?([
                    .setDescription("Unpacking image mount"),
                    .setItemsName("entries"),
                ])
                let mountTask = await mountTaskManager.startTask()
                let mountProgressUpdate = progressUpdate.map {
                    ProgressTaskCoordinator.handler(for: mountTask, from: $0)
                }
                let snapshot = try await mountedImage.getCreateSnapshot(
                    platform: requestedPlatform,
                    progressUpdate: mountProgressUpdate
                )
                resolvedMounts.append(try imageMountFilesystem(parsed: parsed, snapshot: snapshot))
            }
        }

        await mountTaskManager.finish()

        config.mounts = resolvedMounts

        if let shmSizeStr = management.shmSize {
            let measurement = try Measurement.parse(parsing: shmSizeStr)
            let bytes = measurement.converted(to: .bytes)
            config.shmSize = UInt64(bytes.value)
        }

        config.virtualization = management.virtualization
        config.sysctls = try Parser.sysctls(management.sysctls)

        switch try networkSelection(management.networks) {
        case .none:
            config.networks = []
        case .host:
            let networkClient = NetworkClient()
            let builtinNetworkId = try await networkClient.builtin?.id
            config.hostNetwork = true
            config.networks = try getAttachmentConfigurations(
                containerId: config.id,
                builtinNetworkId: builtinNetworkId,
                networks: [],
                dnsDomain: containerSystemConfig.dns.domain,
            )
            for attachmentConfiguration in config.networks {
                _ = try await networkClient.get(id: attachmentConfiguration.network)
            }
        case .attachments(let parsedNetworks):
            let networkClient = NetworkClient()
            let availableNetworks = try await networkClient.list()
            let builtinNetworkId = availableNetworks.first(where: \.isBuiltin)?.id
            config.networks = try getAttachmentConfigurations(
                containerId: config.id,
                builtinNetworkId: builtinNetworkId,
                networks: parsedNetworks,
                dnsDomain: containerSystemConfig.dns.domain,
            )
            try validateNetworkAttachments(
                config.networks,
                availableNetworkIDs: Set(availableNetworks.map(\.id))
            )
        }

        if management.dnsDisabled {
            config.dns = nil
        } else {
            let domain = management.dns.domain ?? containerSystemConfig.dns.domain
            config.dns = .init(
                nameservers: management.dns.nameservers,
                domain: domain,
                searchDomains: management.dns.searchDomains,
                options: management.dns.options
            )
        }
        config.hosts = try Parser.hostEntries(management.addHost)

        config.rosetta = management.rosetta || (Platform.current.architecture == "arm64" && requestedPlatform.architecture == "amd64")

        if management.rosetta && Platform.current.architecture != "arm64" {
            throw ContainerizationError(.unsupported, message: "--rosetta flag requires an arm64 host")
        }

        config.labels = try Parser.labels(management.labels)
        config.annotations = try Parser.labels(management.annotations)
        config.hostname = try Parser.hostname(management.hostname)
        config.domainname = try Parser.hostname(management.domainname, option: "--domainname")

        config.publishedPorts = try Parser.publishPorts(management.publishPorts)
        guard config.publishedPorts.count <= publishedPortCountLimit else {
            throw ContainerizationError(.invalidArgument, message: "cannot exceed more than \(publishedPortCountLimit) port publish descriptors")
        }
        guard !config.publishedPorts.hasOverlaps() else {
            throw ContainerizationError(.invalidArgument, message: "host ports for different publish port specs may not overlap")
        }
        config.exposedPorts = try Parser.exposedPorts(management.exposedPorts)

        // Parse --publish-socket arguments and add to container configuration
        // to enable socket forwarding from container to host.
        config.publishedSockets = try Parser.publishSockets(management.publishSockets)

        config.ssh = management.ssh
        config.inboundSockets = management.engineAPISocket ? [try .engineAPI()] : []
        config.readOnly = management.readOnly
        config.useInit = management.useInit
        config.hostPIDNamespace = try Parser.hostPIDNamespace(management.pid)
        config.hostCgroupNamespace = try Parser.hostCgroupNamespace(management.cgroupNamespace)
        config.hostIPCNamespace = try Parser.hostIPCNamespace(management.ipc)
        config.hostUTSNamespace = try Parser.hostUTSNamespace(management.uts)
        let privateUserNamespace = try Parser.privateUserNamespace(
            management.userNamespace
        )
        config.privateUserNamespace =
            requestedIsolation == .sharedVM
            ? true : privateUserNamespace
        config.unconfinedSystemPaths = try Parser.unconfinedSystemPaths(management.securityOpts)

        let caps = try Parser.capabilities(capAdd: management.capAdd, capDrop: management.capDrop)
        config.capAdd = caps.capAdd
        config.capDrop = caps.capDrop
        config.maskedPaths = try Parser.maskedPaths(management.maskedPaths)
        config.readonlyPaths = try Parser.readonlyPaths(management.readonlyPaths)
        config.stopSignal = management.stopSignal ?? imageConfig?.stopSignal
        config.stopTimeoutInSeconds = management.stopTimeout

        if let runtime = management.runtime {
            config.runtimeHandler = runtime
        }

        return (config, kernel, management.initImage)
    }

    /// The first shared-VM vertical deliberately admits only configurations
    /// whose isolation can be enforced by the existing LinuxPod mapper. Reject
    /// unsupported VM-wide settings before image or kernel preparation begins.
    static func validateIsolationCompatibility(
        requestedIsolation: ContainerIsolationMode?,
        requestedPlatform: Platform,
        management: Flags.Management
    ) throws {
        guard requestedIsolation == .sharedVM else {
            return
        }

        guard
            management.networks == [NetworkClient.hostNetworkName]
                || management.networks == [NetworkClient.noNetworkName]
        else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm currently requires --network host or --network none"
            )
        }
        guard management.kernel == nil, management.kernelArgs.isEmpty, management.initImage == nil else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not support custom kernel or init VM assets"
            )
        }
        guard !management.virtualization, management.devices.isEmpty, management.gpus.isEmpty else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not support VM-wide virtualization or device options"
            )
        }
        guard management.deviceCgroupRules.isEmpty else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not support device cgroup overrides"
            )
        }
        guard management.publishPorts.isEmpty else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not yet support published TCP or UDP ports"
            )
        }
        guard management.pid != "host",
            management.cgroupNamespace != "host",
            management.ipc != "host",
            management.uts != "host",
            management.userNamespace != "host"
        else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm requires private PID, cgroup, IPC, UTS, and user namespaces"
            )
        }
        guard try !Parser.unconfinedSystemPaths(management.securityOpts) else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not support unconfined system paths"
            )
        }
        guard management.runtime == nil || management.runtime == "container-runtime-linux" else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm requires the container-runtime-linux runtime"
            )
        }
        guard requestedPlatform.os == Platform.current.os,
            requestedPlatform.architecture == Platform.current.architecture,
            !management.rosetta
        else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm currently requires the native Linux platform"
            )
        }
    }

    static func validateSharedProcessCompatibility(
        requestedIsolation: ContainerIsolationMode?,
        process: ProcessConfiguration
    ) throws {
        guard requestedIsolation == .sharedVM else {
            return
        }
        guard !process.privileged else {
            throw ContainerizationError(
                .unsupported,
                message: "--isolation shared-vm does not support privileged workloads"
            )
        }
    }

    /// Keeps the legacy configuration field readable for old API callers
    /// while ensuring a present v2 request remains the sole authority input.
    static func loggingConfiguration(
        request: ContainerLogRequest?,
        legacyDriver: String?,
        legacyOptions: [String]
    ) throws -> ContainerLogConfiguration {
        guard request == nil else {
            return .default
        }
        return try Parser.logging(driver: legacyDriver, options: legacyOptions)
    }

    static func getAttachmentConfigurations(
        containerId: String,
        builtinNetworkId: String?,
        networks: [Parser.ParsedNetwork],
        dnsDomain: String?,
    ) throws -> [AttachmentConfiguration] {
        // Validate MAC addresses if provided
        for network in networks {
            if let mac = network.macAddress {
                try validMACAddress(mac)
            }
        }
        var scopedDNSAliases: [String: String] = [:]
        for network in networks {
            for (alias, target) in network.scopedDNSAliases {
                if let existing = scopedDNSAliases[alias] {
                    guard existing.caseInsensitiveCompare(target) == .orderedSame else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "network DNS alias '\(alias)' maps to both '\(existing)' and '\(target)'"
                        )
                    }
                    continue
                }
                scopedDNSAliases[alias] = target
            }
        }

        // make an FQDN for the first interface
        let fqdn: String?
        if !containerId.contains(".") {
            // add default domain if it exists, and container ID is unqualified
            if let dnsDomain {
                fqdn = "\(containerId).\(dnsDomain)."
            } else {
                fqdn = nil
            }
        } else {
            // use container ID directly if fully qualified
            fqdn = "\(containerId)."
        }

        guard networks.isEmpty else {
            // Check if this is only the default network with properties (e.g., MAC address)
            let isOnlyDefaultNetwork = networks.count == 1 && networks[0].name == builtinNetworkId

            // networks may only be specified for macOS 26+ (except for default network with properties)
            if !isOnlyDefaultNetwork {
                guard #available(macOS 26, *) else {
                    throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
                }
            }

            // attach the first network using the fqdn, and the rest using just the container ID
            return try networks.enumerated().map { item in
                let macAddress = try item.element.macAddress.map { try MACAddress($0) }
                let mtu = item.element.mtu ?? 1280
                guard item.offset == 0 else {
                    return AttachmentConfiguration(
                        network: item.element.name,
                        options: AttachmentOptions(
                            hostname: containerId,
                            aliases: item.element.aliases,
                            scopedDNSAliases: item.element.scopedDNSAliases,
                            macAddress: macAddress,
                            mtu: mtu,
                            guestInterfaceName: item.element.guestInterfaceName,
                            additionalIPAddresses: item.element.additionalIPAddresses,
                            requestedIPv4Address: item.element.requestedIPv4Address,
                            requestedIPv6Address: item.element.requestedIPv6Address
                        )
                    )
                }
                return AttachmentConfiguration(
                    network: item.element.name,
                    options: AttachmentOptions(
                        hostname: fqdn ?? containerId,
                        aliases: item.element.aliases,
                        scopedDNSAliases: item.element.scopedDNSAliases,
                        macAddress: macAddress,
                        mtu: mtu,
                        guestInterfaceName: item.element.guestInterfaceName,
                        additionalIPAddresses: item.element.additionalIPAddresses,
                        requestedIPv4Address: item.element.requestedIPv4Address,
                        requestedIPv6Address: item.element.requestedIPv6Address
                    )
                )
            }
        }

        // if no networks specified, attach to the default network
        guard let builtinNetworkId else {
            throw ContainerizationError(.invalidState, message: "builtin network is not present")
        }
        return [AttachmentConfiguration(network: builtinNetworkId, options: AttachmentOptions(hostname: fqdn ?? containerId, macAddress: nil, mtu: 1280))]
    }

    static func networkSelection(_ networks: [String]) throws -> NetworkSelection {
        let usesHostNetwork = try Parser.hostNetwork(networks)
        let usesNoNetwork = networks.contains(NetworkClient.noNetworkName)
        let usesQualifiedNoNetwork = networks.contains { $0.hasPrefix("\(NetworkClient.noNetworkName),") }
        if usesQualifiedNoNetwork {
            throw ContainerizationError(.invalidArgument, message: "--network none does not accept attachment properties")
        }
        if usesHostNetwork && usesNoNetwork {
            throw ContainerizationError(.unsupported, message: "networks \(NetworkClient.hostNetworkName) and \(NetworkClient.noNetworkName) cannot be combined")
        }
        if usesHostNetwork && networks.count != 1 {
            throw ContainerizationError(.unsupported, message: "no other networks may be created along with network \(NetworkClient.hostNetworkName)")
        }
        if usesNoNetwork && networks.count != 1 {
            throw ContainerizationError(.unsupported, message: "no other networks may be created along with network \(NetworkClient.noNetworkName)")
        }
        if usesNoNetwork {
            return .none
        }
        if usesHostNetwork {
            return .host
        }
        return .attachments(try networks.map { try Parser.network($0) })
    }

    static func validateNetworkAttachments(
        _ attachments: [AttachmentConfiguration],
        availableNetworkIDs: Set<String>
    ) throws {
        for attachment in attachments where !availableNetworkIDs.contains(attachment.network) {
            throw ContainerizationError(.notFound, message: "network \(attachment.network) not found")
        }
    }

    private static func getKernel(path: String?, arguments: [String]) async throws -> Kernel {
        // For the image itself we'll take the user input and try with it as we can do userspace
        // emulation for x86, but for the kernel we need it to match the hosts architecture.
        let s: SystemPlatform = .current
        var kernel: Kernel
        if let userKernel = path {
            guard FileManager.default.fileExists(atPath: userKernel) else {
                throw ContainerizationError(.notFound, message: "kernel file not found at path \(userKernel)")
            }
            let p = URL(filePath: userKernel)
            kernel = .init(path: p, platform: s)
        } else {
            kernel = try await ClientKernel.getDefaultKernel(for: s)
        }
        // Persist any user-supplied boot args onto the kernel command line. A key supplied
        // here overrides the runtime's matching built-in default (see RuntimeService.bootstrap).
        kernel.commandLine.kernelArgs.append(contentsOf: arguments)
        return kernel
    }

    /// Parses key-value pairs from command line arguments.
    ///
    /// Supports formats like "key=value" and standalone keys (treated as "key=").
    /// - Parameter pairs: Array of strings in "key=value" format
    /// - Returns: Dictionary mapping keys to values
    public static func parseKeyValuePairs(_ pairs: [String]) -> [String: String] {
        var result: [String: String] = Dictionary(minimumCapacity: pairs.count)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2 {
                result[String(components[0])] = String(components[1])
            } else {
                result[pair] = ""
            }
        }
        return result
    }

    /// Gets an existing volume or creates it if it doesn't exist.
    /// Shows a warning for named volumes when auto-creating.
    private static func getOrCreateVolume(parsed: ParsedVolume, log: Logger) async throws -> VolumeConfiguration {
        let labels = parsed.isAnonymous ? [VolumeConfiguration.anonymousLabel: ""] : [:]

        let volume: VolumeConfiguration
        var wasCreated = false
        do {
            volume = try await ClientVolume.create(
                name: parsed.name,
                driver: "local",
                driverOpts: [:],
                labels: labels
            )
            wasCreated = true
        } catch let error as VolumeError {
            guard case .volumeAlreadyExists = error else {
                throw error
            }
            // Volume already exists, just inspect it
            volume = try await ClientVolume.inspect(parsed.name)
        } catch let error as ContainerizationError {
            // Handle XPC-wrapped volumeAlreadyExists error
            guard error.message.contains("already exists") else {
                throw error
            }
            volume = try await ClientVolume.inspect(parsed.name)
        }

        if wasCreated && !parsed.isAnonymous {
            log.warning("named volume was automatically created", metadata: ["volume": "\(parsed.name)"])
        }

        return volume
    }
}
