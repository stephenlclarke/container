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

import ContainerizationOCI
import Foundation

public struct ContainerConfiguration: Sendable, Codable {
    /// Identifier for the container.
    public var id: String
    /// Image used to create the container.
    public var image: ImageDescription
    /// External mounts to add to the container.
    public var mounts: [Filesystem] = []
    /// Ports to publish from container to host.
    public var publishedPorts: [PublishPort] = []
    /// Sockets to publish from container to host.
    public var publishedSockets: [PublishSocket] = []
    /// Key/Value labels for the container.
    public var labels: [String: String] = [:]
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
    /// Linux capabilities to add (normalized CAP_* strings, or "ALL").
    public var capAdd: [String] = []
    /// Linux capabilities to drop (normalized CAP_* strings, or "ALL").
    public var capDrop: [String] = []
    /// Size of /dev/shm in bytes. When nil, the default size is used.
    public var shmSize: UInt64?
    /// Signal to send to the container process on stop (from image config).
    public var stopSignal: String?
    /// The time at which the container was created.
    public var creationDate: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id
        case image
        case mounts
        case publishedPorts
        case publishedSockets
        case labels
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
        case virtualization
        case ssh
        case readOnly
        case hostNetwork
        case useInit
        case hostPIDNamespace
        case capAdd
        case capDrop
        case shmSize
        case stopSignal
        case creationDate
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        image = try container.decode(ImageDescription.self, forKey: .image)
        mounts = try container.decodeIfPresent([Filesystem].self, forKey: .mounts) ?? []
        publishedPorts = try container.decodeIfPresent([PublishPort].self, forKey: .publishedPorts) ?? []
        publishedSockets = try container.decodeIfPresent([PublishSocket].self, forKey: .publishedSockets) ?? []
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
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
        virtualization = try container.decodeIfPresent(Bool.self, forKey: .virtualization) ?? false
        ssh = try container.decodeIfPresent(Bool.self, forKey: .ssh) ?? false
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        hostNetwork = try container.decodeIfPresent(Bool.self, forKey: .hostNetwork) ?? false
        useInit = try container.decodeIfPresent(Bool.self, forKey: .useInit) ?? false
        hostPIDNamespace = try container.decodeIfPresent(Bool.self, forKey: .hostPIDNamespace) ?? false
        capAdd = try container.decodeIfPresent([String].self, forKey: .capAdd) ?? []
        capDrop = try container.decodeIfPresent([String].self, forKey: .capDrop) ?? []
        shmSize = try container.decodeIfPresent(UInt64.self, forKey: .shmSize)
        stopSignal = try container.decodeIfPresent(String.self, forKey: .stopSignal)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
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
        /// Memory in bytes allocated.
        public var memoryInBytes: UInt64 = 1024.mib()
        /// Storage quota/size in bytes.
        public var storage: UInt64?
        /// Additional CPU cores allocated for VM overhead (guest agent, etc).
        public var cpuOverhead: Int = 1

        public init() {}

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 4
            self.memoryInBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryInBytes) ?? 1024.mib()
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
