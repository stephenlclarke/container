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
}

# These suites depend on host networking and are requested explicitly.
HOST_TESTS = {
    "engine-service": ["ContainerEngineServiceTests"],
    "engine-session": ["ContainerEngineProviderSessionTests"],
    "engine-core": ["ContainerEngineRuntimeSPITests"],
    "containerization-oci": ["ContainerizationOCITests"],
    "containerization-os": ["ContainerizationOSTests"],
    "nio-transport-services": ["NIOTransportServicesTests"],
    "async-http-client": ["AsyncHTTPClientTests"],
}

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
