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
import ContainerXPC
import ContainerizationError
import Foundation

public protocol EngineLinuxSandboxRuntimeClientV1: EngineLinuxSandboxRuntimeV1,
    EngineLinuxSandboxWorkloadRuntimeV1,
    EngineLinuxSandboxServiceRuntimeV1
{}

extension RuntimeClient: EngineLinuxSandboxRuntimeV1 {
    public func boot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootReceiptV1 {
        try await engineSandboxCall(route: .engineSandboxBoot, request: request)
    }

    public func observeBoot(
        _ request: EngineLinuxSandboxBootRequestV1
    ) async throws -> EngineLinuxSandboxBootObservationV1 {
        try await engineSandboxCall(route: .engineSandboxObserveBoot, request: request)
    }

    public func shutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownReceiptV1 {
        try await engineSandboxCall(route: .engineSandboxShutdown, request: request)
    }

    public func observeShutdown(
        _ request: EngineLinuxSandboxShutdownRequestV1
    ) async throws -> EngineLinuxSandboxShutdownObservationV1 {
        try await engineSandboxCall(route: .engineSandboxObserveShutdown, request: request)
    }
}

extension RuntimeClient: EngineLinuxSandboxWorkloadRuntimeV1 {
    public func startWorkload(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1,
        stdio: [FileHandle?]
    ) async throws -> WorkloadProcessReceiptV1 {
        try await engineSandboxCall(
            route: .engineSandboxStartWorkload,
            request: request,
            stdio: stdio
        )
    }

    public func observeWorkloadStart(
        _ request: EngineLinuxSandboxWorkloadStartRequestV1
    ) async throws -> WorkloadProcessObservationV1 {
        try await engineSandboxCall(
            route: .engineSandboxObserveWorkloadStart,
            request: request
        )
    }

    public func stopWorkload(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopReceiptV1 {
        try await engineSandboxCall(
            route: .engineSandboxStopWorkload,
            request: request
        )
    }

    public func observeWorkloadStop(
        _ request: EngineLinuxSandboxWorkloadStopRequestV1
    ) async throws -> EngineLinuxSandboxWorkloadStopObservationV1 {
        try await engineSandboxCall(
            route: .engineSandboxObserveWorkloadStop,
            request: request
        )
    }
}

extension RuntimeClient: EngineLinuxSandboxServiceRuntimeV1 {
    public func dialService(
        _ requestValue: EngineLinuxSandboxServiceDialRequestV1
    ) async throws -> FileHandle {
        let request = XPCMessage(route: RuntimeRoutes.engineSandboxDialService.rawValue)
        try request.setEngineSandboxPayload(requestValue)
        let response: XPCMessage
        do {
            response = try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to dial protected service port \(requestValue.port) on Engine Linux sandbox \(id)",
                cause: error
            )
        }
        guard let handle = response.fileHandle(key: RuntimeKeys.fd.rawValue) else {
            throw ContainerizationError(
                .internalError,
                message: "missing protected service file descriptor for Engine Linux sandbox \(id)"
            )
        }
        return handle
    }
}

extension RuntimeClient: EngineLinuxSandboxRuntimeClientV1 {}

extension RuntimeClient {

    private func engineSandboxCall<Request: Encodable, Response: Decodable>(
        route: RuntimeRoutes,
        request value: Request,
        stdio: [FileHandle?] = []
    ) async throws -> Response {
        let request = XPCMessage(route: route.rawValue)
        try request.setEngineSandboxPayload(value)
        try request.setEngineSandboxStdio(stdio)
        let response: XPCMessage
        do {
            response = try await client.send(request)
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "Engine Linux sandbox request failed for \(id)",
                cause: error
            )
        }
        return try response.engineSandboxPayload(Response.self)
    }
}

extension XPCMessage {
    public func setEngineSandboxPayload<Value: Encodable>(_ value: Value) throws {
        set(
            key: RuntimeKeys.engineSandboxPayload.rawValue,
            value: try JSONEncoder().encode(value)
        )
    }

    public func engineSandboxPayload<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard let data = dataNoCopy(key: RuntimeKeys.engineSandboxPayload.rawValue) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "missing Engine Linux sandbox payload"
            )
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public func setEngineSandboxStdio(_ stdio: [FileHandle?]) throws {
        for (index, handle) in stdio.enumerated() {
            let key: RuntimeKeys
            switch index {
            case 0:
                key = .stdin
            case 1:
                key = .stdout
            case 2:
                key = .stderr
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid shared sandbox stdio descriptor \(index)"
                )
            }
            if let handle {
                set(key: key.rawValue, value: handle)
            }
        }
    }

    public func engineSandboxStdio() -> [FileHandle?] {
        [
            fileHandle(key: RuntimeKeys.stdin.rawValue),
            fileHandle(key: RuntimeKeys.stdout.rawValue),
            fileHandle(key: RuntimeKeys.stderr.rawValue),
        ]
    }
}
