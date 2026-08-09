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

public struct AWSLogsInputEvent: Equatable, Sendable {
    public let message: String
    public let timestampMilliseconds: Int64
    public let insertionOrder: Int

    public init(
        message: String,
        timestampMilliseconds: Int64,
        insertionOrder: Int
    ) {
        self.message = message
        self.timestampMilliseconds = timestampMilliseconds
        self.insertionOrder = insertionOrder
    }
}

public struct AWSLogsPutResult: Equatable, Sendable {
    public let nextSequenceToken: String?

    public init(nextSequenceToken: String?) {
        self.nextSequenceToken = nextSequenceToken
    }
}

public enum AWSLogsClientError: Error, Equatable, Sendable {
    case resourceNotFound
    case resourceAlreadyExists
    case dataAlreadyAccepted(expectedSequenceToken: String?)
    case invalidSequenceToken(expectedSequenceToken: String?)
    case requestFailed
}

public protocol AWSLogsClient: Sendable {
    func createLogGroup(name: String) async throws
    func createLogStream(group: String, stream: String) async throws
    func putLogEvents(
        group: String,
        stream: String,
        events: [AWSLogsInputEvent],
        sequenceToken: String?
    ) async throws -> AWSLogsPutResult
    func close() async
}

public protocol AWSLogsClientFactory: Sendable {
    func makeClient(
        configuration: AWSLogsDriverConfiguration
    ) async throws -> any AWSLogsClient
}
