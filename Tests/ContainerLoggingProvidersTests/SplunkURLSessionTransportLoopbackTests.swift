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

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import ContainerLoggingProviders

struct SplunkURLSessionTransportLoopbackTests {
    @Test func productionHTTPTransportSendsExactVerificationAndBatch() async throws {
        let recorder = SplunkHTTPRecorder()
        try await withSplunkHTTPServer(recorder: recorder) { port in
            let configuration = try loopbackConfiguration(
                url: "http://127.0.0.1:\(port)",
                tls: nil,
                verifyConnection: true
            )
            let session = try await SplunkDriverSession(
                configuration: configuration,
                transportFactory: URLSessionSplunkHTTPTransportFactory()
            )
            try await session.write(
                splunkRecord(payload: Data("one".utf8), sequence: 1)
            )
            try await session.write(
                splunkRecord(payload: Data("two".utf8), sequence: 2)
            )
            try await session.closeUsingPolicy()

            let requests = recorder.snapshot
            #expect(requests.count == 2)
            #expect(requests[0].method == .OPTIONS)
            #expect(requests[0].uri == "/services/collector/event/1.0")
            #expect(requests[1].method == .POST)
            #expect(
                requests[1].headers.first(name: "Authorization")
                    == "Splunk protected-token"
            )
            let body = String(decoding: requests[1].body, as: UTF8.self)
            #expect(body.contains(#""line":"one""#))
            #expect(body.contains(#""line":"two""#))
        }
    }

    @Test func productionTLSTransportHonorsCustomCAAndServerName() async throws {
        let certificatePath = try fixturePath("syslog-server-cert.pem")
        let keyPath = try fixturePath("syslog-server-key.pem")
        let caPath = try fixturePath("syslog-test-ca.pem")
        let context = try tlsServerContext(
            certificatePath: certificatePath,
            keyPath: keyPath
        )
        let recorder = SplunkHTTPRecorder()
        try await withSplunkHTTPServer(
            recorder: recorder,
            tlsContext: context
        ) { port in
            let configuration = try loopbackConfiguration(
                url: "https://127.0.0.1:\(port)",
                tls: SplunkTLSConfiguration(
                    caCertificatePath: caPath,
                    serverName: "localhost",
                    insecureSkipVerify: false
                ),
                verifyConnection: true
            )
            let session = try await SplunkDriverSession(
                configuration: configuration,
                transportFactory: URLSessionSplunkHTTPTransportFactory()
            )
            try await session.closeUsingPolicy()
            #expect(recorder.snapshot.count == 1)
            #expect(recorder.snapshot[0].method == .OPTIONS)
        }
    }
}

private struct SplunkRecordedHTTPRequest: Sendable {
    let method: HTTPMethod
    let uri: String
    let headers: HTTPHeaders
    let body: Data
}

private final class SplunkHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = [SplunkRecordedHTTPRequest]()

    var snapshot: [SplunkRecordedHTTPRequest] {
        lock.withLock { requests }
    }

    func append(_ request: SplunkRecordedHTTPRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class SplunkHTTPServerHandler:
    ChannelInboundHandler, @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: SplunkHTTPRecorder
    private var head: HTTPRequestHead?
    private var body = Data()

    init(recorder: SplunkHTTPRecorder) {
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            body.append(
                contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? []
            )
        case .end:
            guard let head else {
                context.close(promise: nil)
                return
            }
            recorder.append(
                SplunkRecordedHTTPRequest(
                    method: head.method,
                    uri: head.uri,
                    headers: head.headers,
                    body: body
                )
            )
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            context.write(
                wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: head.version,
                            status: .ok,
                            headers: headers
                        )
                    )
                ),
                promise: nil
            )
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            self.head = nil
            body.removeAll(keepingCapacity: true)
        }
    }
}

private func withSplunkHTTPServer(
    recorder: SplunkHTTPRecorder,
    tlsContext: NIOSSLContext? = nil,
    body: (Int) async throws -> Void
) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: Channel
    do {
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelInitializer { channel in
                let tlsFuture: EventLoopFuture<Void>
                if let tlsContext {
                    tlsFuture = channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: tlsContext)
                        )
                    }
                } else {
                    tlsFuture = channel.eventLoop.makeSucceededVoidFuture()
                }
                return tlsFuture.flatMap {
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            SplunkHTTPServerHandler(recorder: recorder)
                        )
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
    do {
        let port = try #require(channel.localAddress?.port)
        try await body(port)
        try await channel.close()
        try await group.shutdownGracefully()
    } catch {
        try? await channel.close()
        try? await group.shutdownGracefully()
        throw error
    }
}

private func loopbackConfiguration(
    url: String,
    tls: SplunkTLSConfiguration?,
    verifyConnection: Bool
) throws -> SplunkDriverConfiguration {
    try SplunkDriverConfiguration(
        endpoint: SplunkEndpoint(url),
        token: "protected-token",
        source: "",
        sourceType: "",
        index: "",
        format: .inline,
        gzipEnabled: false,
        gzipLevel: -1,
        indexAcknowledgement: false,
        verifyConnection: verifyConnection,
        tag: "container-id",
        hostname: "test-host",
        metadata: [:],
        tls: tls,
        policy: try SplunkConnectionPolicy(
            postFrequency: .seconds(60),
            postBatchSize: 2,
            bufferMaximum: 4,
            streamCapacity: 4,
            requestTimeout: .seconds(2),
            closeTimeout: .seconds(2),
            maximumResponseBytes: 1_024
        )
    )
}

private func fixturePath(_ name: String) throws -> String {
    try #require(
        Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        )?.path
    )
}

private func tlsServerContext(
    certificatePath: String,
    keyPath: String
) throws -> NIOSSLContext {
    let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath)
    let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
    return try NIOSSLContext(
        configuration: TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
    )
}
