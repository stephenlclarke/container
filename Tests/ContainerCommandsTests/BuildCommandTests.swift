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
import Foundation
import Testing

@testable import ContainerCommands

struct BuildCommandTests {
    @Test
    func dockerignoreFallsBackToContextFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = directory.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        try Data("FROM scratch\n".utf8).write(to: directory.appendingPathComponent("Dockerfile"))
        try Data("ignored.txt\n".utf8).write(to: context.appendingPathComponent(".dockerignore"))

        let data = try Application.BuildCommand.dockerignoreData(
            dockerfile: directory.appendingPathComponent("Dockerfile").path,
            contextDir: context.path
        )

        #expect(data == Data("ignored.txt\n".utf8))
    }

    @Test
    func dockerignoreSpecificFileTakesPrecedence() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = directory.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        let dockerfile = directory.appendingPathComponent("Dockerfile")
        try Data("FROM scratch\n".utf8).write(to: dockerfile)
        try Data("specific.txt\n".utf8).write(to: directory.appendingPathComponent("Dockerfile.dockerignore"))
        try Data("general.txt\n".utf8).write(to: context.appendingPathComponent(".dockerignore"))

        let data = try Application.BuildCommand.dockerignoreData(
            dockerfile: dockerfile.path,
            contextDir: context.path
        )

        #expect(data == Data("specific.txt\n".utf8))
    }

    @Test
    func dockerignoreForStdinUsesContextFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = directory.appendingPathComponent("context", isDirectory: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        try Data("stdin-ignore.txt\n".utf8).write(to: context.appendingPathComponent(".dockerignore"))

        let data = try Application.BuildCommand.dockerignoreData(
            dockerfile: "-",
            contextDir: context.path
        )

        #expect(data == Data("stdin-ignore.txt\n".utf8))
    }

    @Test
    func buildParsesRepeatedSSHOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("FROM scratch\n".utf8).write(to: directory.appendingPathComponent("Dockerfile"))

        let command = try Application.BuildCommand.parse([
            "--check",
            "--builder", "remote",
            "--build-context", "shared=./shared",
            "--build-context", "base=docker-image://example/base:latest",
            "--allow", "network.host",
            "--add-host", "build.local=127.0.0.1",
            "--network", "host",
            "--privileged",
            "--shm-size", "67108864",
            "--ulimit", "nofile=1024:2048",
            "--ssh", "default",
            "--ssh", "git=/tmp/agent.sock",
            "--tag", "example/app:latest",
            directory.path,
        ])

        #expect(command.check)
        #expect(command.builder == "remote")
        #expect(command.buildContext == ["shared=./shared", "base=docker-image://example/base:latest"])
        #expect(command.allow == ["network.host"])
        #expect(command.addHost == ["build.local=127.0.0.1"])
        #expect(command.network == "host")
        #expect(command.privileged)
        #expect(command.shmSize == "67108864")
        #expect(command.ulimit == ["nofile=1024:2048"])
        #expect(command.ssh == ["default", "git=/tmp/agent.sock"])
        #expect(command.contextDir == directory.path)
        #expect(command.targetImageNames == ["example/app:latest"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test
    func builderCommandsParseNamedBuilderOptions() throws {
        let start = try Application.BuilderStart.parse(["--builder", "remote"])
        #expect(start.builder == "remote")

        let status = try Application.BuilderStatus.parse(["--builder", "remote"])
        #expect(status.builder == "remote")

        let stop = try Application.BuilderStop.parse(["--builder", "remote"])
        #expect(stop.builder == "remote")

        let delete = try Application.BuilderDelete.parse(["--builder", "remote", "--force"])
        #expect(delete.builder == "remote")
        #expect(delete.force)
    }

    @Test
    func buildSSHForwardingUsesEnvironmentSocketForImplicitIDs() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["default", "git"],
            environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"],
            isSocket: { $0 == "/tmp/agent.sock" }
        )

        #expect(
            forwarding.metadataValues == [
                "default=\(BuildSSHForwarding.guestSocketPath)",
                "git=\(BuildSSHForwarding.guestSocketPath)",
            ])
        #expect(forwarding.environmentSocketGuestPath == BuildSSHForwarding.guestSocketPath)
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "default",
                    hostPath: "/tmp/agent.sock",
                    guestPath: BuildSSHForwarding.guestSocketPath
                )
            ])
    }

    @Test
    func buildSSHForwardingRewritesExplicitSocketToGuestPath() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["git=/tmp/git.sock"],
            environment: [:],
            isSocket: { $0 == "/tmp/git.sock" }
        )

        #expect(forwarding.environmentSocketGuestPath == nil)
        #expect(forwarding.metadataValues == ["git=/var/host-services/ssh-auth-git.sock"])
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "git",
                    hostPath: "/tmp/git.sock",
                    guestPath: "/var/host-services/ssh-auth-git.sock"
                )
            ])
    }

    @Test
    func buildSSHForwardingRewritesBarePathToDefaultID() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["/tmp/default.sock"],
            environment: [:],
            isSocket: { $0 == "/tmp/default.sock" }
        )

        #expect(forwarding.environmentSocketGuestPath == nil)
        #expect(forwarding.metadataValues == ["default=\(BuildSSHForwarding.guestSocketPath)"])
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "default",
                    hostPath: "/tmp/default.sock",
                    guestPath: BuildSSHForwarding.guestSocketPath
                )
            ])
    }

    @Test
    func buildSSHForwardingSupportsDistinctSocketPaths() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["default=/tmp/default.sock", "git=/tmp/git.sock"],
            environment: [:],
            isSocket: { _ in true }
        )

        #expect(forwarding.environmentSocketGuestPath == nil)
        #expect(
            forwarding.metadataValues == [
                "default=\(BuildSSHForwarding.guestSocketPath)",
                "git=/var/host-services/ssh-auth-git.sock",
            ])
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "default",
                    hostPath: "/tmp/default.sock",
                    guestPath: BuildSSHForwarding.guestSocketPath
                ),
                BuildSSHForwarding.SocketMount(
                    id: "git",
                    hostPath: "/tmp/git.sock",
                    guestPath: "/var/host-services/ssh-auth-git.sock"
                ),
            ])
    }

    @Test
    func buildSSHForwardingSupportsImplicitAndExplicitDistinctSockets() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["default", "git=/tmp/git.sock"],
            environment: ["SSH_AUTH_SOCK": "/tmp/default.sock"],
            isSocket: { _ in true }
        )

        #expect(forwarding.environmentSocketGuestPath == BuildSSHForwarding.guestSocketPath)
        #expect(
            forwarding.metadataValues == [
                "default=\(BuildSSHForwarding.guestSocketPath)",
                "git=/var/host-services/ssh-auth-git.sock",
            ])
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "default",
                    hostPath: "/tmp/default.sock",
                    guestPath: BuildSSHForwarding.guestSocketPath
                ),
                BuildSSHForwarding.SocketMount(
                    id: "git",
                    hostPath: "/tmp/git.sock",
                    guestPath: "/var/host-services/ssh-auth-git.sock"
                ),
            ])
    }

    @Test
    func buildSSHForwardingAvoidsEnvironmentGuestPathCollisions() throws {
        let forwarding = try BuildSSHForwarding.resolve(
            values: ["default=/tmp/default.sock", "git"],
            environment: ["SSH_AUTH_SOCK": "/tmp/git.sock"],
            isSocket: { _ in true }
        )

        #expect(forwarding.environmentSocketGuestPath == "/var/host-services/ssh-auth-env.sock")
        #expect(
            forwarding.metadataValues == [
                "default=\(BuildSSHForwarding.guestSocketPath)",
                "git=/var/host-services/ssh-auth-env.sock",
            ])
        #expect(
            forwarding.socketMounts == [
                BuildSSHForwarding.SocketMount(
                    id: "default",
                    hostPath: "/tmp/default.sock",
                    guestPath: BuildSSHForwarding.guestSocketPath
                ),
                BuildSSHForwarding.SocketMount(
                    id: "git",
                    hostPath: "/tmp/git.sock",
                    guestPath: "/var/host-services/ssh-auth-env.sock"
                ),
            ])
    }

    @Test
    func buildSSHForwardingRejectsDuplicateIDsWithDifferentSockets() throws {
        #expect(throws: ValidationError.self) {
            try BuildSSHForwarding.resolve(
                values: ["git=/tmp/git.sock", "git=/tmp/other.sock"],
                environment: [:],
                isSocket: { _ in true }
            )
        }
    }

    @Test
    func buildSSHForwardingRejectsMissingImplicitEnvironmentSocket() throws {
        #expect(throws: ValidationError.self) {
            try BuildSSHForwarding.resolve(
                values: ["default"],
                environment: [:],
                isSocket: { _ in true }
            )
        }
    }
}
