"""Declared fixtures for upstream tests that assume SwiftPM source layouts."""

TEST_DATA = {"swift-argument-parser": {"ArgumentParserUnitTests": [
    "Tests/ArgumentParserUnitTests/Snapshots/.editorconfig",
    "Tests/ArgumentParserUnitTests/Snapshots/testADumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testBDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testBase_Bash().bash",
    "Tests/ArgumentParserUnitTests/Snapshots/testBase_Fish().fish",
    "Tests/ArgumentParserUnitTests/Snapshots/testBase_Zsh().zsh",
    "Tests/ArgumentParserUnitTests/Snapshots/testCDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testDefaultAsFlagCompletion_Bash().bash",
    "Tests/ArgumentParserUnitTests/Snapshots/testDefaultAsFlagCompletion_Fish().fish",
    "Tests/ArgumentParserUnitTests/Snapshots/testDefaultAsFlagCompletion_Zsh().zsh",
    "Tests/ArgumentParserUnitTests/Snapshots/testDefaultAsFlagDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testDefaultAsFlagWithTransformDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testMathAddDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testMathDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testMathMultiplyDumpHelp().json",
    "Tests/ArgumentParserUnitTests/Snapshots/testMathStatsDumpHelp().json",
    ":math.rspm"
]}}
PATCHES = {"swift-argument-parser": ["//Tools/bazel:argument-parser-test-runfiles.patch"]}
