"""Explicitly admitted layers. Builds and executable tests are separate targets."""

load(":layer_build.bzl", "layer_build")

LAYERS = {
    "system": struct(
        package = "swift-system",
        products = ["SystemPackage"],
        tests = ["SystemTests"],
        compile_checks = ["MemberImportVisibility"],
    ),
    "atomics": struct(
        package = "swift-atomics",
        products = ["Atomics"],
        tests = ["AtomicsTests"],
        compile_checks = [],
    ),
    "collections": struct(
        package = "swift-collections",
        products = ["Collections"],
        tests = ["DequeTests", "OrderedCollectionsTests", "CollectionsModuleTests"],
        compile_checks = [],
    ),
    "logging": struct(
        package = "swift-log",
        products = ["Logging"],
        tests = ["LoggingTests"],
        compile_checks = [],
    ),
    "service-context": struct(
        package = "swift-service-context",
        products = ["ServiceContextModule"],
        tests = ["ServiceContextTests"],
        compile_checks = [],
    ),
    "numerics": struct(
        package = "swift-numerics",
        products = ["Numerics"],
        tests = ["RealTests", "ComplexTests"],
        compile_checks = [],
    ),
    "asn1": struct(
        package = "swift-asn1",
        products = ["SwiftASN1"],
        tests = ["SwiftASN1Tests"],
        compile_checks = [],
    ),
    "argument-parser": struct(
        package = "swift-argument-parser",
        products = ["ArgumentParser"],
        tests = ["ArgumentParserUnitTests", "ArgumentParserToolInfoTests"],
        compile_checks = [],
    ),
    "http-types": struct(
        package = "swift-http-types",
        products = ["HTTPTypes"],
        tests = ["HTTPTypesTests"],
        compile_checks = [],
    ),
    "metrics": struct(
        package = "swift-metrics",
        products = ["Metrics"],
        tests = ["MetricsTests"],
        compile_checks = [],
    ),
    "algorithms": struct(
        package = "swift-algorithms",
        products = ["Algorithms"],
        tests = ["SwiftAlgorithmsTests"],
        compile_checks = [],
    ),
    "tracing": struct(
        package = "swift-distributed-tracing",
        products = ["Tracing"],
        tests = ["InstrumentationTests", "TracingTests"],
        compile_checks = [],
    ),
    "toml": struct(
        package = "swift-toml",
        products = ["TOML"],
        tests = ["TOMLTests"],
        compile_checks = [],
    ),
    "protobuf": struct(
        package = "swift-protobuf",
        products = ["SwiftProtobuf"],
        tests = ["SwiftProtobufTests"],
        compile_checks = [],
    ),
    "yaml": struct(
        package = "yams",
        products = ["Yams"],
        tests = ["YamsTests"],
        compile_checks = [],
    ),
    "zstd": struct(
        package = "zstd",
        products = ["libzstd"],
        tests = [],
        compile_checks = [],
    ),
    "punycode": struct(
        package = "punycodeswift",
        products = ["Punycode"],
        tests = ["PunycodeSwiftTests"],
        compile_checks = [],
    ),
    "domain-names": struct(
        package = "tldextractswift",
        products = ["TLDExtractSwift"],
        tests = ["TLDExtractSwiftTests"],
        compile_checks = [],
    ),
    "structured-headers": struct(
        package = "swift-http-structured-headers",
        products = ["StructuredFieldValues"],
        tests = ["StructuredFieldValuesTests"],
        compile_checks = [],
    ),
    "async-algorithms": struct(
        package = "swift-async-algorithms",
        products = ["AsyncAlgorithms"],
        tests = ["AsyncAlgorithmsTests"],
        compile_checks = [],
    ),
    "service-lifecycle": struct(
        package = "swift-service-lifecycle",
        products = ["ServiceLifecycle"],
        tests = ["ServiceLifecycleTests"],
        compile_checks = [],
    ),
    "engine-wire": struct(
        package = "container-engine-api",
        products = ["ContainerEngineWire"],
        tests = ["ContainerEngineWireTests"],
        compile_checks = [],
    ),
    "crypto": struct(
        package = "swift-crypto",
        products = ["Crypto", "_CryptoExtras"],
        tests = ["CryptoTests", "_CryptoExtrasTests"],
        compile_checks = [],
    ),
    "certificates": struct(
        package = "swift-certificates",
        products = ["X509"],
        tests = ["X509Tests"],
        compile_checks = [],
    ),
    "nio": struct(
        package = "swift-nio",
        products = ["NIOCore", "NIOPosix", "NIOHTTP1"],
        tests = ["NIOCoreTests", "NIOEmbeddedTests", "NIOHTTP1Tests"],
        compile_checks = [],
    ),
    "nio-ssl": struct(
        package = "swift-nio-ssl",
        products = ["NIOSSL"],
        tests = ["NIOSSLTests"],
        compile_checks = [],
    ),
    "nio-http2": struct(
        package = "swift-nio-http2",
        products = ["NIOHTTP2", "NIOHPACK"],
        tests = ["NIOHTTP2Tests", "NIOHPACKTests"],
        compile_checks = [],
    ),
    "nio-transport-services": struct(
        package = "swift-nio-transport-services",
        products = ["NIOTransportServices"],
        tests = ["NIOTransportServicesTests"],
        compile_checks = [],
    ),
    "nio-extras": struct(
        package = "swift-nio-extras",
        products = ["NIOExtras", "NIOHTTPCompression", "NIOSOCKS"],
        tests = ["NIOExtrasTests", "NIOHTTPCompressionTests", "NIOSOCKSTests"],
        compile_checks = [],
    ),
    "configuration": struct(
        package = "swift-configuration",
        products = ["Configuration"],
        tests = ["ConfigurationTests"],
        compile_checks = [],
    ),
    "configuration-toml": struct(
        package = "swift-configuration-toml",
        products = ["ConfigurationTOML"],
        tests = ["ConfigurationTOMLTests"],
        compile_checks = [],
    ),
    "async-http-client": struct(
        package = "async-http-client",
        products = ["AsyncHTTPClient"],
        tests = ["AsyncHTTPClientTests"],
        compile_checks = [],
    ),
    "grpc-core": struct(
        package = "grpc-swift-2",
        products = ["GRPCCore", "GRPCInProcessTransport"],
        tests = ["GRPCCoreTests", "GRPCInProcessTransportTests"],
        compile_checks = [],
    ),
    "grpc-protobuf": struct(
        package = "grpc-swift-protobuf",
        products = ["GRPCProtobuf"],
        tests = ["GRPCProtobufTests"],
        compile_checks = [],
    ),
    "grpc-transport": struct(
        package = "grpc-swift-nio-transport",
        products = ["GRPCNIOTransportHTTP2"],
        tests = ["GRPCNIOTransportCoreTests", "GRPCNIOTransportHTTP2Tests"],
        compile_checks = [],
    ),
    "containerization-os": struct(
        package = "containerization",
        products = ["ContainerizationError", "ContainerizationOS", "ContainerizationIO", "ContainerizationExtras"],
        tests = ["ContainerizationOSTests", "ContainerizationExtrasTests"],
        compile_checks = [],
    ),
    "containerization-archive": struct(
        package = "containerization",
        products = ["ContainerizationArchive"],
        tests = ["ContainerizationArchiveTests"],
        compile_checks = [],
    ),
    "containerization-ext4": struct(
        package = "containerization",
        products = ["ContainerizationEXT4"],
        tests = ["ContainerizationEXT4Tests"],
        compile_checks = [],
    ),
    "containerization-oci": struct(
        package = "containerization",
        products = ["ContainerizationOCI"],
        tests = ["ContainerizationOCITests"],
        compile_checks = [],
    ),
    "containerization": struct(
        package = "containerization",
        products = ["Containerization"],
        tests = ["ContainerizationUnitTests"],
        compile_checks = [],
    ),
    "containerization-netlink": struct(
        package = "containerization",
        products = ["ContainerizationNetlink"],
        tests = ["ContainerizationNetlinkTests"],
        compile_checks = [],
    ),
    "containerization-hypervisor": struct(
        package = "containerization",
        products = ["CloudHypervisor"],
        tests = ["CloudHypervisorTests"],
        compile_checks = [],
    ),
    "containerization-cli": struct(
        package = "containerization",
        products = ["cctl"],
        tests = ["cctlTests"],
        compile_checks = [],
    ),
    "containerization-guest-core": struct(
        package = "containerization",
        products = ["VminitdCore"],
        tests = ["VminitdCoreTests"],
        compile_checks = [],
    ),
    "engine-core": struct(
        package = "container-engine-api",
        products = ["ContainerEngineRuntimeSPI", "ContainerEngineRouter", "ContainerEngineLogging"],
        tests = ["ContainerEngineRuntimeSPITests", "ContainerEngineRouterTests", "ContainerEngineLoggingTests"],
        compile_checks = [],
    ),
    "engine-transport": struct(
        package = "container-engine-api",
        products = ["ContainerUnixHTTPServer", "ContainerUnixHTTPClient"],
        tests = ["ContainerUnixHTTPServerTests", "ContainerUnixHTTPClientTests"],
        compile_checks = [],
    ),
    "engine-session": struct(
        package = "container-engine-api",
        products = ["ContainerEngineProviderSession"],
        tests = ["ContainerEngineProviderSessionTests"],
        compile_checks = [],
    ),
    "engine-gateway": struct(
        package = "container-engine-api",
        products = ["ContainerEngineGateway"],
        tests = ["ContainerEngineGatewayTests"],
        compile_checks = [],
    ),
    "engine-service": struct(
        package = "container-engine-api",
        products = ["ContainerEngineService"],
        tests = ["ContainerEngineServiceTests"],
        compile_checks = [],
    ),
    "container-version": struct(
        package = "container",
        products = ["ContainerVersion"],
        tests = ["ContainerVersionTests"],
        compile_checks = [],
    ),
    "container-semantic": struct(
        package = "container",
        products = ["DockerSemanticHelper"],
        tests = ["DockerSemanticHelperTests"],
        compile_checks = [],
    ),
    "container-sockets": struct(
        package = "container",
        products = ["SocketForwarder"],
        tests = ["SocketForwarderTests"],
        compile_checks = [],
    ),
    "container-base": struct(
        package = "container",
        products = ["ContainerLog", "ContainerXPC", "ContainerOS", "TerminalProgress", "DNSServer"],
        tests = ["CLITests", "ContainerXPCTests", "ContainerOSTests", "TerminalProgressTests", "DNSServerTests"],
        compile_checks = [],
    ),
    "container-state": struct(
        package = "container",
        products = ["ContainerResource", "ContainerPersistence", "ContainerPlugin", "ContainerTestSupport"],
        tests = ["ContainerPersistenceTests", "ContainerPluginTests", "ContainerTestSupportTests"],
        compile_checks = [],
    ),
    "container-client": struct(
        package = "container",
        products = ["ContainerAPIClient", "ContainerImagesServiceClient", "ContainerNetworkClient", "ContainerRuntimeClient", "ContainerRuntimeLinuxClient", "MachineAPIClient"],
        tests = ["ContainerAPIClientTests", "MachineAPIClientTests"],
        compile_checks = [],
    ),
    "container-logging": struct(
        package = "container",
        products = ["ContainerLoggingProviders", "ContainerLoggingStorage"],
        tests = ["ContainerLoggingProvidersTests"],
        compile_checks = [],
    ),
    "container-build": struct(
        package = "container",
        products = ["ContainerBuild"],
        tests = ["ContainerBuildTests"],
        compile_checks = [],
    ),
    "container-images": struct(
        package = "container",
        products = ["ContainerImagesService"],
        tests = ["ContainerImagesServiceTests"],
        compile_checks = [],
    ),
    "container-network": struct(
        package = "container",
        products = ["ContainerNetworkServer", "ContainerNetworkVmnetServer"],
        tests = ["ContainerNetworkServerTests", "ContainerNetworkVmnetServerTests"],
        compile_checks = [],
    ),
    "container-runtime": struct(
        package = "container",
        products = ["ContainerRuntimeLinuxServer"],
        tests = ["ContainerRuntimeLinuxServerTests"],
        compile_checks = [],
    ),
    "container-machine": struct(
        package = "container",
        products = ["MachineAPIService"],
        tests = ["MachineAPIServiceTests"],
        compile_checks = [],
    ),
    "container-api": struct(
        package = "container",
        products = ["ContainerAPIService"],
        tests = ["ContainerAPIServiceTests", "ContainerResourceTests"],
        compile_checks = [],
    ),
    "container-commands": struct(
        package = "container",
        products = ["ContainerCommands"],
        tests = ["ContainerCommandsTests"],
        compile_checks = [],
    ),
    "container-k8s": struct(
        package = "container",
        products = ["ContainerK8s"],
        tests = ["K8sPluginTests"],
        compile_checks = [],
    ),
    "aws-crt": struct(
        package = "aws-crt-swift",
        products = ["AwsCommonRuntimeKit"],
        tests = ["AwsCommonRuntimeKitOfflineTests"],
        compile_checks = [],
    ),
    "smithy": struct(
        package = "smithy-swift",
        products = ["ClientRuntime", "SmithyCodegenCLI"],
        tests = [],
        compile_checks = [],
    ),
    "aws-cloudwatch": struct(
        package = "aws-sdk-swift",
        products = ["AWSCloudWatchLogs", "AWSClientRuntime", "AWSSDKIdentity"],
        tests = ["AWSClientRuntimeTests", "AWSSDKEventStreamsAuthTests", "AWSSDKHTTPAuthTests", "AWSSDKIdentityTests"],
        compile_checks = [],
    ),
    "container-executables": struct(
        package = "container",
        products = ["container", "container-engine", "container-apiserver", "container-core-images", "container-network-vmnet", "container-runtime-linux", "machine-apiserver", "k8s"],
        tests = [],
        compile_checks = [],
    ),
}

