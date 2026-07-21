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

#if os(macOS)
import ContainerizationError
@preconcurrency import Foundation
import Logging
import Testing

@testable import ContainerXPC

@Suite(.timeLimit(.minutes(1)), .serialized)
struct XPCClientTests {
    @Test(arguments: [0, 1, 2])
    func fileHandlesPreserveEveryDescriptor(count: Int) throws {
        let message = XPCMessage(route: "file-handles")
        let sourceHandles = try (0..<count).map { _ in
            try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        }
        try message.set(key: "file-handles", value: sourceHandles)

        let receivedHandles = try #require(message.fileHandles(key: "file-handles"))
        defer {
            for handle in receivedHandles {
                try? handle.close()
            }
        }

        #expect(receivedHandles.count == count)
        #expect(receivedHandles.allSatisfy { $0.fileDescriptor >= 0 })
    }

    @Test
    func fileHandlesRejectNonArrayValue() throws {
        let message = XPCMessage(route: "file-handles")
        let sourceHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        message.set(key: "file-handles", value: sourceHandle)

        #expect(message.fileHandles(key: "file-handles") == nil)
    }

    @Test
    func responseTimeoutReturnsWithinBound() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await client.send(XPCMessage(route: "hang"), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            let elapsed = start.duration(to: clock.now)
            #expect(error.code == .timeout)
            #expect(error.message.contains("XPC timeout for request to test.container.xpc/hang"))
            #expect(elapsed < .seconds(2))
        }
    }

    @Test
    func responseTimeoutHandlesMessagesWithoutRoute() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(XPCMessage(object: xpc_dictionary_create_empty()), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("XPC timeout for request to test.container.xpc/nil"))
        }
    }

    @Test
    func sendWithoutResponseTimeoutCompletesWhenServerReplies() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let response = try await client.send(XPCMessage(route: "echo"))
        #expect(response.string(key: "result") == "ok")
    }

    @Test
    func clientCanBeReusedAfterResponseTimeout() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()

        do {
            _ = try await client.send(XPCMessage(route: "hang"), responseTimeout: .milliseconds(100))
            Issue.record("expected send to time out")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        let response = try await client.send(XPCMessage(route: "echo"), responseTimeout: .seconds(1))
        #expect(response.string(key: "result") == "ok")
    }

    @Test
    func closingClientInterruptsPendingRequest() async throws {
        let server = AnonymousXPCServer()
        defer { server.close() }

        let client = server.makeClient()
        let request = Task {
            try await client.send(XPCMessage(route: "hang"), responseTimeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        client.close()

        do {
            _ = try await request.value
            Issue.record("expected closed client to interrupt the pending request")
        } catch let error as ContainerizationError {
            #expect(error.code == .interrupted)
        }
    }

    @Test
    func serverRouteSessionDisconnectHandlersFire() async throws {
        let probe = DisconnectProbe()
        let listener = xpc_connection_create(nil, nil)
        let server = XPCServer(
            connection: listener,
            routes: [
                "register-disconnect": { message, session in
                    await session.onDisconnect {
                        await probe.fire()
                    }
                    let response = message.reply()
                    response.set(key: "result", value: "registered")
                    return response
                }
            ],
            log: Logger(label: "test.container.xpc.server-session")
        )
        let serverTask = Task {
            try await server.listen()
        }
        defer {
            serverTask.cancel()
            xpc_connection_cancel(listener)
        }

        try await Task.sleep(for: .milliseconds(50))
        let endpoint = xpc_endpoint_create(listener)
        let client = XPCClient(connection: xpc_connection_create_from_endpoint(endpoint), label: "test.container.xpc")
        let response = try await client.send(XPCMessage(route: "register-disconnect"), responseTimeout: .seconds(1))
        #expect(response.string(key: "result") == "registered")

        client.close()
        try await probe.wait(timeout: .seconds(1))
    }
}

private actor DisconnectProbe {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        fired = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.waitForFire()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ContainerizationError(.timeout, message: "disconnect handler did not fire")
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForFire() async {
        if fired {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class AnonymousXPCServer: @unchecked Sendable {
    private let listener: xpc_connection_t
    private let lock = NSLock()
    private var connections = [xpc_connection_t]()
    private var pendingRequests = [xpc_object_t]()

    init() {
        listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { [weak self] object in
            switch xpc_get_type(object) {
            case XPC_TYPE_CONNECTION:
                self?.accept(connection: object)
            case XPC_TYPE_ERROR:
                break
            default:
                fatalError("unhandled xpc object type: \(xpc_get_type(object))")
            }
        }
        xpc_connection_activate(listener)
    }

    func makeClient() -> XPCClient {
        let endpoint = xpc_endpoint_create(listener)
        let connection = xpc_connection_create_from_endpoint(endpoint)
        return XPCClient(connection: connection, label: "test.container.xpc")
    }

    func close() {
        xpc_connection_cancel(listener)
        lock.withLock {
            for connection in connections {
                xpc_connection_cancel(connection)
            }
            connections.removeAll()
            pendingRequests.removeAll()
        }
    }

    private func accept(connection: xpc_connection_t) {
        lock.withLock {
            connections.append(connection)
        }
        nonisolated(unsafe) let connection = connection
        xpc_connection_set_event_handler(connection) { [weak self] object in
            guard let self else {
                return
            }
            switch xpc_get_type(object) {
            case XPC_TYPE_DICTIONARY:
                let message = XPCMessage(object: object)
                switch message.string(key: XPCMessage.routeKey) {
                case "echo":
                    guard let reply = xpc_dictionary_create_reply(object) else {
                        return
                    }
                    xpc_dictionary_set_string(reply, "result", "ok")
                    xpc_connection_send_message(connection, reply)
                case "hang":
                    self.lock.withLock {
                        self.pendingRequests.append(object)
                    }
                default:
                    self.lock.withLock {
                        self.pendingRequests.append(object)
                    }
                }
            case XPC_TYPE_ERROR:
                break
            default:
                fatalError("unhandled xpc object type: \(xpc_get_type(object))")
            }
        }
        xpc_connection_activate(connection)
    }
}
#endif
