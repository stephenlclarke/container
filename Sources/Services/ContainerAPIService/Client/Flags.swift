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

import ArgumentParser
import ContainerizationError
import Foundation

public struct Flags {
    public struct Logging: ParsableArguments {
        public init() {}

        public init(debug: Bool) {
            self.debug = debug
        }

        @Flag(name: .long, help: "Enable debug output [environment: CONTAINER_DEBUG]")
        public var debug = false
    }

    public struct Process: ParsableArguments {
        public init() {}

        public init(
            cwd: String?,
            env: [String],
            envFile: [String],
            gid: UInt32?,
            groupAdd: [String] = [],
            interactive: Bool,
            oomScoreAdj: Int? = nil,
            privileged: Bool = false,
            tty: Bool,
            uid: UInt32?,
            ulimits: [String],
            user: String?
        ) {
            self.cwd = cwd
            self.env = env
            self.envFile = envFile
            self.gid = gid
            self.groupAdd = groupAdd
            self.interactive = interactive
            self.oomScoreAdj = oomScoreAdj
            self.privileged = privileged
            self.tty = tty
            self.uid = uid
            self.ulimits = ulimits
            self.user = user
        }

        @Option(name: .shortAndLong, help: "Set environment variables (key=value, or just key to inherit from host)")
        public var env: [String] = []

        @Option(
            name: .long,
            help: "Read in a file of environment variables (key=value format, ignores # comments and blank lines)"
        )
        public var envFile: [String] = []

        @Option(name: .long, help: "Set the group ID for the process")
        public var gid: UInt32?

        @Option(
            name: .customLong("group-add"),
            help: .init("Add a supplemental group by name or numeric ID to the process", valueName: "group")
        )
        public var groupAdd: [String] = []

        @Flag(name: .shortAndLong, help: "Keep the standard input open even if not attached")
        public var interactive = false

        @Option(
            name: .customLong("oom-score-adj"),
            parsing: .unconditional,
            help: .init("Adjust the Linux OOM killer score for the process", valueName: "score")
        )
        public var oomScoreAdj: Int?

        @Flag(name: .customLong("privileged"), help: "Give extended Linux capabilities to the process")
        public var privileged = false

        @Flag(name: .shortAndLong, help: "Open a TTY with the process")
        public var tty = false

        @Option(name: .shortAndLong, help: "Set the user for the process (format: name|uid[:gid])")
        public var user: String?

        @Option(name: .long, help: "Set the user ID for the process")
        public var uid: UInt32?

        @Option(
            name: [.customShort("w"), .customLong("workdir"), .long],
            help: .init(
                "Set the initial working directory inside the container",
                valueName: "dir"
            )
        )
        public var cwd: String?

        @Option(
            name: .customLong("ulimit"),
            help: .init(
                "Set resource limits (format: <type>=<soft>[:<hard>])",
                valueName: "limit"
            )
        )
        public var ulimits: [String] = []
    }

    public struct Resource: ParsableArguments {
        public init() {}

        public init(
            cpus: Double?,
            memory: String?,
            cpuPeriod: Int64? = nil,
            cpuQuota: Int64? = nil
        ) {
            self.cpus = cpus
            self.memory = memory
            self.cpuPeriod = cpuPeriod
            self.cpuQuota = cpuQuota
        }

        @Option(name: .shortAndLong, help: "CPU limit (0 for unlimited; supports fractional values such as 0.25)")
        public var cpus: Double?

        @Option(
            name: .customLong("cpu-period"),
            help: .init("CPU CFS period in microseconds", valueName: "microseconds")
        )
        public var cpuPeriod: Int64?

        @Option(
            name: .customLong("cpu-quota"),
            help: .init("CPU CFS quota in microseconds (-1 for unlimited)", valueName: "microseconds")
        )
        public var cpuQuota: Int64?

        @Option(
            name: .shortAndLong,
            help: "Amount of memory (byte granularity), with optional K, M, G, T, or P suffix"
        )
        public var memory: String?
    }

    public struct DNS: ParsableArguments {
        public init() {}

        public init(domain: String?, nameservers: [String], options: [String], searchDomains: [String]) {
            self.domain = domain
            self.nameservers = nameservers
            self.options = options
            self.searchDomains = searchDomains
        }

        @Option(
            name: .customLong("dns"),
            help: .init("DNS nameserver IP address", valueName: "ip")
        )
        public var nameservers: [String] = []

        @Option(
            name: .customLong("dns-domain"),
            help: .init("Default DNS domain", valueName: "domain")
        )
        public var domain: String? = nil

        @Option(
            name: .customLong("dns-option"),
            help: .init("DNS options", valueName: "option")
        )
        public var options: [String] = []

