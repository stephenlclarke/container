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
import ContainerizationOCI
import Foundation

public struct ContainerConfiguration: Sendable, Codable {
    /// Identifier for the container.
    public var id: String
    /// Canonical Docker Engine identifier when this container was created
    /// through the Docker-compatible API. Native containers leave this unset.
    public var dockerID: String?
    /// Docker-visible container name when this container was created through
    /// the Docker-compatible API. Native containers leave this unset.
    public var dockerName: String?
    /// Image used to create the container.
    public var image: ImageDescription
    /// External mounts to add to the container.
    public var mounts: [Filesystem] = []
    /// Ports to publish from container to host.
    public var publishedPorts: [PublishPort] = []
    /// Ports exposed as container metadata without publishing them to the host.
    public var exposedPorts: [String] = []
    /// Sockets to publish from container to host.
    public var publishedSockets: [PublishSocket] = []
    /// Authority-owned sockets to project into the container at start.
    ///
    /// Durable intent contains only canonical guest-visible paths. The selected
    /// authority resolves its private host broker immediately before activation.
    public var inboundSockets: [InboundUnixSocketIntentV1] = []
    /// Key/Value labels for the container.
    public var labels: [String: String] = [:]
    /// OCI annotations for the container runtime specification.
    public var annotations: [String: String] = [:]
    /// System controls for the container.
    public var sysctls: [String: String] = [:]
    /// The networks the container will be added to.
    public var networks: [AttachmentConfiguration] = []
    /// Optional hostname visible inside the container's UTS namespace.
    public var hostname: String?
    /// Optional NIS domain name visible inside the container's UTS namespace.
    public var domainname: String?
    /// The DNS configuration for the container.
    public var dns: DNSConfiguration? = nil
    /// Additional entries to append to the container's /etc/hosts file.
    public var hosts: [HostEntry] = []
    /// Whether to enable rosetta x86-64 translation for the container.
    public var rosetta: Bool = false
    /// Initial or main process of the container.
    public var initProcess: ProcessConfiguration
    /// Platform for the container.
    public var platform: ContainerizationOCI.Platform = .current
    /// Resource values for the container.
    public var resources: Resources = .init()
    /// Logging policy for captured container stdio.
    public var logging: ContainerLogConfiguration = .default
    /// Optional health probe configuration for the running container.
    public var healthCheck: ContainerHealthCheck?
    /// Name of the runtime that supports the container.
    public var runtimeHandler: String = "container-runtime-linux"
    /// Isolation explicitly requested by the caller. Nil preserves omission
    /// separately from the effective compatibility default.
    public var requestedIsolation: ContainerIsolationMode?
    /// Isolation selected by the engine after validating the request.
    public var effectiveIsolation: ContainerIsolationMode = .dedicatedVM
    /// Stable authority-owned sandbox identity when the selected isolation
    /// places this container in a shared virtual machine.
    public var sandboxID: String?
    /// Configure exposing virtualization support in the container.
    public var virtualization: Bool = false
    /// Enable SSH agent socket forwarding from host to container.
    public var ssh: Bool = false
    /// Whether to mount the rootfs as read-only.
    public var readOnly: Bool = false
    /// Whether the container was requested with host network mode.
    public var hostNetwork: Bool = false
    /// Whether to use a minimal init process inside the container.
    public var useInit: Bool = false
    /// Whether to run the init process in the sandbox VM PID namespace.
    public var hostPIDNamespace: Bool = false
    /// Whether to run the container in the sandbox VM cgroup namespace.
    public var hostCgroupNamespace: Bool = false
    /// Whether to run the container in the sandbox VM IPC namespace.
    public var hostIPCNamespace: Bool = false
    /// Whether to run the container in the sandbox VM UTS namespace.
    public var hostUTSNamespace: Bool = false
    /// Whether to create a private user namespace inside the sandbox VM.
    public var privateUserNamespace: Bool = false
    /// Whether to disable the default masked and read-only paths in the Linux guest.
    public var unconfinedSystemPaths: Bool = false
    /// Linux capabilities to add (normalized CAP_* strings, or "ALL").
    public var capAdd: [String] = []
    /// Linux capabilities to drop (normalized CAP_* strings, or "ALL").
    public var capDrop: [String] = []
    /// Size of /dev/shm in bytes. When nil, the default size is used.
    public var shmSize: UInt64?
    /// Signal to send to the container process on stop.
    public var stopSignal: String?
    /// Paths inside the container to hide from the workload. When nil, the
    /// runtime's default set is used. Set to `[]` to opt out, or provide a
    /// custom list to override the default entirely.
    public var maskedPaths: [String]?
    /// Paths inside the container to mark read-only. When nil, the runtime's
    /// default set is used. Set to `[]` to opt out, or provide a custom list
    /// to override the default entirely.
    public var readonlyPaths: [String]?
    /// Seconds to wait for a graceful stop before forcing termination.
    public var stopTimeoutInSeconds: Int32?
    /// The time at which the container was created.
    public var creationDate: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id
        case dockerID
        case dockerName
        case image
        case mounts
        case publishedPorts
        case exposedPorts
        case publishedSockets
        case inboundSockets
        case labels
        case annotations
        case sysctls
        case networks
        case hostname
        case domainname
        case dns
        case hosts
        case rosetta
        case initProcess
        case platform
        case resources
        case logging
        case healthCheck
        case runtimeHandler
        case requestedIsolation
        case effectiveIsolation
        case sandboxID
        case virtualization
        case ssh
        case readOnly
        case hostNetwork
        case useInit
        case hostPIDNamespace
        case hostCgroupNamespace
        case hostIPCNamespace
        case hostUTSNamespace
        case privateUserNamespace
        case unconfinedSystemPaths
        case capAdd
        case capDrop
        case shmSize
        case stopSignal
        case maskedPaths
        case readonlyPaths
        case stopTimeoutInSeconds
        case creationDate
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        dockerID = try container.decodeIfPresent(String.self, forKey: .dockerID)
        dockerName = try container.decodeIfPresent(String.self, forKey: .dockerName)
        image = try container.decode(ImageDescription.self, forKey: .image)
        mounts = try container.decodeIfPresent([Filesystem].self, forKey: .mounts) ?? []
        publishedPorts = try container.decodeIfPresent([PublishPort].self, forKey: .publishedPorts) ?? []
        exposedPorts = try container.decodeIfPresent([String].self, forKey: .exposedPorts) ?? []
        publishedSockets = try container.decodeIfPresent([PublishSocket].self, forKey: .publishedSockets) ?? []
        inboundSockets = try container.decodeIfPresent([InboundUnixSocketIntentV1].self, forKey: .inboundSockets) ?? []
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
        sysctls = try container.decodeIfPresent([String: String].self, forKey: .sysctls) ?? [:]

