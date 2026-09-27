"""Explicitly admitted layers. Builds and executable tests are separate targets."""

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
}

def declare_layers():
    for name, layer in LAYERS.items():
        repo = "@swiftpkg_" + layer.package.replace("-", "_") + "//:"
        native.filegroup(
            name = name,
            testonly = True,
            srcs = [repo + product + ".rspm" for product in layer.products] + [repo + target + ".rspm" for target in layer.compile_checks],
        )
        native.test_suite(
            name = name + "-tests",
            tests = [repo + target + ".rspm" for target in layer.tests],
        )
