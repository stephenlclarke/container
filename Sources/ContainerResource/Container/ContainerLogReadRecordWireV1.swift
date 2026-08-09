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

public enum ContainerLogReadRecordWireError: Error, Equatable, Sendable {
    case invalidStream(String)
    case unsupportedSchemaVersion(UInt32)
}

/// A bounded transport projection of ``ContainerLogReadRecordV1``.
///
/// The core record deliberately has no generic persistence conformance. This
/// type is an explicit, versioned wire codec used only to move exact active
/// reader records across the runtime XPC file-descriptor boundary. Decoding
/// always re-enters the core record's validation boundary before a value is
/// exposed to a caller.
public struct ContainerLogReadRecordWireV1: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1
    public static let maximumEncodedRecordBytes = 512 * 1_024

    public let schemaVersion: UInt32
    public let stream: ContainerLogStream
    public let secondsSinceUnixEpoch: Int64
    public let nanoseconds: UInt32
    public let data: Data
    public let attributes: [String: String]
    public let sequence: UInt64
    public let processGeneration: UInt64?

    public init(_ record: ContainerLogReadRecordV1) {
        self.schemaVersion = Self.currentSchemaVersion
        self.stream = record.stream
        self.secondsSinceUnixEpoch = record.timestamp.secondsSinceUnixEpoch
        self.nanoseconds = record.timestamp.nanoseconds
        self.data = record.data
        self.attributes = record.attributes
        self.sequence = record.sequence
        self.processGeneration = record.processGeneration
    }

    public func record() throws -> ContainerLogReadRecordV1 {
        try ContainerLogReadRecordV1(
            stream: stream,
            timestamp: ContainerLogTimestamp(
                secondsSinceUnixEpoch: secondsSinceUnixEpoch,
                nanoseconds: nanoseconds
            ),
            data: data,
            attributes: attributes,
            sequence: sequence,
            processGeneration: processGeneration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case stream
        case secondsSinceUnixEpoch
        case nanoseconds
        case data
        case attributes
        case sequence
        case processGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ContainerLogReadRecordWireError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        let streamValue = try container.decode(String.self, forKey: .stream)
        guard let stream = ContainerLogStream(rawValue: streamValue) else {
            throw ContainerLogReadRecordWireError.invalidStream(streamValue)
        }
        let secondsSinceUnixEpoch = try container.decode(
            Int64.self,
            forKey: .secondsSinceUnixEpoch
        )
        let nanoseconds = try container.decode(UInt32.self, forKey: .nanoseconds)
        let data = try container.decode(Data.self, forKey: .data)
        let attributes =
            try container.decodeIfPresent(
                [String: String].self,
                forKey: .attributes
            ) ?? [:]
        let sequence = try container.decode(UInt64.self, forKey: .sequence)
        let processGeneration = try container.decodeIfPresent(
            UInt64.self,
            forKey: .processGeneration
        )
        let record = try ContainerLogReadRecordV1(
            stream: stream,
            timestamp: ContainerLogTimestamp(
                secondsSinceUnixEpoch: secondsSinceUnixEpoch,
                nanoseconds: nanoseconds
            ),
            data: data,
            attributes: attributes,
            sequence: sequence,
            processGeneration: processGeneration
        )
        self.init(record)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(stream.rawValue, forKey: .stream)
        try container.encode(
            secondsSinceUnixEpoch,
            forKey: .secondsSinceUnixEpoch
        )
        try container.encode(nanoseconds, forKey: .nanoseconds)
        try container.encode(data, forKey: .data)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(
            processGeneration,
            forKey: .processGeneration
        )
    }
}
