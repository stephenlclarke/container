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

import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIClient
@testable import ContainerPersistence

struct ParserTest {
    @Test
    func testPublishPortParserTcp() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortParserUdp() throws {
        let result = try Parser.publishPorts(["192.168.32.36:8000:8080/UDP"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("192.168.32.36")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8000))
        #expect(result[0].containerPort == UInt16(8080))
        #expect(result[0].proto == .udp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortRange() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080-8179:9000-9099/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(9000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 100)
    }

    @Test
    func testPublishPortRangeSingle() throws {
        let result = try Parser.publishPorts(["127.0.0.1:8080-8080:9000-9000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("127.0.0.1")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(9000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortNoHostAddress() throws {
        let result = try Parser.publishPorts(["8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("0.0.0.0")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortNoProtocol() throws {
        let result = try Parser.publishPorts(["8080:8000"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("0.0.0.0")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortParserIPv6() throws {
        let result = try Parser.publishPorts(["[fe80::36f3:5e50:ed71:1bb]:8080:8000/tcp"])
        #expect(result.count == 1)
        let expectedAddress = try IPAddress("fe80::36f3:5e50:ed71:1bb")
        #expect(result[0].hostAddress == expectedAddress)
        #expect(result[0].hostPort == UInt16(8080))
        #expect(result[0].containerPort == UInt16(8000))
        #expect(result[0].proto == .tcp)
        #expect(result[0].count == 1)
    }

    @Test
    func testPublishPortInvalidProtocol() throws {
        #expect {
            _ = try Parser.publishPorts(["8080:8000/sctp"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish protocol")
        }
    }

    @Test
    func testPublishPortInvalidValue() throws {
        #expect {
            _ = try Parser.publishPorts([""])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish value")
        }
    }

    @Test
    func testPublishPortMissingPort() throws {
        #expect {
            _ = try Parser.publishPorts(["1234"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish value")
        }
    }

    @Test
    func testPublishInvalidIPv4Address() throws {
        #expect {
            _ = try Parser.publishPorts(["1234:8080:8000"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish IPv4 address")
        }
    }

    @Test
    func testPublishInvalidIPv6Address() throws {
        #expect {
            _ = try Parser.publishPorts([
                "[1234:5678]:8080:8000",
                "[2001::db8::1]:8080:8080",
                "[2001:db8:85a3::8a2e:370g:7334]:8080:8080",
                "[2001:db8:85a3::][8a2e::7334]:8080:8080",
            ])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish IPv6 address")
        }
    }

    @Test
    func testPublishPortInvalidHostPort() throws {
        #expect {
            _ = try Parser.publishPorts(["65536:1234"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortInvalidContainerPort() throws {
        #expect {
            _ = try Parser.publishPorts(["1234:65536"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeMismatch() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8000:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("counts are not equal")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["65536-65537:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeZeroHostPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["0-1:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortEnd() throws {
        #expect {
            _ = try Parser.publishPorts(["65535-65536:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidHostPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001-8002:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeNegativeHostPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8001-8000:9000-9001"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish host port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:65536-65537"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeZeroContainerPortStart() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:0-1"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortEnd() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:65535-65536"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeInvalidContainerPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:9000-9001-9002"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testPublishPortRangeNegativeContainerPortRange() throws {
        #expect {
            _ = try Parser.publishPorts(["8000-8001:9001-9000"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid publish container port")
        }
    }

    @Test
    func testRelativePaths() throws {
        // Test bind mount with relative path "."
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let result = try Parser.mount("type=bind,src=.,dst=/foo", relativeTo: tempDir)

            switch result {
            case .filesystem(let fs):
                #expect(fs.source == tempDir.standardizedFileURL.path)
                #expect(fs.destination == "/foo")
                #expect(!fs.isVolume)
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with relative path "./"
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-rel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let result = try Parser.volume("./:/foo", relativeTo: tempDir)

            switch result {
            case .filesystem(let fs):
                let expectedPath = tempDir.standardizedFileURL.path
                // Normalize trailing slashes for comparison
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/foo")
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with nested relative path "./subdir"
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-rel-nested-\(UUID().uuidString)")
            let nestedDir = tempDir.appendingPathComponent("subdir")
            try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let result = try Parser.volume("./subdir:/foo", relativeTo: tempDir)

            switch result {
            case .filesystem(let fs):
                let expectedPath = nestedDir.standardizedFileURL.path
                // Normalize trailing slashes for comparison
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/foo")
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with bare "." as source (current directory)
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-dot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let result = try Parser.volume(".:/docs:ro", relativeTo: tempDir)

            switch result {
            case .filesystem(let fs):
                let expectedPath = tempDir.standardizedFileURL.path
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/docs")
                #expect(fs.options.contains("ro"))
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }

        // Test volume with ".." as source (parent directory)
        do {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-volume-dotdot-\(UUID().uuidString)")
            let childDir = tempDir.appendingPathComponent("child")
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            let result = try Parser.volume("..:/data", relativeTo: childDir)

            switch result {
            case .filesystem(let fs):
                let expectedPath = tempDir.standardizedFileURL.path
                #expect(fs.source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expectedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                #expect(fs.destination == "/data")
            case .volume:
                #expect(Bool(false), "Expected filesystem mount, got volume")
            }
        }
    }

    @Test
    func testMountBindAbsolutePath() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-abs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let result = try Parser.mount("type=bind,src=\(tempDir.path),dst=/foo")

        switch result {
        case .filesystem(let fs):
            #expect(fs.source == tempDir.path)
            #expect(fs.destination == "/foo")
            #expect(!fs.isVolume)
        case .volume:
            #expect(Bool(false), "Expected filesystem mount, got volume")
        }
    }

    @Test
    func testVolumeBindPropagationOption() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-bind-propagation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let result = try Parser.volume("\(tempDir.path):/host:ro,rslave")

        switch result {
        case .filesystem(let fs):
            #expect(fs.source == tempDir.path)
            #expect(fs.destination == "/host")
            #expect(fs.options == ["ro", "rslave"])
        case .volume:
            #expect(Bool(false), "Expected filesystem mount, got volume")
        }
    }

    @Test
    func testMountVolumeValidName() throws {
        let result = try Parser.mount("type=volume,src=myvolume,dst=/data")

        switch result {
        case .filesystem:
            #expect(Bool(false), "Expected volume mount, got filesystem")
        case .volume(let vol):
            #expect(vol.name == "myvolume")
            #expect(vol.destination == "/data")
        }
    }

    @Test
    func testMountVolumeInvalidName() throws {
        #expect {
            _ = try Parser.mount("type=volume,src=.,dst=/data")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid volume name")
        }
    }

    @Test
    func testMountBindNonExistentPath() throws {
        #expect {
            _ = try Parser.mount("type=bind,src=/nonexistent/path,dst=/foo")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("path") && error.description.contains("does not exist")
        }
    }

    @Test
    func testMountBindFileInsteadOfDirectory() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-file-\(UUID().uuidString)")
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        #expect {
            _ = try Parser.mount("type=bind,src=\(tempFile.path),dst=/foo")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("path") && error.description.contains("is not a directory")
        }
    }

    @Test
    func testIsValidDomainNameOk() throws {
        let names = [
            "a",
            "a.b",
            "foo.bar",
            "F-O.B-R",
            [
                String(repeating: "0", count: 63),
                String(repeating: "1", count: 63),
                String(repeating: "2", count: 63),
                String(repeating: "3", count: 63),
            ].joined(separator: "."),
        ]
        for name in names {
            #expect(Parser.isValidDomainName(name))
        }
    }

    @Test
    func testIsValidDomainNameBad() throws {
        let names = [
            ".foo",
            "foo.",
            ".foo.bar",
            "foo.bar.",
            "-foo.bar",
            "foo.bar-",
            [
                String(repeating: "0", count: 63),
                String(repeating: "1", count: 63),
                String(repeating: "2", count: 63),
                String(repeating: "3", count: 62),
                "4",
            ].joined(separator: "."),
        ]
        for name in names {
            #expect(!Parser.isValidDomainName(name))
        }
    }

    // MARK: - Environment Variable Tests

    @Test
    func testEnvExplicitValue() throws {
        let result = Parser.env(envList: ["FOO=bar", "BAZ=qux"])
        #expect(result == ["FOO=bar", "BAZ=qux"])
    }

    @Test
    func testEnvImplicitInheritance() throws {
        guard let homeValue = ProcessInfo.processInfo.environment["PATH"] else {
            Issue.record("PATH environment variable not set")
            return
        }

        let result = Parser.env(envList: ["PATH"])
        #expect(result == ["PATH=\(homeValue)"])
    }

    @Test
    func testEnvImplicitUndefinedVariable() throws {
        // A variable that doesn't exist should be silently skipped
        let result = Parser.env(envList: ["THIS_VAR_DEFINITELY_DOES_NOT_EXIST_12345"])
        #expect(result.isEmpty)
    }

    @Test
    func testEnvMixedExplicitAndImplicit() throws {
        guard let homeValue = ProcessInfo.processInfo.environment["HOME"] else {
            Issue.record("HOME environment variable not set")
            return
        }

        let result = Parser.env(envList: ["FOO=bar", "HOME", "BAZ=qux"])
        #expect(result == ["FOO=bar", "HOME=\(homeValue)", "BAZ=qux"])
    }

    @Test
    func testEnvEmptyValue() throws {
        // Explicit empty value should be preserved
        let result = Parser.env(envList: ["EMPTY="])
        #expect(result == ["EMPTY="])
    }

    @Test
    func testAllEnvUserOverridesImage() throws {
        let result = try Parser.allEnv(
            imageEnvs: ["FOO=fromimage", "BAR=kept"],
            envFiles: [],
            envs: ["FOO=fromuser"]
        )
        #expect(Set(result) == Set(["FOO=fromuser", "BAR=kept"]))
    }

    @Test
    func testAllEnvFileOverridesImage() throws {
        let tmpFile = try tmpFileWithContent("FOO=fromfile\n")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let result = try Parser.allEnv(
            imageEnvs: ["FOO=fromimage", "BAR=kept"],
            envFiles: [tmpFile.path],
            envs: []
        )
        #expect(Set(result) == Set(["FOO=fromfile", "BAR=kept"]))
    }

    @Test
    func testAllEnvUserOverridesFileOverridesImage() throws {
        let tmpFile = try tmpFileWithContent("FOO=fromfile\nBAZ=fromfile\n")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let result = try Parser.allEnv(
            imageEnvs: ["FOO=fromimage", "BAR=fromimage"],
            envFiles: [tmpFile.path],
            envs: ["FOO=fromuser"]
        )
        #expect(Set(result) == Set(["FOO=fromuser", "BAR=fromimage", "BAZ=fromfile"]))
    }

    private func tmpFileWithContent(_ content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("envfile-test-\(UUID().uuidString)")
        try content.write(to: tempFile, atomically: true, encoding: .utf8)
        return tempFile
    }

    // NOTE: A lot of these env-file tests are recreations of the docker cli's unit tests for their
    // env-file support.

    @Test
    func testParseEnvFileGoodFile() throws {
        var content = """
            foo=bar
                baz=quux
            # comment

            _foobar=foobaz
            with.dots=working
            and_underscore=working too
            """
        content += "\n    \t  "

        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)

        let expectedLines = [
            "foo=bar",
            "baz=quux",
            "_foobar=foobaz",
            "with.dots=working",
            "and_underscore=working too",
        ]

        #expect(lines == expectedLines)
    }

    @Test
    func testParseEnvFileMultipleEqualsSigns() throws {
        let content = """
            URL=https://foo.bar?baz=woo
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)

        let expectedLines = [
            "URL=https://foo.bar?baz=woo"
        ]

        #expect(lines == expectedLines)
    }

    @Test
    func testParseEnvFileEmptyFile() throws {
        let tmpFile = try tmpFileWithContent("")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let lines = try Parser.envFile(path: tmpFile.path)
        #expect(lines.isEmpty)
    }

    @Test
    func testParseEnvFileNonExistentFile() throws {
        #expect {
            _ = try Parser.envFile(path: "/nonexistent/foo_bar_baz")
        } throws: { error in
            guard let error = error as? ContainerizationError,
                let cause = error.cause
            else {
                return false
            }
            return String(describing: cause).contains("No such file or directory")
        }
    }

    @Test
    func testParseEnvFileBadlyFormattedFile() throws {
        let content = """
            foo=bar
                f   =quux
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("contains whitespaces")
        }
    }

    @Test
    func testParseEnvFileRandomFile() throws {
        let content = """
            first line
            another invalid line
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("first line") && error.description.contains("contains whitespaces")
        }
    }

    @Test
    func testParseEnvVariableDefinitionsFile() throws {
        let content = """
            # comment=
            UNDEFINED_VAR
            HOME
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let variables = try Parser.envFile(path: tmpFile.path)

        // HOME should be imported from environment
        guard let homeValue = ProcessInfo.processInfo.environment["HOME"] else {
            Issue.record("HOME environment variable not set")
            return
        }

        #expect(variables.count == 1)
        #expect(variables[0] == "HOME=\(homeValue)")
    }

    @Test
    func testParseEnvVariableWithNoNameFile() throws {
        let content = """
            # comment=
            =blank variable names are an error case
            """
        let tmpFile = try tmpFileWithContent(content)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        #expect {
            _ = try Parser.envFile(path: tmpFile.path)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("no variable name")
        }
    }

    @Test
    func testParseEnvFileFromNamedPipe() throws {
        let pipePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("envfile-pipe-\(UUID().uuidString)")

        // Create a named pipe (FIFO)
        let result = mkfifo(pipePath.path, 0o600)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        defer { try? FileManager.default.removeItem(at: pipePath) }

        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            do {
                let handle = try FileHandle(forWritingTo: pipePath)
                try handle.write(contentsOf: "SECRET_KEY=value123\n".data(using: .utf8)!)
                try handle.close()
            } catch {
                Issue.record(error)
            }
            group.leave()
        }

        // Read from pipe (blocks until writer connects)
        let lines = try Parser.envFile(path: pipePath.path)

        // Wait for write to complete
        group.wait()

        #expect(lines == ["SECRET_KEY=value123"])
    }

    // MARK: Network Parser Tests

    @Test
    func testParseNetworkSimpleName() throws {
        let result = try Parser.network("default")
        #expect(result.name == "default")
        #expect(result.aliases == [])
        #expect(result.macAddress == nil)
    }

    @Test
    func testParseNetworkWithMACAddress() throws {
        let result = try Parser.network("backend,mac=02:42:ac:11:00:02")
        #expect(result.name == "backend")
        #expect(result.aliases == [])
        #expect(result.macAddress == "02:42:ac:11:00:02")
    }

    @Test
    func testParseNetworkWithAliases() throws {
        let result = try Parser.network("backend,alias=api,alias=api.internal")

        #expect(result.name == "backend")
        #expect(result.aliases == ["api", "api.internal"])
    }

    @Test
    func testParseNetworkDeduplicatesAliases() throws {
        let result = try Parser.network("backend,alias=api,alias=api,alias=web")

        #expect(result.name == "backend")
        #expect(result.aliases == ["api", "web"])
    }

    @Test
    func testParseNetworkWithMACAddressHyphenSeparator() throws {
        let result = try Parser.network("backend,mac=02-42-ac-11-00-02")
        #expect(result.name == "backend")
        #expect(result.macAddress == "02-42-ac-11-00-02")
    }

    @Test
    func testHostNetworkParserAcceptsHost() throws {
        #expect(try Parser.hostNetwork(["host"]))
        #expect(try !Parser.hostNetwork(["default"]))
        #expect(try !Parser.hostNetwork([]))
    }

    @Test
    func testHostNetworkParserRejectsAttachmentProperties() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostNetwork(["host,alias=api"])
        }
    }

    @Test
    func testParseNetworkEmptyString() throws {
        #expect {
            _ = try Parser.network("")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("network specification cannot be empty")
        }
    }

    @Test
    func testParseNetworkEmptyName() throws {
        #expect {
            _ = try Parser.network(",mac=02:42:ac:11:00:02")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("network name cannot be empty")
        }
    }

    @Test
    func testParseNetworkEmptyMACAddress() throws {
        #expect {
            _ = try Parser.network("backend,mac=")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("mac address value cannot be empty")
        }
    }

    @Test
    func testParseNetworkEmptyAlias() throws {
        #expect {
            _ = try Parser.network("backend,alias=")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid network alias value: hostname is empty")
        }
    }

    @Test
    func testParseNetworkUnknownProperty() throws {
        #expect {
            _ = try Parser.network("backend,unknown=value")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("unknown network property") && error.description.contains("unknown")
        }
    }

    @Test
    func testParseNetworkInvalidPropertyFormat() throws {
        #expect {
            _ = try Parser.network("backend,invalidproperty")
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid property format")
        }
    }

    // MARK: - Relative Path Passthrough Tests

    @Test
    func testProcessEntrypointRelativePathPassthrough() throws {
        let processFlags = try Flags.Process.parse(["--cwd", "/bin"])
        let managementFlags = try Flags.Management.parse(["--entrypoint", "./uname"])

        let result = try Parser.process(
            arguments: [],
            processFlags: processFlags,
            managementFlags: managementFlags,
            config: nil
        )

        #expect(result.executable == "./uname")
        #expect(result.workingDirectory == "/bin")
    }

    @Test
    func testProcessPrivilegedFlag() throws {
        let processFlags = try Flags.Process.parse(["--privileged"])
        let managementFlags = try Flags.Management.parse([])

        let result = try Parser.process(
            arguments: ["id"],
            processFlags: processFlags,
            managementFlags: managementFlags,
            config: nil
        )

        #expect(result.executable == "id")
        #expect(result.privileged)
    }

    @Test
    func testUlimitParserSoftAndHard() throws {
        let result = try Parser.rlimits(["nofile=1024:2048"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[0].soft == 1024)
        #expect(result[0].hard == 2048)
    }

    @Test
    func testUlimitParserSingleValue() throws {
        let result = try Parser.rlimits(["nproc=512"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NPROC")
        #expect(result[0].soft == 512)
        #expect(result[0].hard == 512)
    }

    @Test
    func testUlimitParserUnlimited() throws {
        let result = try Parser.rlimits(["memlock=unlimited"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_MEMLOCK")
        #expect(result[0].soft == UInt64.max)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testLogDriverParserDefaultsToLocal() throws {
        let logging = try Parser.logging(driver: nil)

        #expect(logging == .default)
    }

    @Test
    func testLogDriverParserAcceptsJSONFileAsLocalCapture() throws {
        let logging = try Parser.logging(driver: "json-file")

        #expect(logging == .default)
    }

    @Test
    func testLogDriverParserAcceptsLocalRotationOptions() throws {
        let logging = try Parser.logging(driver: "local", options: ["max-size=10m", "max-file=3"])

        #expect(logging.storage == .local)
        #expect(logging.maxSizeInBytes == 10 * 1024 * 1024)
        #expect(logging.maxFileCount == 3)
    }

    @Test
    func testLogDriverParserAcceptsJSONFileRotationOptions() throws {
        let logging = try Parser.logging(driver: "json-file", options: ["max-file=2"])

        #expect(logging.storage == .local)
        #expect(logging.maxFileCount == 2)
    }

    @Test
    func testLogDriverParserAcceptsDefaultRotationOptions() throws {
        let logging = try Parser.logging(driver: nil, options: ["max-size=512b"])

        #expect(logging.storage == .local)
        #expect(logging.maxSizeInBytes == 512)
        #expect(logging.maxFileCount == nil)
    }

    @Test
    func testLogDriverParserAcceptsNone() throws {
        let logging = try Parser.logging(driver: "none")

        #expect(logging.storage == .none)
    }

    @Test
    func testLogDriverParserRejectsOptionsWithNone() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "none", options: ["max-size=10m"])
        }
        #expect(error?.message == "log options are not supported with log driver 'none'")
    }

    @Test
    func testLogDriverParserRejectsUnsupportedDrivers() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "syslog")
        }
        #expect(error?.message == "unsupported log driver 'syslog' (supported: json-file, local, none)")
    }

    @Test
    func testLogDriverParserRejectsUnsupportedOptions() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "local", options: ["mode=blocking"])
        }
        #expect(error?.message == "unsupported log option 'mode' (supported for local logging: max-size, max-file)")
    }