        @Option(
            name: .customLong("dns-search"),
            help: .init("DNS search domains", valueName: "domain")
        )
        public var searchDomains: [String] = []
    }

    public struct Registry: ParsableArguments {
        public init() {}

        public init(scheme: String) {
            self.scheme = scheme
        }

        @Option(help: "Scheme to use when connecting to the container registry. One of (http, https, auto)")
        public var scheme: String = "auto"
    }

    public struct Management: ParsableArguments {
        public init() {}

        public init(
            arch: String,
            capAdd: [String],
            capDrop: [String],
            cidfile: String,
            detach: Bool,
            dns: Flags.DNS,
            dnsDisabled: Bool,
            addHost: [String] = [],
            entrypoint: String?,
            initImage: String?,
            kernel: String?,
            labels: [String],
            healthCommand: String? = nil,
            healthInterval: String? = nil,
            healthRetries: Int? = nil,
            healthStartInterval: String? = nil,
            healthStartPeriod: String? = nil,
            healthTimeout: String? = nil,
            hostname: String? = nil,
            domainname: String? = nil,
            logDriver: String? = nil,
            logOpt: [String] = [],
            mounts: [String],
            name: String?,
            networks: [String],
            os: String,
            pid: String? = nil,
            platform: String?,
            publishPorts: [String],
            publishSockets: [String],
            readOnly: Bool,
            remove: Bool,
            restart: String? = nil,
            restartDelay: String? = nil,
            restartWindow: String? = nil,
            rosetta: Bool,
            runtime: String?,
            ssh: Bool,
            shmSize: String?,
            stopSignal: String? = nil,
            stopTimeout: Int32? = nil,
            pidsLimit: Int64? = nil,
            memoryReservation: String? = nil,
            memorySwap: String? = nil,
            cpuShares: UInt64? = nil,
            blkio: [String] = [],
            deviceCgroupRules: [String] = [],
            devices: [String] = [],
            gpus: [String] = [],
            sysctls: [String] = [],
            securityOpts: [String] = [],
            noHealthCheck: Bool = false,
            tmpFs: [String],
            useInit: Bool,
            virtualization: Bool,
            volumes: [String]
        ) {
            self.arch = arch
            self.capAdd = capAdd
            self.capDrop = capDrop
            self.cidfile = cidfile
            self.detach = detach
            self.dns = dns
            self.dnsDisabled = dnsDisabled
            self.addHost = addHost
            self.entrypoint = entrypoint
            self.initImage = initImage
            self.kernel = kernel
            self.labels = labels
            self.healthCommand = healthCommand
            self.healthInterval = healthInterval
            self.healthRetries = healthRetries
            self.healthStartInterval = healthStartInterval
            self.healthStartPeriod = healthStartPeriod
            self.healthTimeout = healthTimeout
            self.hostname = hostname
            self.domainname = domainname
            self.logDriver = logDriver
            self.logOpt = logOpt
            self.mounts = mounts
            self.name = name
            self.networks = networks
            self.os = os
            self.pid = pid
            self.platform = platform
            self.publishPorts = publishPorts
            self.publishSockets = publishSockets
            self.readOnly = readOnly
            self.remove = remove
            self.restart = restart
            self.restartDelay = restartDelay
            self.restartWindow = restartWindow
            self.rosetta = rosetta
            self.runtime = runtime
            self.ssh = ssh
            self.shmSize = shmSize
            self.stopSignal = stopSignal
            self.stopTimeout = stopTimeout
            self.pidsLimit = pidsLimit
            self.memoryReservation = memoryReservation
            self.memorySwap = memorySwap
            self.cpuShares = cpuShares
            self.blkio = blkio
            self.deviceCgroupRules = deviceCgroupRules
            self.devices = devices
            self.gpus = gpus
            self.sysctls = sysctls
            self.securityOpts = securityOpts
            self.noHealthCheck = noHealthCheck
            self.tmpFs = tmpFs
            self.useInit = useInit
            self.virtualization = virtualization
            self.volumes = volumes
        }

        @Option(name: .shortAndLong, help: "Set arch if image can target multiple architectures")
        public var arch: String = Arch.hostArchitecture().rawValue

        @Option(
            name: .customLong("cap-add"),
            help: .init("Add a Linux capability (e.g. CAP_NET_RAW, or ALL)", valueName: "cap")
        )
        public var capAdd: [String] = []

        @Option(
            name: .customLong("cap-drop"),
            help: .init("Drop a Linux capability (e.g. CAP_NET_RAW, or ALL)", valueName: "cap")
        )
        public var capDrop: [String] = []

