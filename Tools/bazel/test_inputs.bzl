"""Declared fixtures for upstream tests that assume SwiftPM source layouts."""

TEST_DATA = {
    "container": {
        "ContainerVersionTests": ["Package.swift", "Package.resolved"],
        "ContainerCommandsTests": ["Package.resolved"],
        "DockerSemanticHelperTests": ["@@//Tools/ContainerSemanticHelper:payload"],
        "ContainerLoggingProvidersTests": ["@@//Tools/ContainerSemanticHelper:payload"],
        "ContainerAPIServiceTests": ["@@//Tools/ContainerSemanticHelper:payload"],
    },
    "swift-argument-parser": {"ArgumentParserUnitTests": [":math.rspm"]},
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
    "zstd": ["//Tools/bazel:zstd-public-module.patch"],
    "smithy-swift": ["//Tools/bazel:smithy-codegen-resource.patch"],
    "aws-crt-swift": ["//Tools/bazel:aws-crt-offline-tests.patch"],
    "aws-sdk-swift": ["//Tools/bazel:aws-sdk-runtime-tests.patch"],
    "container-engine-api": ["//Tools/bazel:engine-host-identity-tests.patch"],
    "containerization": ["//Tools/bazel:containerization-registry-tests.patch"],
    "swift-nio-transport-services": ["//Tools/bazel:swift-nio-transport-services-host-tests.patch"],
    "async-http-client": ["//Tools/bazel:async-http-client-host-tests.patch"],
    "swift-certificates": ["//Tools/bazel:certificates-test-activity.patch"],
    "swift-argument-parser": ["//Tools/bazel:argument-parser-test-runfiles.patch"],
}

# Seatbelt prevents set-ID mode restoration; these tests assert real file modes.
TEST_TAGS = {
    "containerization": {"ContainerizationArchiveTests": ["no-sandbox"]},
    "container": {"IntegrationTests": ["manual", "no-sandbox", "external"]},
}