    @Test
    func testLogDriverParserRejectsMalformedOptions() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "local", options: ["max-size"])
        }
        #expect(error?.message == "invalid log option 'max-size' (expected key=value)")
    }

    @Test
    func testLogDriverParserRejectsInvalidRotationValues() throws {
        let sizeError = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "local", options: ["max-size=0"])
        }
        #expect(sizeError?.message == "invalid log option max-size '0'")

        let fileError = #expect(throws: ContainerizationError.self) {
            _ = try Parser.logging(driver: "local", options: ["max-file=0"])
        }
        #expect(fileError?.message == "invalid log option max-file '0'")
    }

    @Test
    func testRestartPolicyParserDefaultsToNo() throws {
        let policy = try Parser.restartPolicy(nil)

        #expect(policy == .no)
    }

    @Test
    func testRestartPolicyParserAcceptsDockerValues() throws {
        let always = try Parser.restartPolicy("always")
        let unlessStopped = try Parser.restartPolicy("unless-stopped")
        let onFailure = try Parser.restartPolicy("on-failure:3")
        let onFailureUnlimited = try Parser.restartPolicy("on-failure:0")

        #expect(always.mode == .always)
        #expect(always.maximumRetryCount == nil)
        #expect(unlessStopped.mode == .unlessStopped)
        #expect(unlessStopped.maximumRetryCount == nil)
        #expect(onFailure.mode == .onFailure)
        #expect(onFailure.maximumRetryCount == 3)
        #expect(onFailureUnlimited.mode == .onFailure)
        #expect(onFailureUnlimited.maximumRetryCount == nil)
    }

    @Test
    func testCreateOptionsParsesRestartTiming() throws {
        let options = try Parser.createOptions(
            autoRemove: false,
            restart: "on-failure:3",
            restartDelay: "5s",
            restartWindow: "30s"
        )

        #expect(options.restartPolicy.mode == .onFailure)
        #expect(options.restartPolicy.maximumRetryCount == 3)
        #expect(options.restartPolicy.retryDelayInNanoseconds == 5_000_000_000)
        #expect(options.restartPolicy.successfulRunDurationInNanoseconds == 30_000_000_000)
    }

    @Test
    func testRestartPolicyParserRejectsInvalidValues() throws {
        let invalidMode = #expect(throws: ContainerizationError.self) {
            _ = try Parser.restartPolicy("sometimes")
        }
        #expect(invalidMode?.message == "unsupported restart policy 'sometimes' (supported: no, on-failure[:max-retries], always, unless-stopped)")

        let invalidRetry = #expect(throws: ContainerizationError.self) {
            _ = try Parser.restartPolicy("on-failure:-1")
        }
        #expect(invalidRetry?.message == "invalid restart policy 'on-failure:-1'")

        let invalidModeRetry = #expect(throws: ContainerizationError.self) {
            _ = try Parser.restartPolicy("always:3")
        }
        #expect(invalidModeRetry?.message == "restart retry count is only supported with on-failure")
    }

    @Test
    func testCreateOptionsRejectsInvalidRestartTiming() throws {
        let missingPolicy = #expect(throws: ContainerizationError.self) {
            _ = try Parser.createOptions(autoRemove: false, restart: nil, restartDelay: "5s")
        }
        #expect(missingPolicy?.message == "restart timing options require --restart")

        let invalidDelay = #expect(throws: ContainerizationError.self) {
            _ = try Parser.createOptions(autoRemove: false, restart: "always", restartDelay: "never")
        }
        #expect(invalidDelay?.message == "invalid --restart-delay duration 'never'")

        let invalidWindow = #expect(throws: ContainerizationError.self) {
            _ = try Parser.createOptions(autoRemove: false, restart: "always", restartWindow: "-1s")
        }
        #expect(invalidWindow?.message == "invalid --restart-window duration '-1s'")
    }

    @Test
    func testCreateOptionsRejectsRemoveWithRestartPolicy() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.createOptions(autoRemove: true, restart: "always")
        }

        #expect(error?.message == "--rm cannot be combined with --restart")
    }

    @Test
    func testHealthCheckParserBuildsShellProbe() throws {
        let baseProcess = ProcessConfiguration(
            executable: "server",
            arguments: [],
            environment: ["PATH=/usr/bin"],
            workingDirectory: "/srv",
            user: .raw(userString: "app")
        )

        let healthCheck = try #require(
            try Parser.healthCheck(
                command: "test -f /tmp/ready",
                interval: "5s",
                retries: 2,
                startInterval: "500ms",
                startPeriod: "1m30s",
                timeout: "250ms",
                disabled: false,
                baseProcess: baseProcess
            ))

        #expect(healthCheck.process.executable == "/bin/sh")
        #expect(healthCheck.process.arguments == ["-c", "test -f /tmp/ready"])
        #expect(healthCheck.process.environment == ["PATH=/usr/bin"])
        #expect(healthCheck.process.workingDirectory == "/srv")
        #expect(healthCheck.process.user.description == "app")
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.retries == 2)
        #expect(healthCheck.startIntervalInNanoseconds == 500_000_000)
        #expect(healthCheck.startPeriodInNanoseconds == 90_000_000_000)
        #expect(healthCheck.timeoutInNanoseconds == 250_000_000)
    }

    @Test
    func testHealthCheckParserReturnsNilWithoutProbe() throws {
        let healthCheck = try Parser.healthCheck(
            command: nil,
            interval: nil,
            retries: nil,
            startInterval: nil,
            startPeriod: nil,
            timeout: nil,
            disabled: false,
            baseProcess: ProcessConfiguration(executable: "server", arguments: [], environment: [])
        )

        #expect(healthCheck == nil)
    }

    @Test
    func testHealthCheckParserRejectsOptionsWithoutProbe() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.healthCheck(
                command: nil,
                interval: "30s",
                retries: nil,
                startInterval: nil,
                startPeriod: nil,
                timeout: nil,
                disabled: false,
                baseProcess: ProcessConfiguration(executable: "server", arguments: [], environment: [])
            )
        }

        #expect(error?.message == "health check options require --health-cmd")
    }

    @Test
    func testHealthCheckParserRejectsDisabledWithProbeOptions() throws {
        let error = #expect(throws: ContainerizationError.self) {
            _ = try Parser.healthCheck(
                command: "true",
                interval: nil,
                retries: nil,
                startInterval: nil,
                startPeriod: nil,
                timeout: nil,
                disabled: true,
                baseProcess: ProcessConfiguration(executable: "server", arguments: [], environment: [])
            )
        }

        #expect(error?.message == "--no-healthcheck cannot be combined with health check options")
    }

    @Test
    func testUlimitParserUnlimitedHardOnly() throws {
        let result = try Parser.rlimits(["stack=8192:unlimited"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_STACK")
        #expect(result[0].soft == 8192)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testUlimitParserMinusOneAsUnlimited() throws {
        let result = try Parser.rlimits(["core=-1"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_CORE")
        #expect(result[0].soft == UInt64.max)
        #expect(result[0].hard == UInt64.max)
    }

    @Test
    func testUlimitParserMultipleUlimits() throws {
        let result = try Parser.rlimits(["nofile=1024:2048", "nproc=256", "cpu=60:120"])
        #expect(result.count == 3)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[1].limit == "RLIMIT_NPROC")
        #expect(result[2].limit == "RLIMIT_CPU")
    }

    @Test
    func testUlimitParserAllSupportedTypes() throws {
        let types = ["core", "cpu", "data", "fsize", "memlock", "nofile", "nproc", "rss", "stack"]
        let expectedRlimits = [
            "RLIMIT_CORE", "RLIMIT_CPU", "RLIMIT_DATA", "RLIMIT_FSIZE",
            "RLIMIT_MEMLOCK", "RLIMIT_NOFILE", "RLIMIT_NPROC", "RLIMIT_RSS", "RLIMIT_STACK",
        ]

        for (i, type) in types.enumerated() {
            let result = try Parser.rlimits(["\(type)=100"])
            #expect(result.count == 1)
            #expect(result[0].limit == expectedRlimits[i])
        }
    }

    @Test
    func testUlimitParserCaseInsensitive() throws {
        let result = try Parser.rlimits(["NOFILE=1024", "Nproc=512"])
        #expect(result.count == 2)
        #expect(result[0].limit == "RLIMIT_NOFILE")
        #expect(result[1].limit == "RLIMIT_NPROC")
    }

    @Test
    func testUlimitParserInvalidFormat() throws {
        #expect {
            _ = try Parser.rlimits(["nofile"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid ulimit format")
        }
    }

    @Test
    func testUlimitParserUnsupportedType() throws {
        #expect {
            _ = try Parser.rlimits(["foo=100"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("unsupported ulimit type")
        }
    }

    @Test
    func testUlimitParserSoftExceedsHard() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=2048:1024"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("soft limit") && error.description.contains("cannot exceed hard limit")
        }
    }

    @Test
    func testUlimitParserDuplicateType() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=1024", "nofile=2048"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("duplicate ulimit type")
        }
    }

    @Test
    func testUlimitParserInvalidValue() throws {
        #expect {
            _ = try Parser.rlimits(["nofile=abc"])
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("invalid ulimit value")
        }
    }

    @Test
    func testUlimitParserEmptyArray() throws {
        let result = try Parser.rlimits([])
        #expect(result.isEmpty)
    }

    @Test
    func testUlimitParserZeroValue() throws {
        let result = try Parser.rlimits(["core=0"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_CORE")
        #expect(result[0].soft == 0)
        #expect(result[0].hard == 0)
    }

    @Test
    func testUlimitParserLargeValues() throws {
        let result = try Parser.rlimits(["nproc=\(UInt64.max - 1):\(UInt64.max)"])
        #expect(result.count == 1)
        #expect(result[0].limit == "RLIMIT_NPROC")
        #expect(result[0].soft == UInt64.max - 1)
        #expect(result[0].hard == UInt64.max)
    }

    // MARK: - Capabilities Parser Tests

    @Test
    func testCapabilitiesParserEmpty() throws {
        let result = try Parser.capabilities(capAdd: [], capDrop: [])
        #expect(result.capAdd.isEmpty)
        #expect(result.capDrop.isEmpty)
    }

    @Test
    func testCapabilitiesParserAddSingle() throws {
        let result = try Parser.capabilities(capAdd: ["CAP_NET_RAW"], capDrop: [])
        #expect(result.capAdd == ["CAP_NET_RAW"])
        #expect(result.capDrop.isEmpty)
    }

    @Test
    func testCapabilitiesParserDropSingle() throws {
        let result = try Parser.capabilities(capAdd: [], capDrop: ["CAP_MKNOD"])
        #expect(result.capAdd.isEmpty)
        #expect(result.capDrop == ["CAP_MKNOD"])
    }

    @Test
    func testCapabilitiesParserWithoutPrefix() throws {
        let result = try Parser.capabilities(capAdd: ["NET_RAW"], capDrop: ["MKNOD"])
        #expect(result.capAdd == ["CAP_NET_RAW"])
        #expect(result.capDrop == ["CAP_MKNOD"])
    }

    @Test
    func testCapabilitiesParserCaseInsensitive() throws {
        let result = try Parser.capabilities(capAdd: ["net_raw"], capDrop: ["mknod"])
        #expect(result.capAdd == ["CAP_NET_RAW"])
        #expect(result.capDrop == ["CAP_MKNOD"])
    }

    @Test
    func testCapabilitiesParserLowercaseWithPrefix() throws {
        let result = try Parser.capabilities(capAdd: ["cap_net_raw"], capDrop: [])
        #expect(result.capAdd == ["CAP_NET_RAW"])
    }

    @Test
    func testCapabilitiesParserALL() throws {
        let result = try Parser.capabilities(capAdd: ["ALL"], capDrop: ["ALL"])
        #expect(result.capAdd == ["ALL"])
        #expect(result.capDrop == ["ALL"])
    }

    @Test
    func testCapabilitiesParserDropALLWithAdd() throws {
        let result = try Parser.capabilities(capAdd: ["CAP_NET_RAW", "CAP_MKNOD"], capDrop: ["ALL"])
        #expect(result.capAdd == ["CAP_NET_RAW", "CAP_MKNOD"])
        #expect(result.capDrop == ["ALL"])
    }

    @Test
    func testCapabilitiesParserAddALLWithDrop() throws {
        let result = try Parser.capabilities(capAdd: ["ALL"], capDrop: ["CAP_NET_ADMIN"])
        #expect(result.capAdd == ["ALL"])
        #expect(result.capDrop == ["CAP_NET_ADMIN"])
    }

    @Test
    func testCapabilitiesParserMultiple() throws {
        let result = try Parser.capabilities(
            capAdd: ["CAP_NET_RAW", "CAP_SYS_ADMIN"],
            capDrop: ["CAP_MKNOD", "CAP_CHOWN"]
        )
        #expect(result.capAdd.count == 2)
        #expect(result.capAdd.contains("CAP_NET_RAW"))
        #expect(result.capAdd.contains("CAP_SYS_ADMIN"))
        #expect(result.capDrop.count == 2)
        #expect(result.capDrop.contains("CAP_MKNOD"))
        #expect(result.capDrop.contains("CAP_CHOWN"))
    }

    @Test
    func testCapabilitiesParserInvalidAdd() throws {
        #expect {
            _ = try Parser.capabilities(capAdd: ["CHWOWZERS"], capDrop: [])
        } throws: { _ in
            true
        }
    }

    @Test
    func testCapabilitiesParserInvalidDrop() throws {
        #expect {
            _ = try Parser.capabilities(capAdd: [], capDrop: ["CHWOWZERS"])
        } throws: { _ in
            true
        }
    }

    // MARK: - Parser.resources

    @Test func testResourcesCustomDefaults() throws {
        let result = try Parser.resources(
            cpus: nil, memory: nil,
            defaultCPUs: 2, defaultMemory: try MemorySize("2048MB")
        )
        #expect(result.cpus == 2)
        #expect(result.memoryInBytes == 2048.mib())
    }

    @Test func testResourcesFlagOverridesDefaults() throws {
        let result = try Parser.resources(cpus: 1, memory: "256m", defaultCPUs: 8, defaultMemory: MemorySize("2g"))
        #expect(result.cpus == 1)
        #expect(result.memoryInBytes == 256.mib())
    }

    @Test func testSysctlsParsesNameValuePairs() throws {
        let result = try Parser.sysctls([
            "net.ipv4.ip_forward=1",
            "kernel.msgmax=65536",
        ])

        #expect(
            result == [
                "net.ipv4.ip_forward": "1",
                "kernel.msgmax": "65536",
            ])
    }

    @Test func testSysctlsLastDuplicateWins() throws {
        let result = try Parser.sysctls([
            "net.ipv4.ip_forward=0",
            "net.ipv4.ip_forward=1",
        ])

        #expect(result["net.ipv4.ip_forward"] == "1")
    }

    @Test func testSysctlsRejectsMissingValueSeparator() throws {
        #expect {
            _ = try Parser.sysctls(["net.ipv4.ip_forward"])
        } throws: { _ in
            true
        }
    }

    @Test func testSysctlsRejectsEmptyName() throws {
        #expect {
            _ = try Parser.sysctls(["=1"])
        } throws: { _ in
            true
        }
    }

    @Test func testBlockIOSpecsCombined() throws {
        let parsed = try Parser.blockIO(specs: [
            "weight=500,leaf-weight=300",
            "device=/dev/null,weight=700,leaf-weight=400",
            "device=/dev/null,read-bps=1mb,write-bps=2mb",
            "device=/dev/null,read-iops=1000,write-iops=2000",
        ])
        let blockIO = try #require(parsed)

        #expect(blockIO.weight == 500)
        #expect(blockIO.leafWeight == 300)
        #expect(blockIO.weightDevice.first?.weight == 700)
        #expect(blockIO.weightDevice.first?.leafWeight == 400)
        #expect(blockIO.throttleReadBpsDevice.first?.rate == 1.mib())
        #expect(blockIO.throttleWriteBpsDevice.first?.rate == 2.mib())
        #expect(blockIO.throttleReadIOPSDevice.first?.rate == 1000)
        #expect(blockIO.throttleWriteIOPSDevice.first?.rate == 2000)
    }

    @Test func testBlockIOAcceptsMajorMinorLiteral() throws {
        let parsed = try Parser.blockIO(specs: ["device=8:0,weight=600,read-bps=512kb"])
        let blockIO = try #require(parsed)
        let weightDevice = try #require(blockIO.weightDevice.first)

        #expect(weightDevice.major == 8)
        #expect(weightDevice.minor == 0)
        #expect(weightDevice.weight == 600)
        #expect(blockIO.throttleReadBpsDevice.first?.rate == 512 * 1024)
    }

    @Test func testBlockIORejectsInvalidWeight() throws {
        #expect {
            _ = try Parser.blockIO(specs: ["weight=1"])
        } throws: { _ in
            true
        }
    }

    @Test func testBlockIORejectsUnknownKey() throws {
        #expect {
            _ = try Parser.blockIO(specs: ["device=/dev/null,bogus=1"])
        } throws: { _ in
            true
        }
    }

    @Test func testBlockIORejectsGlobalKeyOnDeviceSpec() throws {
        #expect {
            _ = try Parser.blockIO(specs: ["read-bps=1mb"])
        } throws: { _ in
            true
        }
    }

    @Test func testDeviceCgroupRulesParse() throws {
        let rules = try Parser.deviceCgroupRules([
            "c 1:3 mr",
            "a *:* rwm",
        ])

        #expect(rules.count == 2)
        #expect(rules[0].allow)
        #expect(rules[0].type == "c")
        #expect(rules[0].major == 1)
        #expect(rules[0].minor == 3)
        #expect(rules[0].access == "mr")
        #expect(rules[1].allow)
        #expect(rules[1].type == "a")
        #expect(rules[1].major == nil)
        #expect(rules[1].minor == nil)
        #expect(rules[1].access == "rwm")
    }

    @Test func testDeviceCgroupRulesRejectInvalidType() throws {
        #expect {
            _ = try Parser.deviceCgroupRules(["x 1:3 rwm"])
        } throws: { _ in
            true
        }
    }

    @Test func testDeviceCgroupRulesRejectInvalidDevice() throws {
        #expect {
            _ = try Parser.deviceCgroupRules(["c 1 rwm"])
        } throws: { _ in
            true
        }
    }

    @Test func testDeviceCgroupRulesRejectInvalidAccess() throws {
        #expect {
            _ = try Parser.deviceCgroupRules(["c 1:3 z"])
        } throws: { _ in
            true
        }
    }

    @Test func testDevicesParseDockerPathForms() throws {
        let devices = try Parser.devices([
            "/dev/null",
            "/dev/null:/dev/xnull",
            "/dev/null:/dev/xnull:rw",
            "/dev/null:mr",
        ])

        #expect(devices == [
            ParsedDeviceMapping(source: "/dev/null", target: "/dev/null", permissions: "rwm"),
            ParsedDeviceMapping(source: "/dev/null", target: "/dev/xnull", permissions: "rwm"),
            ParsedDeviceMapping(source: "/dev/null", target: "/dev/xnull", permissions: "rw"),
            ParsedDeviceMapping(source: "/dev/null", target: "/dev/null", permissions: "mr"),
        ])
    }

    @Test func testDevicesRejectRelativeHostPath() throws {
        #expect {
            _ = try Parser.devices(["dev/null:/dev/xnull"])
        } throws: { _ in
            true
        }
    }

    @Test func testDevicesRejectRelativeContainerPath() throws {
        #expect {
            _ = try Parser.devices(["/dev/null:xnull:rwm"])
        } throws: { _ in
            true
        }
    }

    @Test func testDevicesRejectInvalidPermissions() throws {
        #expect {
            _ = try Parser.devices(["/dev/null:/dev/xnull:z"])
        } throws: { _ in
            true
        }
    }

    @Test func testResourcesBuildPropertyLookup() async throws {
        let content = """
            [build]
            cpus = 8
            memory = "4g"
            """
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-build-lookup.toml")
        FileManager.default.createFile(atPath: tempFile.path(), contents: Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempFile.path(percentEncoded: false))])
        let result = try Parser.resources(
            cpus: nil, memory: nil,
            defaultCPUs: config.build.cpus,
            defaultMemory: config.build.memory
        )
        #expect(result.cpus == 8)
        #expect(result.memoryInBytes == 4096.mib())
    }

    @Test func testResourcesCPUsFromProperty() async throws {
        let content = """
            [container]
            cpus = 8
            """
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-cpus-property.toml")
        FileManager.default.createFile(atPath: tempFile.path(), contents: Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempFile.path(percentEncoded: false))])
        let result = try Parser.resources(
            cpus: nil, memory: nil,
            defaultCPUs: config.container.cpus,
            defaultMemory: config.container.memory
        )
        #expect(result.cpus == 8)
    }

    @Test func testResourcesMemoryFromProperty() async throws {
        let content = """
            [container]
            memory = "2g"
            """
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-memory-property.toml")
        FileManager.default.createFile(atPath: tempFile.path(), contents: Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempFile.path(percentEncoded: false))])
        let result = try Parser.resources(
            cpus: nil, memory: nil,
            defaultCPUs: config.container.cpus,
            defaultMemory: config.container.memory
        )
        #expect(result.memoryInBytes == 2048.mib())
    }

    @Test func testResourcesFlagOverridesProperty() async throws {
        let content = """
            [container]
            cpus = 8
            memory = "2g"
            """
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-flag-overrides.toml")
        FileManager.default.createFile(atPath: tempFile.path(), contents: Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempFile.path(percentEncoded: false))])
        let result = try Parser.resources(
            cpus: 1, memory: "256m",
            defaultCPUs: config.container.cpus,
            defaultMemory: config.container.memory
        )
        #expect(result.cpus == 1)
        #expect(result.memoryInBytes == 256.mib())
    }

    @Test func testResourcesPropertyKeysAreIsolated() async throws {
        let content = """
            [container]
            cpus = 16
            memory = "8g"
            """
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test-keys-isolated.toml")
        FileManager.default.createFile(atPath: tempFile.path(), contents: Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let config: ContainerSystemConfig = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempFile.path(percentEncoded: false))])
        let result = try Parser.resources(
            cpus: nil, memory: nil,
            defaultCPUs: config.build.cpus,
            defaultMemory: config.build.memory
        )
        #expect(result.cpus == 2)
        #expect(result.memoryInBytes == 2048.mib())
    }

    // MARK: - DNS Flag Validation Tests

    @Test
    func testManagementFlagsRejectsNoDNSWithDNS() throws {
        #expect(throws: (any Error).self) {
            _ = try Flags.Management.parse(["--dns", "1.1.1.1", "--no-dns"])
        }
    }

    @Test
    func testManagementFlagsRejectsNoDNSWithDNSDomain() throws {
        #expect(throws: (any Error).self) {
            _ = try Flags.Management.parse(["--dns-domain", "example.com", "--no-dns"])
        }
    }

    @Test
    func testManagementFlagsRejectsNoDNSWithDNSSearch() throws {
        #expect(throws: (any Error).self) {
            _ = try Flags.Management.parse(["--dns-search", "example.com", "--no-dns"])
        }
    }

    @Test
    func testManagementFlagsRejectsNoDNSWithDNSOption() throws {
        #expect(throws: (any Error).self) {
            _ = try Flags.Management.parse(["--dns-option", "debug", "--no-dns"])
        }
    }

    @Test
    func testManagementFlagsAcceptsDNSAlone() throws {
        _ = try Flags.Management.parse(["--dns", "1.1.1.1"])
    }

    @Test
    func testManagementFlagsAcceptsNoDNSAlone() throws {
        _ = try Flags.Management.parse(["--no-dns"])
    }

    @Test
    func testHostEntriesParserAcceptsIPv4WithColonSeparator() throws {
        let result = try Parser.hostEntries(["db:192.168.66.2"])

        #expect(result == [.init(ipAddress: "192.168.66.2", hostnames: ["db"])])
    }

    @Test
    func testHostEntriesParserAcceptsIPv6WithEqualsSeparator() throws {
        let result = try Parser.hostEntries(["myhostv6=::1"])

        #expect(result == [.init(ipAddress: "::1", hostnames: ["myhostv6"])])
    }

    @Test
    func testHostEntriesParserAcceptsBracketedIPv6() throws {
        let result = try Parser.hostEntries(["myhostv6=[2001:db8::1]"])

        #expect(result == [.init(ipAddress: "2001:db8::1", hostnames: ["myhostv6"])])
    }

    @Test
    func testHostEntriesParserAcceptsHostGateway() throws {
        let result = try Parser.hostEntries(["host.docker.internal=host-gateway"])

        #expect(result == [.init(ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress, hostnames: ["host.docker.internal"])])
        #expect(result.first?.requiresHostGateway == true)
    }

    @Test
    func testHostEntriesParserAcceptsMultipleEntries() throws {
        let result = try Parser.hostEntries([
            "db:10.0.0.5",
            "cache=10.0.0.6",
        ])

        #expect(
            result == [
                .init(ipAddress: "10.0.0.5", hostnames: ["db"]),
                .init(ipAddress: "10.0.0.6", hostnames: ["cache"]),
            ])
    }

    @Test
    func testHostEntriesParserRejectsMissingSeparator() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostEntries(["db-192.168.1.1"])
        }
    }

    @Test
    func testHostEntriesParserRejectsEmptyHostname() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostEntries([":192.168.1.1"])
        }
    }

    @Test
    func testHostEntriesParserRejectsEmptyAddress() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostEntries(["db:"])
        }
    }

    @Test
    func testHostEntriesParserRejectsInvalidAddress() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostEntries(["db:not-an-ip"])
        }
    }

    @Test
    func testManagementFlagsAcceptsAddHost() throws {
        let flags = try Flags.Management.parse([
            "--add-host", "db:192.168.66.2",
            "--add-host", "cache=192.168.66.3",
        ])

        #expect(flags.addHost == ["db:192.168.66.2", "cache=192.168.66.3"])
    }

    @Test
    func testHostnameParserAcceptsRFC1123Name() throws {
        let result = try Parser.hostname("api-01.example.test.")

        #expect(result == "api-01.example.test")
    }

    @Test
    func testHostnameParserRejectsEmptyValue() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostname(" ")
        }
    }

    @Test
    func testHostnameParserRejectsInvalidLabel() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostname("bad_name")
        }
    }

    @Test
    func testDomainnameParserAcceptsRFC1123Name() throws {
        let result = try Parser.hostname("example.test.", option: "--domainname")

        #expect(result == "example.test")
    }

    @Test
    func testDomainnameParserRejectsInvalidLabel() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostname("bad_name", option: "--domainname")
        }
    }

    @Test
    func testManagementFlagsAcceptsHostname() throws {
        let flags = try Flags.Management.parse([
            "--hostname", "api-01",
        ])

        #expect(flags.hostname == "api-01")
    }

    @Test
    func testManagementFlagsAcceptsShortHostname() throws {
        let flags = try Flags.Management.parse([
            "-h", "api-01",
        ])

        #expect(flags.hostname == "api-01")
    }

    @Test
    func testManagementFlagsAcceptsDomainname() throws {
        let flags = try Flags.Management.parse([
            "--domainname", "example.test",
        ])

        #expect(flags.domainname == "example.test")
    }

    @Test
    func testManagementFlagsAcceptsNetworkHost() throws {
        let flags = try Flags.Management.parse([
            "--network", "host",
        ])

        #expect(flags.networks == ["host"])
    }

    @Test
    func testManagementFlagsAcceptsPIDHost() throws {
        let flags = try Flags.Management.parse([
            "--pid", "host",
        ])

        #expect(flags.pid == "host")
    }

    @Test
    func testHostPIDNamespaceParserAcceptsHost() throws {
        #expect(try Parser.hostPIDNamespace("host"))
        #expect(try !Parser.hostPIDNamespace(nil))
    }

    @Test
    func testHostPIDNamespaceParserRejectsUnsupportedValue() throws {
        #expect(throws: (any Error).self) {
            _ = try Parser.hostPIDNamespace("container:db")
        }
    }

    @Test
    func testManagementFlagsAcceptsLogDriver() throws {
        let flags = try Flags.Management.parse(["--log-driver", "none"])

        #expect(flags.logDriver == "none")
    }

    @Test
    func testManagementFlagsAcceptsJSONFileLogDriver() throws {
        let flags = try Flags.Management.parse(["--log-driver", "json-file"])

        #expect(flags.logDriver == "json-file")
    }

    @Test
    func testManagementFlagsAcceptsLogOptions() throws {
        let flags = try Flags.Management.parse([
            "--log-driver", "local",
            "--log-opt", "max-size=10m",
            "--log-opt", "max-file=3",
        ])

        #expect(flags.logDriver == "local")
        #expect(flags.logOpt == ["max-size=10m", "max-file=3"])
    }

    // MARK: - Collection capacity hints

    @Test("labels with large input preserves all entries")
    func testLabelsLargeInput() throws {
        let labels = (0..<100).map { "key\($0)=value\($0)" }
        let result = try Parser.labels(labels)
        #expect(result.count == 100)
        #expect(result["key42"] == "value42")
        #expect(result["key99"] == "value99")
    }

    @Test("resolve with large input preserves all entries")
    func testParseKeyValuePairsLargeInput() {
        let pairs = (0..<100).map { "key\($0)=value\($0)" }
        let result = Utility.parseKeyValuePairs(pairs)
        #expect(result.count == 100)
        #expect(result["key0"] == "value0")
        #expect(result["key99"] == "value99")
    }

    @Test("tmpfsMounts with large input")
    func testTmpfsMountsLargeInput() throws {
        let mounts = (0..<20).map { "/mnt/tmpfs\($0)" }
        let result = try Parser.tmpfsMounts(mounts)
        #expect(result.count == 20)
    }

    @Test("volumes with large input")
    func testVolumesLargeInput() throws {
        let volumes = (0..<20).map { "vol\($0):/mnt/vol\($0)" }
        let result = try Parser.volumes(volumes)
        #expect(result.count == 20)
    }

    @Test("capabilities with large input")
    func testCapabilitiesLargeInput() throws {
        let result = try Parser.capabilities(capAdd: ["ALL", "SYS_ADMIN", "NET_RAW", "CHOWN"], capDrop: ["SETUID", "KILL"])
        #expect(result.capAdd.count == 4)
        #expect(result.capDrop.count == 2)
        #expect(result.capAdd.first == "ALL")
    }

    @Test("rlimits with large input")
    func testRlimitsLargeInput() throws {
        let result = try Parser.rlimits(["nofile=1024:2048", "nproc=100:200", "memlock=65536:65536"])
        #expect(result.count == 3)
        #expect(result[0].limit == "RLIMIT_NOFILE")
    }

    @Test("allEnv with large env lists")
    func testAllEnvLargeInput() throws {
        let imageEnvs = (0..<50).map { "IMAGE_VAR\($0)=value\($0)" }
        let envs = (0..<50).map { "USER_VAR\($0)=value\($0)" }
        let result = try Parser.allEnv(imageEnvs: imageEnvs, envFiles: [], envs: envs)
        #expect(result.count == 100)
    }
}