        if container.contains(.networks) {
            networks = try container.decode([AttachmentConfiguration].self, forKey: .networks)
        } else {
            networks = []
        }

        dns = try container.decodeIfPresent(DNSConfiguration.self, forKey: .dns)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        domainname = try container.decodeIfPresent(String.self, forKey: .domainname)
        hosts = try container.decodeIfPresent([HostEntry].self, forKey: .hosts) ?? []
        rosetta = try container.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        initProcess = try container.decode(ProcessConfiguration.self, forKey: .initProcess)
        platform = try container.decodeIfPresent(ContainerizationOCI.Platform.self, forKey: .platform) ?? .current
        resources = try container.decodeIfPresent(Resources.self, forKey: .resources) ?? .init()
        logging = try container.decodeIfPresent(ContainerLogConfiguration.self, forKey: .logging) ?? .default
        healthCheck = try container.decodeIfPresent(ContainerHealthCheck.self, forKey: .healthCheck)
        runtimeHandler = try container.decodeIfPresent(String.self, forKey: .runtimeHandler) ?? "container-runtime-linux"
        requestedIsolation = try container.decodeIfPresent(ContainerIsolationMode.self, forKey: .requestedIsolation)
        effectiveIsolation = try container.decodeIfPresent(ContainerIsolationMode.self, forKey: .effectiveIsolation) ?? .dedicatedVM
        sandboxID = try container.decodeIfPresent(String.self, forKey: .sandboxID)
        virtualization = try container.decodeIfPresent(Bool.self, forKey: .virtualization) ?? false
        ssh = try container.decodeIfPresent(Bool.self, forKey: .ssh) ?? false
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        hostNetwork = try container.decodeIfPresent(Bool.self, forKey: .hostNetwork) ?? false
        useInit = try container.decodeIfPresent(Bool.self, forKey: .useInit) ?? false
        hostPIDNamespace = try container.decodeIfPresent(Bool.self, forKey: .hostPIDNamespace) ?? false
        hostCgroupNamespace = try container.decodeIfPresent(Bool.self, forKey: .hostCgroupNamespace) ?? false
        hostIPCNamespace = try container.decodeIfPresent(Bool.self, forKey: .hostIPCNamespace) ?? false
        hostUTSNamespace = try container.decodeIfPresent(Bool.self, forKey: .hostUTSNamespace) ?? false
        privateUserNamespace = try container.decodeIfPresent(Bool.self, forKey: .privateUserNamespace) ?? false
        unconfinedSystemPaths = try container.decodeIfPresent(Bool.self, forKey: .unconfinedSystemPaths) ?? false
        capAdd = try container.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        capDrop = try container.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        shmSize = try container.decodeIfPresent(UInt64.self, forKey: .shmSize)
        stopSignal = try container.decodeIfPresent(String.self, forKey: .stopSignal)
        maskedPaths = try container.decodeIfPresent([String].self, forKey: .maskedPaths)
        readonlyPaths = try container.decodeIfPresent([String].self, forKey: .readonlyPaths)
        stopTimeoutInSeconds = try container.decodeIfPresent(Int32.self, forKey: .stopTimeoutInSeconds)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: any Encoder) throws {
        try encode(to: encoder, logging: logging)
    }

    /// Redaction-safe view used by routine native inspection surfaces.
    public var routineInspection: RoutineInspectionProjection {
        RoutineInspectionProjection(configuration: self)
    }

    public struct RoutineInspectionProjection: Encodable, Sendable {
        private let configuration: ContainerConfiguration

        fileprivate init(configuration: ContainerConfiguration) {
            self.configuration = configuration
        }

        public func encode(to encoder: any Encoder) throws {
            try configuration.encode(
                to: encoder,
                logging: configuration.logging.routineInspection
            )
        }
    }

    private func encode<Logging: Encodable>(
        to encoder: any Encoder,
        logging: Logging
    ) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(dockerID, forKey: .dockerID)
        try container.encodeIfPresent(dockerName, forKey: .dockerName)
        try container.encode(image, forKey: .image)
        try container.encode(mounts, forKey: .mounts)
        try container.encode(publishedPorts, forKey: .publishedPorts)
        try container.encode(exposedPorts, forKey: .exposedPorts)
        try container.encode(publishedSockets, forKey: .publishedSockets)
        try container.encode(inboundSockets, forKey: .inboundSockets)
        try container.encode(labels, forKey: .labels)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(sysctls, forKey: .sysctls)
        try container.encode(networks, forKey: .networks)
        try container.encodeIfPresent(hostname, forKey: .hostname)
        try container.encodeIfPresent(domainname, forKey: .domainname)
        try container.encodeIfPresent(dns, forKey: .dns)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(rosetta, forKey: .rosetta)
        try container.encode(initProcess, forKey: .initProcess)
        try container.encode(platform, forKey: .platform)
        try container.encode(resources, forKey: .resources)
        try container.encode(logging, forKey: .logging)
        try container.encodeIfPresent(healthCheck, forKey: .healthCheck)
        try container.encode(runtimeHandler, forKey: .runtimeHandler)
        try container.encodeIfPresent(requestedIsolation, forKey: .requestedIsolation)
        try container.encode(effectiveIsolation, forKey: .effectiveIsolation)
        try container.encodeIfPresent(sandboxID, forKey: .sandboxID)
        try container.encode(virtualization, forKey: .virtualization)
        try container.encode(ssh, forKey: .ssh)
        try container.encode(readOnly, forKey: .readOnly)
        try container.encode(hostNetwork, forKey: .hostNetwork)
        try container.encode(useInit, forKey: .useInit)
        try container.encode(hostPIDNamespace, forKey: .hostPIDNamespace)
        try container.encode(hostCgroupNamespace, forKey: .hostCgroupNamespace)
        try container.encode(hostIPCNamespace, forKey: .hostIPCNamespace)
        try container.encode(hostUTSNamespace, forKey: .hostUTSNamespace)
        try container.encode(privateUserNamespace, forKey: .privateUserNamespace)
        try container.encode(unconfinedSystemPaths, forKey: .unconfinedSystemPaths)
        try container.encode(capAdd, forKey: .capAdd)
        try container.encode(capDrop, forKey: .capDrop)
        try container.encodeIfPresent(shmSize, forKey: .shmSize)
        try container.encodeIfPresent(stopSignal, forKey: .stopSignal)
        try container.encodeIfPresent(maskedPaths, forKey: .maskedPaths)
        try container.encodeIfPresent(readonlyPaths, forKey: .readonlyPaths)
        try container.encodeIfPresent(stopTimeoutInSeconds, forKey: .stopTimeoutInSeconds)
        try container.encode(creationDate, forKey: .creationDate)
    }

    public struct DNSConfiguration: Sendable, Codable {
        public static let defaultNameservers = ["1.1.1.1"]

        public let nameservers: [String]
        public let domain: String?
        public let searchDomains: [String]
        public let options: [String]

        public init(
            nameservers: [String] = defaultNameservers,
            domain: String? = nil,
            searchDomains: [String] = [],
            options: [String] = []
        ) {
            self.nameservers = nameservers
            self.domain = domain
            self.searchDomains = searchDomains
            self.options = options
        }
    }

    /// Host mapping appended to /etc/hosts before the container starts.
    public struct HostEntry: Sendable, Codable, Equatable {
        /// Magic value resolved to the first network gateway when the container starts.
        public static let hostGatewayAddress = "host-gateway"

        /// IP address, or `host-gateway`, written as the first field in the hosts entry.
        public let ipAddress: String
        /// One or more hostnames written after the address.
        public let hostnames: [String]

        /// Whether this entry should resolve to the first network gateway at runtime.
        public var requiresHostGateway: Bool {
            ipAddress == Self.hostGatewayAddress
        }

        public init(ipAddress: String, hostnames: [String]) {
            self.ipAddress = ipAddress
            self.hostnames = hostnames
        }
    }

    /// Resources like cpu, memory, and storage quota.
    public struct Resources: Sendable, Codable {
        /// Number of CPU cores allocated.
        public var cpus: Int = 4
        /// Optional CFS CPU quota in microseconds. When set, this can express
        /// a fractional CPU limit while `cpus` remains the integral VM vCPU
        /// allocation.
        public var cpuQuotaInMicroseconds: Int64?
        /// Optional CFS CPU period in microseconds for the container cgroup.
        public var cpuPeriodInMicroseconds: UInt64?
        /// Optional Linux CPU set applied to the container cgroup.
        public var cpuSet: String?
        /// Memory in bytes allocated.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// Optional live workload-memory target. This does not change the
        /// configured boot-time maximum in `memoryInBytes`.
        public var memoryTargetInBytes: UInt64?
        /// Storage quota/size in bytes.
        public var storage: UInt64?
        /// Additional CPU cores allocated for VM overhead (guest agent, etc).
        public var cpuOverhead: Int = 1

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 4
            self.cpuQuotaInMicroseconds = try c.decodeIfPresent(Int64.self, forKey: .cpuQuotaInMicroseconds)
            self.cpuPeriodInMicroseconds = try c.decodeIfPresent(UInt64.self, forKey: .cpuPeriodInMicroseconds)
            self.cpuSet = try c.decodeIfPresent(String.self, forKey: .cpuSet)
            self.memoryInBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryInBytes) ?? 1024.mib()
            self.memoryTargetInBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryTargetInBytes)
            self.storage = try c.decodeIfPresent(UInt64.self, forKey: .storage)
            self.cpuOverhead = try c.decodeIfPresent(Int.self, forKey: .cpuOverhead) ?? 1
        }
    }

    public init(
        id: String,
        image: ImageDescription,
        process: ProcessConfiguration
    ) {
        self.id = id
        self.image = image
        self.initProcess = process
    }
}
