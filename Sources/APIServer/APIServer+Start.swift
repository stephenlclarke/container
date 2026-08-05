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
import ContainerAPIClient
import ContainerAPIService
import ContainerAWSLogsSDKAdapter
import ContainerEngineLogging
import ContainerEngineProviderSession
import ContainerEngineRuntimeSPI
import ContainerLog
import ContainerLoggingProviders
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerVersion
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import DNSServer
import Foundation
import Logging
import SystemPackage

extension APIServer {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for the API server"
        )

        static let listenAddress = "127.0.0.1"
        static let localhostDNSPort = 1053
        static let dnsPort = 2053

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        var appRoot = ApplicationRoot.path

        var installRoot = InstallRoot.path

        var logRoot = LogRoot.path

        func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let commandName = APIServer._commandName
            let logPath = logRoot.map { $0.appending(FilePath.Component("\(commandName).log") ?? "unknown") }
            let log = ServiceLogger.bootstrap(category: "APIServer", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                let appRootURL = URL(fileURLWithPath: appRoot.string)
                try ApplicationRoot.ensureCreated(at: appRootURL, log: log)
                log.info("configuring XPC server")
                var routes = [XPCRoute: XPCServer.RouteHandler]()
                let pluginLoader = try initializePluginLoader(log: log)

                try await initializePlugins(pluginLoader: pluginLoader, log: log, routes: &routes, debug: debug)
                let kernelService = try initializeKernelService(
                    log: log,
                    routes: &routes
                )
                let containersService = try await initializeContainersService(
                    pluginLoader: pluginLoader,
                    kernelService: kernelService,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )
                let engineLoggingProvider = try await initializeEngineLoggingProvider(
                    appRoot: appRootURL,
                    containersService: containersService,
                    containerSystemConfig: containerSystemConfig,
                    log: log
                )
                try engineLoggingProvider.start()
                let networkService = try await initializeNetworksService(
                    pluginLoader: pluginLoader,
                    containersService: containersService,
                    containerSystemConfig: containerSystemConfig,
                    log: log,
                    routes: &routes
                )
                await containersService.setNetworksService(networkService)
                initializeHealthCheckService(log: log, routes: &routes)
                let volumesService = try await initializeVolumeService(containersService: containersService, log: log, routes: &routes)
                try initializeDiskUsageService(
                    containersService: containersService,
                    volumesService: volumesService,
                    log: log,
                    routes: &routes
                )

                let server = XPCServer(
                    identifier: "com.apple.container.apiserver",
                    routes: routes.reduce(
                        into: [String: XPCServer.RouteHandler](),
                        {
                            $0[$1.key.rawValue] = $1.value
                        }), log: log)

                await withTaskGroup(of: Result<Void, Error>.self) { group in
                    group.addTask {
                        await withTaskCancellationHandler {
                            await engineLoggingProvider.wait()
                        } onCancel: {
                            Task {
                                await engineLoggingProvider.shutdown()
                            }
                        }
                        return .success(())
                    }

                    group.addTask {
                        log.info("starting XPC server")
                        do {
                            try await server.listen()
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }

                    // start up host table DNS
                    group.addTask {
                        let hostsResolver = ContainerDNSHandler(networkService: networkService)
                        let nxDomainResolver = NxDomainResolver()
                        let compositeResolver = CompositeResolver(handlers: [hostsResolver, nxDomainResolver])
                        let hostsQueryValidator = StandardQueryValidator(handler: compositeResolver)
                        let dnsServer: DNSServer = DNSServer(handler: hostsQueryValidator, log: log)
                        log.info(
                            "starting DNS resolver for container hostnames",
                            metadata: [
                                "host": "\(Self.listenAddress)",
                                "port": "\(Self.dnsPort)",
                            ]
                        )
                        do {
                            try await dnsServer.run(host: Self.listenAddress, port: Self.dnsPort)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }

                    }

                    // start up realhost DNS
                    group.addTask {
                        do {
                            let localhostResolver = LocalhostDNSHandler(log: log)
                            await localhostResolver.monitorResolvers()

                            let nxDomainResolver = NxDomainResolver()
                            let compositeResolver = CompositeResolver(handlers: [localhostResolver, nxDomainResolver])
                            let hostsQueryValidator = StandardQueryValidator(handler: compositeResolver)
                            let dnsServer: DNSServer = DNSServer(handler: hostsQueryValidator, log: log)
                            log.info(
                                "starting DNS resolver for localhost",
                                metadata: [
                                    "host": "\(Self.listenAddress)",
                                    "port": "\(Self.localhostDNSPort)",
                                ]
                            )
                            try await dnsServer.run(host: Self.listenAddress, port: Self.localhostDNSPort)
                            return .success(())
                        } catch {
                            return .failure(error)
                        }
                    }

                    for await result in group {
                        switch result {
                        case .success():
                            continue
                        case .failure(let error):
                            log.error("API server task failed: \(error)")
                        }
                    }
                }
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                APIServer.exit(withError: error)
            }
        }

        private func initializeEngineLoggingProvider(
            appRoot: URL,
            containersService: ContainersService,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger
        ) async throws -> ContainerEngineProviderSessionServer {
            let stateRoot = appRoot.appendingPathComponent(
                "engine-provider",
                isDirectory: true
            )
            let stateRootUUID = try ContainerEngineStateRootIdentityStore(
                path: stateRoot.appendingPathComponent("state-root-id")
            ).loadOrCreate()
            let capabilities = try [
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerAttach",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerAttachWebsocket",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerResize",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerLogs",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerInspect",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerList",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ImageInspect",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ImageList",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerCreate",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerStart",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerStop",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.ContainerDelete",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemInfo",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.route.SystemVersion",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.handoff.object-transfer.v1",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.handoff.provider-key-enrollment.v1",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.handoff.destination-key-possession.v1",
                    status: .native
                ),
                ContainerEngineProviderCapability(
                    identifier: "engine.handoff.part.logging.v1",
                    status: .native
                ),
            ]
            let declaration = try ContainerEngineProviderDeclaration(
                profile: .enhanced,
                kind: .containerAuthority,
                implementationVersion: ReleaseVersion.version(),
                runtimeRevisions: [
                    "container": ReleaseVersion.gitCommit()
                        ?? ReleaseVersion.version(),
                    "container-engine-api":
                        ReleaseVersion
                        .containerEngineAPIVersion(),
                    "containerization": ReleaseVersion.containerizationRef(),
                ],
                stateSchemaVersion: 1,
                capabilities: capabilities
            )
            let fingerprint = try ContainerEngineProviderFingerprint(
                declaration: declaration,
                stateRootUUID: stateRootUUID
            )
            let codeIdentity = try ProviderHandoffCodeIdentity.current()
            let enrollmentTime = try Self.currentUnixSeconds()
            let providerIdentity = try ProviderHandoffProviderKeyStore(
                account:
                    "provider-private-keys-v1.\(stateRootUUID.uuidString.lowercased())"
            ).loadOrCreate(
                context: ProviderHandoffProviderKeyEnrollmentContextV1(
                    providerFingerprint: fingerprint.digest,
                    stateRootUUID: stateRootUUID.uuidString.lowercased(),
                    owningBundleIdentifier: codeIdentity.signingIdentifier,
                    codeRequirementDigestSHA256:
                        codeIdentity.designatedRequirementDigestSHA256,
                    teamIdentifier: codeIdentity.teamIdentifier,
                    providerRegistrationDigestSHA256: String(
                        fingerprint.digest.dropFirst("sha256:".count)
                    ),
                    enrolledAtUnixSeconds: enrollmentTime,
                    notBeforeUnixSeconds: enrollmentTime,
                    notAfterUnixSeconds: UInt64.max
                )
            )
            let backend = ContainerDockerLoggingBackend(
                containers: containersService,
                engineIdentity: stateRootUUID.uuidString,
                serverVersion: ReleaseVersion.version(),
                containerSystemConfig: containerSystemConfig
            )
            let controller = try DockerLoggingAPIController(
                backend: backend,
                sharedResponseBackend: backend
            )
            let objectStore = ProviderHandoffBundleObjectStore(
                root: stateRoot.appendingPathComponent(
                    "handoff-objects",
                    isDirectory: true
                )
            )
            let possessionProofStore = ProviderHandoffPossessionProofStore(
                root: stateRoot.appendingPathComponent(
                    "handoff-possession-proofs",
                    isDirectory: true
                )
            )
            let loggingHandoffResponder =
                try await containersService
                .makeLoggingHandoffControlResponder(
                    stateRoot: stateRoot,
                    objectStore: objectStore,
                    possessionProofStore: possessionProofStore,
                    trustRegistryStore: ProviderHandoffTrustRegistryStore(
                        account:
                            "trust-registry-v1.\(stateRootUUID.uuidString.lowercased())"
                    ),
                    providerIdentity: providerIdentity
                )
            let socketPath =
                stateRoot
                .appendingPathComponent("provider.sock")
                .path
            let provider = try ContainerEngineProviderSessionServer(
                responder: controller,
                handoffControlResponder:
                    ContainerEngineProviderHandoffControlService(
                        objectStore: objectStore,
                        downstream:
                            ContainerEngineProviderIdentityControlResponder(
                                identity: providerIdentity,
                                possessionProofStore:
                                    possessionProofStore,
                                downstream: loggingHandoffResponder
                            )
                    ),
                socketPath: socketPath,
                declaration: declaration,
                stateRootUUID: stateRootUUID
            )
            log.info(
                "configured enhanced Engine logging provider",
                metadata: [
                    "fingerprint": "\(provider.fingerprint.digest)",
                    "socket": "\(socketPath)",
                ]
            )
            return provider
        }

        private static func currentUnixSeconds() throws -> UInt64 {
            let value = Date().timeIntervalSince1970
            guard
                value.isFinite,
                value >= 0,
                value < Double(UInt64.max)
            else {
                throw ValidationError(
                    "the current time cannot be represented for provider handoff enrollment"
                )
            }
            return UInt64(value.rounded(.down))
        }

        private func initializePluginLoader(log: Logger) throws -> PluginLoader {
            log.info(
                "initializing plugin loader",
                metadata: [
                    "installRoot": "\(installRoot.string)"
                ])

            // TODO: Remove when we convert PluginLoader to FilePath
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let pluginsURL = PluginLoader.userPluginsDir(installRoot: installRootURL)
            log.info("detecting user plugins directory", metadata: ["path": "\(pluginsURL.path(percentEncoded: false))"])
            var directoryExists: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &directoryExists)
            let userPluginsURL = directoryExists.boolValue ? pluginsURL : nil

            // plugins built into the application installed as a Unix-like application
            let installRootPluginsPath =
                installRoot
                .appending(FilePath.Component("libexec"))
                .appending(FilePath.Component("container"))
                .appending(FilePath.Component("plugins"))
            let installRootPluginsURL = URL(fileURLWithPath: installRootPluginsPath.string)

            let pluginDirectories = [
                userPluginsURL,
                installRootPluginsURL,
            ].compactMap { $0 }

            let pluginFactories: [PluginFactory] = [
                DefaultPluginFactory(logger: log),
                AppBundlePluginFactory(logger: log),
            ]

            for pluginDirectory in pluginDirectories {
                log.info("discovered plugin directory", metadata: ["path": "\(pluginDirectory.path(percentEncoded: false))"])
            }

            let appRootURL = URL(fileURLWithPath: appRoot.string)
            return try PluginLoader(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                pluginDirectories: pluginDirectories,
                pluginFactories: pluginFactories,
                log: log
            )
        }

        // First load all of the plugins we can find. Then just expose
        // the handlers for clients to do whatever they want.
        private func initializePlugins(
            pluginLoader: PluginLoader,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler],
            debug: Bool = false
        ) async throws {
            log.info("initializing plugins")

            let bootPlugins = pluginLoader.findPlugins().filter { $0.shouldBoot }

            let service = PluginsService(pluginLoader: pluginLoader, log: log)
            try await service.loadAll(bootPlugins, debug: debug)

            let harness = PluginsHarness(service: service, log: log)
            routes[XPCRoute.pluginGet] = XPCServer.route(harness.get)
            routes[XPCRoute.pluginList] = XPCServer.route(harness.list)
            routes[XPCRoute.pluginLoad] = XPCServer.route(harness.load)
            routes[XPCRoute.pluginUnload] = XPCServer.route(harness.unload)
            routes[XPCRoute.pluginRestart] = XPCServer.route(harness.restart)
        }

        private func initializeHealthCheckService(log: Logger, routes: inout [XPCRoute: XPCServer.RouteHandler]) {
            log.info("initializing health check service")

            // TODO: Remove when we convert HealthCheckHarness to FilePath
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let svc = HealthCheckHarness(
                appRoot: appRootURL,
                installRoot: installRootURL,
                logRoot: logRoot,
                log: log
            )
            routes[XPCRoute.ping] = XPCServer.route(svc.ping)
        }

        private func initializeKernelService(
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) throws -> KernelService {
            log.info("initializing kernel service")

            // TODO: Remove when we convert KernelService to FilePath
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let svc = try KernelService(log: log, appRoot: appRootURL)
            let harness = KernelHarness(service: svc, log: log)
            routes[XPCRoute.installKernel] = XPCServer.route(harness.install)
            routes[XPCRoute.getDefaultKernel] = XPCServer.route(harness.getDefaultKernel)
            return svc
        }

        private func initializeContainersService(
            pluginLoader: PluginLoader,
            kernelService: KernelService,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) async throws -> ContainersService {
            log.info("initializing containers service")

            // TODO: Remove when we convert ContainersService to FilePath
            let appRootURL = URL(fileURLWithPath: appRoot.string)
            let installRootURL = URL(fileURLWithPath: installRoot.string)
            let providerSandboxAuthority = await initializeProviderSandboxAuthority(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                log: log
            )
            let journaldService = await initializeJournaldService(
                appRoot: appRootURL,
                installRoot: installRootURL,
                kernelService: kernelService,
                containerSystemConfig: containerSystemConfig,
                authority: providerSandboxAuthority,
                log: log
            )
            let dockerPluginInstallations = await initializeDockerLoggingPlugins(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                kernelService: kernelService,
                containerSystemConfig: containerSystemConfig,
                authority: providerSandboxAuthority,
                log: log
            )
            let remoteLogDriverPlane =
                try await AuthorityRemoteLogDriverPlane
                .create(
                    appRoot: appRootURL,
                    awsLogsClientFactory: AWSCloudWatchLogsClientFactory(),
                    journaldService: journaldService,
                    dockerPluginInstallations: dockerPluginInstallations
                )
            try await remoteLogDriverPlane.reconcileProtectedEffects(
                containerRoot: appRootURL.appendingPathComponent(
                    "containers",
                    isDirectory: true
                )
            )
            let service = try ContainersService(
                appRoot: appRootURL,
                pluginLoader: pluginLoader,
                containerSystemConfig: containerSystemConfig,
                log: log,
                debugHelpers: debug,
                remoteLogDriverPlane: remoteLogDriverPlane
            )
            try await service.reconcileLoggingProviderUpgrades()
            let harness = ContainersHarness(service: service, log: log)

            routes[XPCRoute.containerList] = XPCServer.route(harness.list)
            routes[XPCRoute.containerCreate] = XPCServer.route(harness.create)
            routes[XPCRoute.containerDelete] = XPCServer.route(harness.delete)
            routes[XPCRoute.containerLogs] = XPCServer.route(harness.logs)
            routes[XPCRoute.containerFollowLogs] = XPCServer.route(harness.followLogs)
            routes[XPCRoute.containerLogRecordFile] = XPCServer.route(harness.logRecordFile)
            routes[XPCRoute.containerLogRecords] = XPCServer.route(harness.logRecords)
            routes[XPCRoute.containerFollowLogRecords] = XPCServer.route(harness.followLogRecords)
            routes[XPCRoute.containerEvent] = XPCServer.route(harness.events)
            routes[XPCRoute.containerBootstrap] = XPCServer.route(harness.bootstrap)
            routes[XPCRoute.containerAttach] = XPCServer.route(harness.attach)
            routes[XPCRoute.containerDial] = XPCServer.route(harness.dial)
            routes[XPCRoute.containerStop] = XPCServer.route(harness.stop)
            routes[XPCRoute.containerPause] = XPCServer.route(harness.pause)
            routes[XPCRoute.containerUnpause] = XPCServer.route(harness.unpause)
            routes[XPCRoute.containerStartProcess] = XPCServer.route(harness.startProcess)
            routes[XPCRoute.containerCreateProcess] = harness.createProcess
            routes[XPCRoute.containerResize] = XPCServer.route(harness.resize)
            routes[XPCRoute.containerWait] = XPCServer.route(harness.wait)
            routes[XPCRoute.containerKill] = XPCServer.route(harness.kill)
            routes[XPCRoute.containerStats] = XPCServer.route(harness.stats)
            routes[XPCRoute.containerProcesses] = XPCServer.route(harness.processes)
            routes[XPCRoute.containerDiskUsage] = XPCServer.route(harness.diskUsage)
            routes[XPCRoute.containerCopyIn] = XPCServer.route(harness.copyIn)
            routes[XPCRoute.containerCopyOut] = XPCServer.route(harness.copyOut)
            routes[XPCRoute.containerExport] = XPCServer.route(harness.export)

            return service
        }

        private func initializeJournaldService(
            appRoot: URL,
            installRoot: URL,
            kernelService: KernelService,
            containerSystemConfig: ContainerSystemConfig,
            authority: EngineLinuxSandboxAuthorityV1?,
            log: Logger
        ) async -> (any JournaldService)? {
            do {
                guard let authority else {
                    throw ContainerizationError(
                        .notFound,
                        message:
                            "container-runtime-linux is unavailable for the journald service"
                    )
                }
                let service = try EngineLinuxSandboxJournaldServiceV1.create(
                    appRoot: appRoot,
                    installRoot: installRoot,
                    kernelService: kernelService,
                    containerSystemConfig: containerSystemConfig,
                    authority: authority
                )
                log.info(
                    "verified lazy journald logging service",
                    metadata: [
                        "sandbox": "engine-linux-sandbox",
                        "workload": "container-journald-service",
                    ]
                )
                return service
            } catch {
                log.warning(
                    "journald logging driver is unavailable",
                    metadata: ["error": "\(error)"]
                )
                return nil
            }
        }

        private func initializeProviderSandboxAuthority(
            appRoot: URL,
            pluginLoader: PluginLoader,
            log: Logger
        ) async -> EngineLinuxSandboxAuthorityV1? {
            do {
                guard
                    let runtimePlugin = pluginLoader.findPlugins().first(
                        where: {
                            $0.name
                                == LaunchdEngineLinuxSandboxLauncherV1
                                .runtimePluginName
                                && $0.hasType(.runtime)
                        }
                    )
                else {
                    throw ContainerizationError(
                        .notFound,
                        message:
                            "container-runtime-linux is unavailable for provider services"
                    )
                }
                let launcher = try LaunchdEngineLinuxSandboxLauncherV1(
                    loader: pluginLoader,
                    plugin: runtimePlugin,
                    debug: debug
                )
                return try await EngineLinuxSandboxAuthorityV1.open(
                    root: appRoot.appendingPathComponent(
                        "engine-linux-sandbox",
                        isDirectory: true
                    ),
                    owningControllerID: "container-apiserver-provider-services",
                    sandboxID: "engine-linux-sandbox",
                    launcher: launcher
                )
            } catch {
                log.warning(
                    "Engine Linux provider sandbox is unavailable",
                    metadata: ["error": "\(error)"]
                )
                return nil
            }
        }

        private func initializeDockerLoggingPlugins(
            appRoot: URL,
            pluginLoader: PluginLoader,
            kernelService: KernelService,
            containerSystemConfig: ContainerSystemConfig,
            authority: EngineLinuxSandboxAuthorityV1?,
            log: Logger
        ) async -> [DockerPluginLogDriverInstallation] {
            let plugins = pluginLoader.findPlugins()
                .filter { $0.hasType(.logging) }
                .sorted { $0.name < $1.name }
            guard !plugins.isEmpty else { return [] }
            guard let authority else {
                log.warning(
                    "Docker logging plugins are unavailable without the Engine Linux provider sandbox"
                )
                return []
            }

            var installations = [DockerPluginLogDriverInstallation]()
            let builtInProviders = [
                SyslogLogDriverContract.descriptor(),
                FluentdLogDriverContract.descriptor(),
                GELFLogDriverContract.descriptor(),
                SplunkLogDriverContract.descriptor(),
                AWSLogsLogDriverContract.descriptor(),
                GCPLogsLogDriverContract.descriptor(),
                JournaldLogDriverContract.descriptor(),
            ]
            var collisions = DockerPluginInstallationCollisionRegistry(
                reservedDescriptors:
                    BuiltinLogDriverDescriptors.current.descriptors
                    + builtInProviders
            )
            for plugin in plugins {
                do {
                    guard let resourceRoot = plugin.resourceURL else {
                        throw
                            EngineLinuxSandboxDockerPluginServiceError
                            .invalidInstalledAsset(
                                "logging plugin has no protected resource bundle"
                            )
                    }
                    let assets =
                        try InstalledDockerPluginWorkloadManifestV1
                        .verify(resourceRoot: resourceRoot)
                    let manifest = assets.manifest
                    var candidateCollisions = collisions
                    try candidateCollisions.register(
                        driver: manifest.driver,
                        aliases: manifest.aliases,
                        providerID: manifest.providerID,
                        providerGeneration: manifest.providerGeneration,
                        servicePort: manifest.servicePort
                    )
                    let installation =
                        try EngineLinuxSandboxDockerPluginServiceV1.create(
                            appRoot: appRoot,
                            resourceRoot: resourceRoot,
                            kernelService: kernelService,
                            containerSystemConfig: containerSystemConfig,
                            authority: authority
                        )
                    installations.append(installation)
                    collisions = candidateCollisions
                    log.info(
                        "verified lazy Docker logging plugin",
                        metadata: [
                            "plugin": "\(plugin.name)",
                            "driver": "\(manifest.driver)",
                            "providerGeneration":
                                "\(manifest.providerGeneration)",
                        ]
                    )
                } catch {
                    log.warning(
                        "Docker logging plugin is unavailable",
                        metadata: [
                            "plugin": "\(plugin.name)",
                            "error": "\(error)",
                        ]
                    )
                }
            }
            return installations
        }

        private func initializeNetworksService(
            pluginLoader: PluginLoader,
            containersService: ContainersService,
            containerSystemConfig: ContainerSystemConfig,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) async throws -> NetworksService {
            log.info("initializing networks service")

            let resourceRoot = appRoot.appending(FilePath.Component("networks"))
            let defaultNetworkConfig = try NetworkConfiguration(
                name: NetworkClient.defaultNetworkName,
                mode: .nat,
                ipv4Subnet: containerSystemConfig.network.subnet,
                ipv6Subnet: containerSystemConfig.network.subnetv6,
                labels: try .init([ResourceLabelKeys.role: ResourceRoleValues.builtin]),
                plugin: "container-network-vmnet"
            )
            let service = try await NetworksService(
                pluginLoader: pluginLoader,
                resourceRoot: resourceRoot,
                containersService: containersService,
                defaultNetworkConfiguration: defaultNetworkConfig,
                log: log,
                debugHelpers: debug
            )

            let defaultNetwork = try await service.list()
                .filter { $0.isBuiltin }
                .first
            if defaultNetwork == nil {
                // FIXME: default network should be configurable elsewhere
                _ = try await service.create(configuration: defaultNetworkConfig)
            }

            let harness = NetworksHarness(service: service, log: log)

            if #available(macOS 26, *) {
                routes[XPCRoute.networkCreate] = XPCServer.route(harness.create)
            }
            routes[XPCRoute.networkList] = XPCServer.route(harness.list)
            routes[XPCRoute.networkDelete] = XPCServer.route(harness.delete)

            return service
        }

        private func initializeVolumeService(
            containersService: ContainersService,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) async throws -> VolumesService {
            log.info("initializing volume service")

            let resourceRoot = appRoot.appending(FilePath.Component("volumes"))
            let service = try await VolumesService(resourceRoot: resourceRoot, containersService: containersService, log: log)
            let harness = VolumesHarness(service: service, log: log)

            routes[XPCRoute.volumeCreate] = XPCServer.route(harness.create)
            routes[XPCRoute.volumeDelete] = XPCServer.route(harness.delete)
            routes[XPCRoute.volumeList] = XPCServer.route(harness.list)
            routes[XPCRoute.volumeInspect] = XPCServer.route(harness.inspect)
            routes[XPCRoute.volumeDiskUsage] = XPCServer.route(harness.diskUsage)

            return service
        }

        private func initializeDiskUsageService(
            containersService: ContainersService,
            volumesService: VolumesService,
            log: Logger,
            routes: inout [XPCRoute: XPCServer.RouteHandler]
        ) throws {
            log.info("initializing disk usage service")

            let service = DiskUsageService(
                containersService: containersService,
                volumesService: volumesService,
                log: log
            )
            let harness = DiskUsageHarness(service: service, log: log)

            routes[XPCRoute.systemDiskUsage] = XPCServer.route(harness.get)
        }
    }
}