        @Option(name: .long, help: "Write the container ID to the path provided")
        public var cidfile = ""

        @Flag(name: .shortAndLong, help: "Run the container and detach from the process")
        public var detach = false

        @OptionGroup
        public var dns: Flags.DNS

        @Option(
            name: .customLong("add-host"),
            help: .init("Add a custom host-to-IP mapping to /etc/hosts (format: host:ip or host=ip)", valueName: "host:ip")
        )
        public var addHost: [String] = []

        @Option(
            name: .long,
            help: .init(
                "Override the entrypoint of the image",
                valueName: "cmd"
            )
        )
        public var entrypoint: String?

        @Flag(name: .customLong("init"), help: "Run an init process inside the container that forwards signals and reaps processes")
        public var useInit = false

        @Option(
            name: .long,
            help: .init("Use a custom init image instead of the default", valueName: "image")
        )
        public var initImage: String?

        @Option(
            name: .shortAndLong,
            help: .init("Set a custom kernel path", valueName: "path"),
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            }
        )
        public var kernel: String?

        @Option(name: [.short, .customLong("label")], help: "Add a key=value label to the container")
        public var labels: [String] = []

        @Option(name: .customLong("health-cmd"), help: "Command to run to check container health")
        public var healthCommand: String?

        @Option(name: .customLong("health-interval"), help: "Time between health checks (for example: 30s, 1m30s)")
        public var healthInterval: String?

        @Option(name: .customLong("health-retries"), help: "Consecutive failures needed to report unhealthy")
        public var healthRetries: Int?

        @Option(name: .customLong("health-start-interval"), help: "Time between health checks during the start period")
        public var healthStartInterval: String?

        @Option(name: .customLong("health-start-period"), help: "Start period before health check failures count")
        public var healthStartPeriod: String?

        @Option(name: .customLong("health-timeout"), help: "Maximum time a health check may run")
        public var healthTimeout: String?

        @Option(name: [.customShort("h"), .customLong("hostname")], help: "Container host name")
        public var hostname: String?

        @Option(name: .customLong("domainname"), help: "Container NIS domain name")
        public var domainname: String?

        @Option(name: .customLong("log-driver"), help: "Set the container stdio log driver (json-file, local, or none)")
        public var logDriver: String?

        @Option(name: .customLong("log-opt"), help: "Set a container stdio log driver option (max-size=<size> or max-file=<count>)")
        public var logOpt: [String] = []

        @Option(name: .customLong("mount"), help: "Add a mount to the container (format: type=<>,source=<>,target=<>,readonly)")
        public var mounts: [String] = []

        @Option(name: .long, help: "Use the specified name as the container ID")
        public var name: String?

        @Option(
            name: [.customLong("network")],
            help:
                "Attach the container to a network (format: <name>[,alias=NAME][,mac=XX:XX:XX:XX:XX:XX][,mtu=VALUE][,interface=NAME][,address=IP[/PREFIX]][,ip=IPv4][,ip6=IPv6], or none/host)"
        )
        public var networks: [String] = []

        @Flag(name: [.customLong("no-dns")], help: "Do not configure DNS in the container")
        public var dnsDisabled = false

        @Option(name: .long, help: "Set OS if image can target multiple operating systems")
        public var os = "linux"

        @Option(name: .customLong("pid"), help: "Set the PID namespace mode (host)")
        public var pid: String?

        @Option(
            name: [.customShort("p"), .customLong("publish")],
            help: .init(
                "Publish a port from container to host (format: [host-ip:]host-port:container-port[/protocol])",
                valueName: "spec"
            )
        )
        public var publishPorts: [String] = []

        @Option(name: .long, help: "Platform for the image if it's multi-platform. This takes precedence over --os and --arch [environment: CONTAINER_DEFAULT_PLATFORM]")
        public var platform: String?

        @Option(
            name: .customLong("publish-socket"),
            help: .init(
                "Publish a socket from container to host (format: host_path:container_path)",
                valueName: "spec"
            )
        )
        public var publishSockets: [String] = []

        @Flag(name: .long, help: "Mount the container's root filesystem as read-only")
        public var readOnly = false

        @Flag(name: [.customLong("rm"), .long], help: "Remove the container after it stops")
        public var remove = false

        @Option(name: .long, help: "Restart policy to apply when the container exits (no, on-failure[:max-retries], always, unless-stopped)")
        public var restart: String?

        @Option(name: .long, help: ArgumentHelp("Delay between restart attempts", valueName: "duration"))
        public var restartDelay: String?

        @Option(name: .long, help: ArgumentHelp("Successful-run window before restart retry state resets", valueName: "duration"))
        public var restartWindow: String?

