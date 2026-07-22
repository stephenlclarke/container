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

import AsyncHTTPClient
import ContainerTestSupport
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Testing

@Suite
struct TestCLIRunCommand {
    private let alpine = WarmupImage.alpine320

    // MARK: - Basic run options

    @Test func testRunCommand() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            _ = try f.doExec(c, cmd: ["date"])
        }
    }

    @Test func testRunCommandCWD() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--cwd", "/tmp"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["pwd"]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "/tmp")
        }
    }

    @Test func testRunCommandEnv() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--env", "FOO=bar"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.initProcess.environment.contains("FOO=bar"))
        }
    }

    @Test func testRunCommandLabelsPreserveEqualsInValues() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: [
                    "--label", "config=key=value",
                    "--label", "traefik.http.routers.api.rule=Host(`example.test`)",
                ],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let labels = try f.inspectContainer(c).configuration.labels
            #expect(labels["config"] == "key=value")
            #expect(labels["traefik.http.routers.api.rule"] == "Host(`example.test`)")
        }
    }

    @Test func testRunCommandEnvFile() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let envFile = f.testDir.appending("test.env")
            let content = "# comment\nFOO=bar\nBAR=baz wow\nURL=https://foo.bar?baz=wow\n"
            try content.write(toFile: envFile.string, atomically: true, encoding: .utf8)

            try f.doLongRun(name: c, image: image, args: ["--env-file", envFile.string], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            for expected in ["FOO=bar", "BAR=baz wow", "URL=https://foo.bar?baz=wow"] {
                #expect(inspect.configuration.initProcess.environment.contains(expected))
            }
        }
    }

    @Test func testRunCommandUserIDGroupID() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--uid", "10", "--gid", "100"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try #expect(output.contains(Regex("uid=10.*?gid=100.*")))
        }
    }

    @Test func testRunCommandUser() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--user", "nobody"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["whoami"]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "nobody")
        }
    }

    @Test func testRunCommandCPUs() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            // CPU cgroup controls are provided by the source-matched guest
            // installed by this integration target.
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cpus", "2"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpu.max"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = output.components(separatedBy: .whitespaces)
            #expect(fields.count == 2)
            let numerator = try #require(Int(fields[0]))
            let denominator = try #require(Int(fields[1]))
            #expect(denominator > 0)
            #expect(2 * denominator == numerator)
        }
    }

    @Test func testRunCommandFractionalCPUs() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cpus", "0.25"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpu.max"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(output == "25000 100000")
        }
    }

    @Test func testRunCommandUnlimitedCPUs() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cpus", "0"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpu.max"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(output == "max 100000")
        }
    }

    @Test func testRunCommandCPUShares() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            // The cgroup v2 CPU-share bridge is provided by the matched guest
            // image installed by the integration target, not the versioned
            // release guest used by a stock default configuration.
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cpu-shares", "512"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpu.weight"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // OCI shares are translated to cgroup v2's CPU-weight scale.
            #expect(output == "59")
        }
    }

    @Test func testRunCommandCPUSet() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cpuset-cpus", "0-1"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpuset.cpus", "/sys/fs/cgroup/cpuset.mems"])
                .split(separator: "\n")
                .map(String.init)

            #expect(output == ["0-1", "0"])
        }
    }

    @Test func testRunCommandHostCgroupNamespace() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cgroupns", "host"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.hostCgroupNamespace)
            let cgroupPath = try f.doExec(c, cmd: ["cat", "/proc/self/cgroup"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(cgroupPath.hasPrefix("0::"))
        }
    }

    @Test func testRunCommandHostIPCAndUTSNamespaces() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--ipc", "host", "--uts", "host"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.hostIPCNamespace)
            #expect(inspect.configuration.hostUTSNamespace)
            let hostname = try f.doExec(c, cmd: ["hostname"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!hostname.isEmpty)
            let ipcStatus = try f.doExec(c, cmd: ["sh", "-c", "test -r /proc/sysvipc/shm"])
            #expect(ipcStatus.isEmpty)
        }
    }

    @Test func testRunCommandPrivatePIDNamespace() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--pid", "private"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(!inspect.configuration.hostPIDNamespace)
            let initPID = try f.doExec(c, cmd: ["sh", "-c", "test -r /proc/1/status"])
            #expect(initPID.isEmpty)
        }
    }

    @Test func testRunCommandPrivateUserNamespace() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--userns", "private"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.privateUserNamespace)
            let mapping = try f.doExec(
                c,
                cmd: [
                    "sh", "-c",
                    "test \"$(readlink /proc/self/ns/user)\" != \"user:[4026531837]\" && cat /proc/self/uid_map",
                ]
            )
            .split(whereSeparator: \.isWhitespace)
            #expect(mapping == ["0", "0", "4294967295"])
        }
    }

    @Test func testRunCommandUnconfinedSystemPaths() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: ["--init-image", "vminit:latest", "--cap-drop", "ALL", "--security-opt", "systempaths=unconfined"],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.unconfinedSystemPaths)

            let defaultMountOptions = try f.run([
                "run", "--rm", "--cap-drop", "ALL", "--init-image", "vminit:latest", image,
                "sh", "-c", "awk '$5 == \"/proc/sys\" { print $6 }' /proc/self/mountinfo",
            ]).check().output.trimmingCharacters(in: .whitespacesAndNewlines)
            let unconfinedMountOptions = try f.run([
                "run", "--rm", "--cap-drop", "ALL", "--security-opt", "systempaths=unconfined", "--init-image", "vminit:latest", image,
                "sh", "-c", "awk '$5 == \"/proc/sys\" { print $6 }' /proc/self/mountinfo",
            ]).check().output.trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(defaultMountOptions.contains("ro"))
            #expect(unconfinedMountOptions.isEmpty)
        }
    }

    @Test func testRunCommandCPUQuotaAndPeriod() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c,
                image: image,
                args: [
                    "--init-image", "vminit:latest", "--cpu-period", "200000", "--cpu-quota", "50000",
                ],
                autoRemove: false
            )
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["cat", "/sys/fs/cgroup/cpu.max"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            #expect(output == "50000 200000")
        }
    }

    @Test func testRunCommandMemory() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--memory", "1024M"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let inspect = try f.inspectContainer(c)
            let expectedBytes = UInt64(1024) * 1024 * 1024
            #expect(inspect.configuration.resources.memoryInBytes == expectedBytes)
        }
    }

    @Test func testRunCommandUlimitNofile() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--ulimit", "nofile=1024:2048"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            let nofile = inspect.configuration.initProcess.rlimits.first { $0.limit == "RLIMIT_NOFILE" }
            try #require(nofile != nil)
            #expect(nofile?.soft == 1024)
            #expect(nofile?.hard == 2048)

            let output = try f.doExec(c, cmd: ["sh", "-c", "ulimit -n"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "1024")
        }
    }

    @Test func testRunCommandUlimitNproc() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--ulimit", "nproc=256"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            let nproc = inspect.configuration.initProcess.rlimits.first { $0.limit == "RLIMIT_NPROC" }
            try #require(nproc != nil)
            #expect(nproc?.soft == 256)
            #expect(nproc?.hard == 256)

            let output = try f.doExec(c, cmd: ["sh", "-c", "ulimit -u"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == "256")
        }
    }

    @Test func testRunCommandMultipleUlimits() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: ["--ulimit", "nofile=1024:2048", "--ulimit", "nproc=512", "--ulimit", "stack=8388608"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let rlimits = try f.inspectContainer(c).configuration.initProcess.rlimits
            #expect(rlimits.count == 3)
            let nofile = rlimits.first { $0.limit == "RLIMIT_NOFILE" }
            let nproc = rlimits.first { $0.limit == "RLIMIT_NPROC" }
            let stack = rlimits.first { $0.limit == "RLIMIT_STACK" }
            #expect(nofile?.soft == 1024 && nofile?.hard == 2048)
            #expect(nproc?.soft == 512 && nproc?.hard == 512)
            #expect(stack?.soft == 8_388_608 && stack?.hard == 8_388_608)
        }
    }

    // MARK: - Mounts and storage

    @Test func testRunCommandMount() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let testData = "hello world"
            let hostFile = f.testDir.appending("testfile.txt")
            try testData.write(toFile: hostFile.string, atomically: true, encoding: .utf8)

            try f.doLongRun(
                name: c, image: image,
                args: ["--mount", "type=virtiofs,source=\(f.testDir.string),target=/tmp/testmount,readonly"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["cat", "/tmp/testmount/testfile.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData)
        }
    }

    @Test func testRunCommandNonRootHardlinkBindMount() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let hardlinkDirectory = f.testDir.appending("hardlinks")
            let payload = String(repeating: "hard-link payload\\n", count: 4096)

            // The guest user must be able to traverse the source directory.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: f.testDir.string)
            try FileManager.default.createDirectory(
                atPath: hardlinkDirectory.string, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: hardlinkDirectory.string)

            for index in 0..<16 {
                let source = hardlinkDirectory.appending("source-\(index)")
                let hardlink = hardlinkDirectory.appending("hardlink-\(index)")
                try payload.write(toFile: source.string, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o444], ofItemAtPath: source.string)
                try FileManager.default.linkItem(atPath: source.string, toPath: hardlink.string)
            }

            try f.run([
                "run", "--rm", "--uid", "1024",
                "--mount", "type=bind,source=\(hardlinkDirectory.string),target=/mnt/hardlinks,readonly",
                image,
                "sh", "-ceu",
                """
                for path in /mnt/hardlinks/*; do
                    test -r "$path"
                    cat "$path" >/dev/null
                done
                tar -cf /tmp/hardlinks.tar /mnt/hardlinks
                test "$(tar -tf /tmp/hardlinks.tar | wc -l)" -ge 33
                """,
            ]).check()
        }
    }

    @Test func testRunCommandUnixSocketMount() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            // sockaddr_un.sun_path is 104 bytes on macOS — use /tmp to keep
            // the host socket path short regardless of project directory depth.
            let socketDir = "/tmp/\(f.testID)-sock"
            try FileManager.default.createDirectory(
                atPath: socketDir, withIntermediateDirectories: true, attributes: nil)
            f.addCleanup { try? FileManager.default.removeItem(atPath: socketDir) }
            let socketPath = socketDir + "/ssh-auth.sock"
            let guestSocketPath = "/run/ssh-auth.sock"

            let socketType = try UnixType(path: socketPath, perms: 0o766, unlinkExisting: true)
            let socket = try Socket(type: socketType, closeOnDeinit: true)
            try socket.listen()
            f.addCleanup { try? socket.close() }

            try f.doLongRun(
                name: c, image: image,
                args: ["-v", "\(socketPath):\(guestSocketPath)", "-e", "SSH_AUTH_SOCK=\(guestSocketPath)"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            _ = try f.doExec(c, cmd: ["apk", "add", "netcat-openbsd"])
            let perms = try f.doExec(
                c, cmd: ["sh", "-c", "stat -c \"%a\" \"${SSH_AUTH_SOCK}\""],
                user: "guest"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(perms == "766")
            _ = try f.doExec(c, cmd: ["sh", "-c", "nc -zU \"${SSH_AUTH_SOCK}\""], user: "guest")
        }
    }

    @Test func testRunCommandTmpfs() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--tmpfs", "/tmp/testtmpfs"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["df", "/tmp/testtmpfs"])
            let lines = output.split(separator: "\n")
            #expect(lines.count == 2)
            let words = lines[1].split(separator: " ")
            #expect(words[0].lowercased() == "tmpfs")
        }
    }

    @Test func testRunCommandShmSize() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--shm-size", "128m"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["mount"])
            let shmLine = output.split(separator: "\n").first { $0.contains("/dev/shm") }
            try #require(shmLine != nil)
            #expect(shmLine!.contains("size=\(128 * 1024)k"))
        }
    }

    @Test func testRunCommandVolume() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let testData = "one small step"
            let volumeFile = f.testDir.appending("data.txt")
            try testData.write(toFile: volumeFile.string, atomically: true, encoding: .utf8)

            try f.doLongRun(
                name: c, image: image,
                args: ["--volume", "\(f.testDir.string):/tmp/testvolume"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["cat", "/tmp/testvolume/data.txt"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(output == testData)
        }
    }

    @Test func testRunCommandCidfile() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let cidfile = f.testDir.appending("container.cid")

            try f.doLongRun(name: c, image: image, args: ["--cidfile", cidfile.string], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let actualID = try String(contentsOfFile: cidfile.string, encoding: .utf8)
            #expect(actualID == c)
        }
    }

    // MARK: - Network and DNS

    @Test func testRunCommandNoDNS() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--no-dns"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let result = try f.run(["exec", c, "cat", "/etc/resolv.conf"])
            #expect(result.status != 0)
        }
    }

    @Test func testRunCommandDefaultResolvConf() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["cat", "/etc/resolv.conf"])
            let actualLines = output.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { $0.components(separatedBy: .whitespaces).joined(separator: " ") }

            let inspect = try f.inspectContainer(c)
            let ip = inspect.networks[0].ipv4Address.address
            let nameserver = IPv4Address((ip.value & Prefix(length: 24)!.prefixMask32) + 1).description
            let config = try f.getSystemConfig()
            let expectedLines: [String] = [
                "nameserver \(nameserver)",
                config.dns.domain.map { "domain \($0)" },
            ].compactMap { $0 }

            #expect(expectedLines == actualLines)
        }
    }

    @Test func testRunCommandNonDefaultResolvConf() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: image,
                args: [
                    "--dns", "8.8.8.8", "--dns-domain", "example.com",
                    "--dns-search", "test.com", "--dns-option", "debug",
                ],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let output = try f.doExec(c, cmd: ["cat", "/etc/resolv.conf"])
            let actualLines = output.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { $0.components(separatedBy: .whitespaces).joined(separator: " ") }

            #expect(
                actualLines == [
                    "nameserver 8.8.8.8",
                    "domain example.com",
                    "search test.com",
                    "options debug",
                ])
        }
    }

    @Test func testRunDefaultHostsEntries() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            let ip = inspect.networks[0].ipv4Address.address.description

            let output = try f.doExec(c, cmd: ["cat", "/etc/hosts"])
            let lines = output.split(separator: "\n")
            let expected = [("127.0.0.1", "localhost"), (ip, c)]
            for (i, line) in lines.enumerated() {
                guard i < expected.count else { break }
                let words = line.split(separator: " ").map(String.init)
                #expect(words.count >= 2)
                #expect(words[0] == expected[i].0)
                #expect(words[1] == expected[i].1)
            }
        }
    }

    @Test func testPrivilegedPortError() async throws {
        try #require(geteuid() != 0)
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            f.addCleanup { try? f.doRemove(c, force: true) }
            let result = try f.run(["run", "--name", c, "--publish", "127.0.0.1:80:80", image])
            #expect(result.status != 0)
            #expect(result.error.contains("Permission denied while binding to host port 80"))
            #expect(result.error.contains("root privileges"))
        }
    }

    // MARK: - Platform

    @Test func testRunCommandOSArch() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--os", "linux", "--arch", "amd64"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["uname", "-sm"])
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            #expect(output == "linux x86_64")
        }
    }

    @Test func testRunCommandPlatform() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--platform", "linux/amd64"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let output = try f.doExec(c, cmd: ["uname", "-sm"])
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            #expect(output == "linux x86_64")
        }
    }

    // MARK: - init process

    @Test func testRunCommandInit() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--init"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.useInit == true)

            let cmdline = try f.doExec(c, cmd: ["cat", "/proc/1/cmdline"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!cmdline.hasPrefix("sleep"), "PID 1 should be init process, not 'sleep'")
        }
    }

    @Test func testRunCommandInitReapsZombies() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--init"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            _ = try f.doExec(c, cmd: ["sh", "-c", "sh -c 'sh -c \"exit 0\" &' && sleep 1"])
            let ps = try f.doExec(c, cmd: ["sh", "-c", "ps aux | grep -c '\\[sh\\]' || true"])
            let zombieCount = Int(ps.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            #expect(zombieCount == 0, "expected no zombie processes with --init")
        }
    }

    @Test func testRunCommandWithoutInitDefault() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.useInit == false)
        }
    }

    // MARK: - Read-only rootfs

    @Test func testRunCommandReadOnly() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            try f.doLongRun(name: c, image: image, args: ["--read-only"], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)
            let result = try f.run(["exec", c, "touch", "/testfile"])
            #expect(result.status != 0, "touch on read-only rootfs should fail")
        }
    }

    // MARK: - Env file from named pipe

    @Test func testRunCommandEnvFileFromNamedPipe() async throws {
        try await ContainerFixture.with { f in
            let image = try f.copyWarmupImage(alpine)
            let c = "\(f.testID)-c"
            let pipePath = f.testDir.appending("envfile.pipe")
            guard mkfifo(pipePath.string, 0o600) == 0 else {
                Issue.record("failed to create named pipe")
                return
            }

            let content = "FOO=bar\nBAR=baz\n"
            // Write to the FIFO in a detached task so the open doesn't block forever.
            let writeTask = Task.detached {
                let handle = try FileHandle(forWritingTo: URL(filePath: pipePath.string))
                try handle.write(contentsOf: Data(content.utf8))
                try handle.close()
            }
            defer { writeTask.cancel() }

            try f.doLongRun(name: c, image: image, args: ["--env-file", pipePath.string], autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await writeTask.value

            try await f.waitForContainerRunning(c)
            let inspect = try f.inspectContainer(c)
            #expect(inspect.configuration.initProcess.environment.contains("FOO=bar"))
            #expect(inspect.configuration.initProcess.environment.contains("BAR=baz"))
        }
    }

    // MARK: - TCP port forwarding

    @Test func testForwardTCP() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            let proxyPort = try f.availableTCPPort()
            let serverPort = UInt16.random(in: 55000..<60000)
            try f.doLongRun(
                name: c, image: "docker.io/library/python:alpine",
                args: ["--publish", "127.0.0.1:\(proxyPort):\(serverPort)/tcp"],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(serverPort)"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let client = f.makeHTTPClient()
            defer { _ = client.shutdown() }
            await withKnownIssue("published TCP forwarder backend can be unreachable without a host vmnet route", isIntermittent: true) {
                try await f.retry(attempts: 10, delay: .seconds(3)) {
                    do {
                        var req = HTTPClientRequest(url: "http://127.0.0.1:\(proxyPort)")
                        req.method = .GET
                        let resp = try await client.execute(req, timeout: .seconds(3))
                        return resp.status.code >= 200 && resp.status.code < 300
                    } catch {
                        return false
                    }
                }
            }
        }
    }

    @Test func testForwardTCPPortRange() async throws {
        try await ContainerFixture.with { f in
            let range = UInt16(10)
            let proxyPortStart = try f.availableTCPPortRange(count: range + 1)
            let serverPortStart = UInt16.random(in: 55000..<60000)
            let c = "\(f.testID)-c"
            try f.doLongRun(
                name: c, image: "docker.io/library/python:alpine",
                args: ["--publish", "127.0.0.1:\(proxyPortStart)-\(proxyPortStart + range):\(serverPortStart)-\(serverPortStart + range)/tcp"],
                containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(serverPortStart)"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let client2 = f.makeHTTPClient()
            defer { _ = client2.shutdown() }
            await withKnownIssue("published TCP forwarder backend can be unreachable without a host vmnet route", isIntermittent: true) {
                try await f.retry(attempts: 10, delay: .seconds(3)) {
                    do {
                        var req = HTTPClientRequest(url: "http://127.0.0.1:\(proxyPortStart)")
                        req.method = .GET
                        let resp = try await client2.execute(req, timeout: .seconds(3))
                        return resp.status.code >= 200 && resp.status.code < 300
                    } catch {
                        return false
                    }
                }
            }
        }
    }

    @available(macOS 26, *)
    @Test func testForwardTCPv6() async throws {
        try await ContainerFixture.with { f in
            let c = "\(f.testID)-c"
            let proxyPort = try f.availableTCPPortV6()
            let serverPort = UInt16.random(in: 55000..<60000)
            try f.doLongRun(
                name: c, image: "docker.io/library/node:alpine",
                args: ["--publish", "[::1]:\(proxyPort):\(serverPort)/tcp"],
                containerArgs: ["npx", "http-server", "-a", "::", "-p", "\(serverPort)"],
                autoRemove: false)
            f.addCleanup {
                try? f.doStop(c)
                try? f.doRemove(c)
            }
            try await f.waitForContainerRunning(c)

            let client3 = f.makeHTTPClient()
            defer { _ = client3.shutdown() }
            await withKnownIssue("published TCP forwarder backend can be unreachable without a host vmnet route", isIntermittent: true) {
                try await f.retry(attempts: 10, delay: .seconds(3)) {
                    do {
                        var req = HTTPClientRequest(url: "http://[::1]:\(proxyPort)")
                        req.method = .GET
                        let resp = try await client3.execute(req, timeout: .seconds(3))
                        return resp.status.code >= 200 && resp.status.code < 300
                    } catch {
                        return false
                    }
                }
            }
        }
    }
}
