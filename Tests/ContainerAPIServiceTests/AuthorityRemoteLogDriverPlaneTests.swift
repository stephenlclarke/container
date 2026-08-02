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

import ContainerLoggingProviders
import ContainerResource
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ContainerAPIService

@Suite(.serialized)
struct AuthorityRemoteLogDriverPlaneTests {
    @Test
    func gelfProductionPlaneForwardsForegroundAndProviderBytes() async throws {
        try await withTemporaryRoot { root in
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let promise = serverGroup.next().makePromise(of: Data.self)
            let capture = AuthorityDatagramCaptureHandler(promise: promise)
            let server = try await DatagramBootstrap(group: serverGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(capture)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            do {
                let port = try #require(server.localAddress?.port)
                let plane = try await AuthorityRemoteLogDriverPlane.create(
                    appRoot: root
                )
                let id = "gelf-plane"
                let bundle = ContainerResource.Bundle(
                    path: root.appendingPathComponent(id, isDirectory: true)
                )
                try FileManager.default.createDirectory(
                    at: bundle.path,
                    withIntermediateDirectories: true
                )
                let configuration = try gelfConfiguration(
                    id: id,
                    port: port
                )
                let foreground = Pipe()
                let runtimeStdio = try await plane.prepareBootstrap(
                    containerID: id,
                    bundle: bundle,
                    configuration: configuration,
                    authenticatedProtectedOptions: [:],
                    stdio: [nil, foreground.fileHandleForWriting, nil]
                )

                try #require(runtimeStdio[1]).write(
                    contentsOf: Data("plane-output\n".utf8)
                )
                try await plane.bootstrapSucceeded(containerID: id)
                try await plane.activate(containerID: id)
                try await plane.close(containerID: id)

                let foregroundData = foreground.fileHandleForReading
                    .readDataToEndOfFile()
                #expect(foregroundData == Data("plane-output\n".utf8))
                let datagram = try await promise.futureResult.get()
                let json = try #require(String(data: datagram, encoding: .utf8))
                #expect(json.contains("\"short_message\":\"plane-output\""))

                try await server.close().get()
                capture.cancel()
                try await serverGroup.shutdownGracefully()
            } catch {
                capture.cancel()
                try? await server.close().get()
                try? await serverGroup.shutdownGracefully()
                throw error
            }
        }
    }

    private func gelfConfiguration(
        id: String,
        port: Int
    ) throws -> ContainerConfiguration {
        let options = [
            "gelf-address": "udp://127.0.0.1:\(port)",
            "gelf-compression-type": "none",
        ]
        let descriptor = GELFLogDriverContract.descriptor()
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: descriptor.driver,
            safeOptions: options,
            delivery: LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .unavailable),
            providerIdentity: descriptor.providerIdentity,
            providerGenerationAtResolution: descriptor.providerGeneration,
            contractDigest: descriptor.optionContractDigest
        )
        var configuration = ContainerConfiguration(
            id: id,
            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: .init(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:" + String(repeating: "0", count: 64),
                    size: 0
                )
            ),
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: [],
                environment: [],
                terminal: true
            )
        )
        configuration.logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(
                driver: descriptor.driver,
                options: options
            ),
            resolved: resolved
        )
        return configuration
    }

    private func withTemporaryRoot(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "authority-remote-log-plane-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private final class AuthorityDatagramCaptureHandler: ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let promise: EventLoopPromise<Data>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Data>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var envelope = unwrapInboundIn(data)
        let bytes =
            envelope.data.readBytes(
                length: envelope.data.readableBytes
            ) ?? []
        complete(.success(Data(bytes)))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Data, any Error>) {
        let shouldComplete = lock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
        guard shouldComplete else {
            return
        }
        promise.completeWith(result)
    }
}