        @Flag(name: .long, help: "Enable Rosetta in the container")
        public var rosetta = false

        @Option(name: .long, help: "Set the runtime handler for the container (default: container-runtime-linux)")
        public var runtime: String?

        @Flag(name: .long, help: "Forward SSH agent socket to container")
        public var ssh = false

        @Option(name: .customLong("shm-size"), help: "Size of /dev/shm (e.g. 64M, 1G)")
        public var shmSize: String?

        @Option(name: .customLong("stop-signal"), help: "Signal to send when stopping the container")
        public var stopSignal: String?

        @Option(name: .customLong("stop-timeout"), help: "Seconds to wait before forcing container termination")
        public var stopTimeout: Int32?

        @Option(
            name: .customLong("pids-limit"),
            parsing: .unconditional,
            help: "Tune container pids limit; use -1 for unlimited"
        )
        public var pidsLimit: Int64?

        @Option(
            name: .customLong("memory-reservation"),
            help: "Protected memory reservation (e.g. 512M, 1G)"
        )
        public var memoryReservation: String?

        @Option(
            name: .customLong("memory-swap"),
            parsing: .unconditional,
            help: "Total memory plus swap limit (e.g. 1G); use -1 for unlimited swap"
        )
        public var memorySwap: String?

        @Option(
            name: .customLong("cpu-shares"),
            help: "Relative CPU scheduling weight (must be at least 2)"
        )
        public var cpuShares: UInt64?

        @Option(
            name: .customLong("blkio"),
            help: .init(
                "Block I/O cgroup tuning options (experimental: see command reference for the supported keys)",
                valueName: "option"
            )
        )
        public var blkio: [String] = []

        @Option(
            name: .customLong("device-cgroup-rule"),
            help: .init(
                "Add a Linux device cgroup rule (format: '<type> <major>:<minor> <access>')",
                valueName: "rule"
            )
        )
        public var deviceCgroupRules: [String] = []

        @Option(
            name: .customLong("device"),
            help: .init(
                "Add a supported Linux VM device to the container (format: host[:container[:permissions]])",
                valueName: "host[:container[:permissions]]"
            )
        )
        public var devices: [String] = []

        @Option(
            name: .customLong("gpus"),
            help: .init(
                "Request the supported virtio-gpu device (for example: all, count=1, or device=0)",
                valueName: "gpu-request"
            )
        )
        public var gpus: [String] = []

        @Option(name: .customLong("sysctl"), help: .init("Set a namespaced kernel parameter (format: name=value)", valueName: "name=value"))
        public var sysctls: [String] = []

        @Option(
            name: .customLong("security-opt"),
            help: .init("Set a supported Linux security option (no-new-privileges:true|false)", valueName: "option")
        )
        public var securityOpts: [String] = []

        @Flag(name: .customLong("no-healthcheck"), help: "Disable the image health check")
        public var noHealthCheck = false

        @Option(name: .customLong("tmpfs"), help: "Add a tmpfs mount to the container at the given path")
        public var tmpFs: [String] = []

        @Flag(
            name: .long,
            help:
                "Expose virtualization capabilities to the container (requires host and guest support)"
        )
        public var virtualization: Bool = false

        @Option(name: [.customLong("volume"), .short], help: "Bind mount a volume into the container")
        public var volumes: [String] = []

        public func validate() throws {
            if let stopTimeout, stopTimeout < 0 {
                throw ValidationError("--stop-timeout must be non-negative")
            }
            if dnsDisabled {
                let hasDNSConfig =
                    !dns.nameservers.isEmpty
                    || dns.domain != nil
                    || !dns.options.isEmpty
                    || !dns.searchDomains.isEmpty
                if hasDNSConfig {
                    throw ValidationError(
                        "`--no-dns` cannot be used with DNS configuration flags (`--dns`, `--dns-domain`, `--dns-option`, `--dns-search`)"
                    )
                }
            }
        }
    }

    public struct Progress: ParsableArguments {
        public init() {}

        public init(progress: ProgressType) {
            self.progress = progress
        }

        public enum ProgressType: String, ExpressibleByArgument {
            case auto
            case none
            case ansi
            case plain
            case color
        }

        @Option(name: .long, help: ArgumentHelp("Progress type (format: auto|none|ansi|plain|color)", valueName: "type"))
        public var progress: ProgressType = .auto
    }

    public struct ImageFetch: ParsableArguments {
        public init() {}

        public init(maxConcurrentDownloads: Int) {
            self.maxConcurrentDownloads = maxConcurrentDownloads
        }

        @Option(name: .long, help: "Maximum number of concurrent downloads")
        public var maxConcurrentDownloads: Int = 3
    }
}
