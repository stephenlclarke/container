"""Declared fixtures for upstream tests that assume SwiftPM source layouts."""

TEST_DATA = {
    "swift-argument-parser": {"ArgumentParserUnitTests": [":math.rspm"]},
    "yams": {"YamsTests": ["Tests/YamsTests/Fixtures/SourceKitten#289/debug.yaml"]},
}
TEST_DATA_GLOBS = {
    "swift-crypto": {
        "CryptoTests": ["Tests/Test Vectors/**"],
        "_CryptoExtrasTests": ["Tests/_CryptoExtrasVectors/**", "Tests/Test Vectors/**"],
    },
    "swift-argument-parser": {"ArgumentParserUnitTests": ["Tests/ArgumentParserUnitTests/Snapshots/*"]},
    "swift-http-structured-headers": {"StructuredFieldValuesTests": ["Tests/TestFixtures/**/*.json"]},
}
PATCHES = {
    "swift-nio-transport-services": ["//Tools/bazel:swift-nio-transport-services-host-tests.patch"],
    "async-http-client": ["//Tools/bazel:async-http-client-host-tests.patch"],
"swift-certificates": ["//Tools/bazel:certificates-test-activity.patch"], "swift-argument-parser": ["//Tools/bazel:argument-parser-test-runfiles.patch"]}