# These suites include host networking or Keychain checks requested explicitly.
HOST_TESTS = {
    "container-api": ["ContainerAPIServiceTests"],
    "engine-service": ["ContainerEngineServiceTests"],
    "engine-session": ["ContainerEngineProviderSessionTests"],
    "engine-core": ["ContainerEngineRuntimeSPITests"],
    "containerization-oci": ["ContainerizationOCITests"],
    "containerization-os": ["ContainerizationOSTests"],
    "nio-transport-services": ["NIOTransportServicesTests"],
    "async-http-client": ["AsyncHTTPClientTests"],
}

RUNTIME_TESTS = ["IntegrationTests"]

def declare_layers():
    for name, layer in LAYERS.items():
        repo = "@swiftpkg_" + layer.package.replace("-", "_") + "//:"
        layer_build(
            name = name,
            testonly = True,
            deps = [repo + product + ".rspm" for product in layer.products] + [repo + target + ".rspm" for target in layer.compile_checks],
        )
        if layer.tests:
            native.test_suite(
                name = name + "-tests",
                tests = [repo + target + ".rspm" for target in layer.tests],
            )

    for name, tests in HOST_TESTS.items():
        repo = "@swiftpkg_" + LAYERS[name].package.replace("-", "_") + "//:"
        native.test_suite(
            name = name + "-host-tests",
            tests = [repo + target + ".rspm" for target in tests],
            tags = ["manual"],
        )

    native.test_suite(
        name = "dependency-tests",
        tests = [":" + name + "-tests" for name, layer in LAYERS.items() if layer.package != "container" and layer.tests],
    )
    native.test_suite(
        name = "container-tests",
        tests = [":" + name + "-tests" for name, layer in LAYERS.items() if layer.package == "container" and layer.tests] + [":semantic-helper-tests"],
    )
    native.test_suite(
        name = "qualified-tests",
        tests = [":dependency-tests", ":container-tests", ":repository-tests"],
    )

    layer_build(
        name = "runtime-integration",
        testonly = True,
        tags = ["manual"],
        deps = ["@swiftpkg_container//:" + target + ".rspm" for target in RUNTIME_TESTS],
    )
    native.test_suite(
        name = "runtime-integration-tests",
        tests = ["@swiftpkg_container//:" + target + ".rspm" for target in RUNTIME_TESTS],
        tags = ["manual"],
    )
