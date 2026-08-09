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

enum DockerSemanticProtocolV1 {
    static let magic = Data([0x44, 0x43, 0x53, 0x48])  // DCSH
    static let headerBytes = 28
    static let maximumFrameBytes = 16 * 1024 * 1024
    static let maximumByteFieldBytes = 2 * 1024 * 1024
    static let maximumTemplateBytes = 2 * 1024 * 1024
    static let maximumRegularExpressionBytes = 64 * 1024
    static let maximumCandidateBytes = 64 * 1024
    static let maximumCandidateCount = 4_096
    static let maximumCollectionCount = 4_096
    static let maximumMapCount = 1_024
    static let maximumMapKeyBytes = 4 * 1024
    static let maximumOutputBytes = 2 * 1024 * 1024

    enum Kind: UInt8 {
        case request = 1
        case response = 2
    }

    enum Opcode: UInt8 {
        case hello = 1
        case regularExpressionBatch = 2
        case templateRender = 3
        case urlParse = 4
        case cancel = 5
        case fluentdAddress = 6
        case gelfAddress = 7
        case syslogAddress = 8
        case gcpStart = 9
        case gcpLog = 10
        case gcpFlush = 11
        case gcpClose = 12
    }

    struct Header: Equatable {
        let kind: Kind
        let opcode: Opcode
        let requestID: UInt64
        let timeoutNanoseconds: UInt64
        let status: UInt16
        let flags: UInt16

        func encode(payloadByteCount: Int) throws -> Data {
            let (frameBytes, overflow) = DockerSemanticProtocolV1.headerBytes
                .addingReportingOverflow(payloadByteCount)
            guard
                !overflow,
                frameBytes <= DockerSemanticProtocolV1.maximumFrameBytes
            else {
                throw DockerSemanticHelperError.inputLimitExceeded
            }
            var writer = DockerSemanticBinaryWriter()
            writer.append(UInt32(frameBytes))
            writer.append(DockerSemanticProtocolV1.magic)
            writer.append(DockerSemanticHelperProvenance.protocolVersion)
            writer.append(kind.rawValue)
            writer.append(opcode.rawValue)
            writer.append(requestID)
            writer.append(timeoutNanoseconds)
            writer.append(status)
            writer.append(flags)
            return writer.data
        }

        static func decode(_ bytes: Data) throws -> Self {
            guard bytes.count == DockerSemanticProtocolV1.headerBytes else {
                throw DockerSemanticHelperError.protocolViolation
            }
            var reader = DockerSemanticBinaryReader(bytes)
            guard
                try reader.readData(count: 4) == DockerSemanticProtocolV1.magic,
                try reader.read(UInt16.self)
                    == DockerSemanticHelperProvenance.protocolVersion,
                let kind = Kind(rawValue: try reader.read(UInt8.self)),
                let opcode = Opcode(rawValue: try reader.read(UInt8.self))
            else {
                throw DockerSemanticHelperError.protocolViolation
            }
            return Header(
                kind: kind,
                opcode: opcode,
                requestID: try reader.read(UInt64.self),
                timeoutNanoseconds: try reader.read(UInt64.self),
                status: try reader.read(UInt16.self),
                flags: try reader.read(UInt16.self)
            )
        }
    }
}

struct DockerSemanticBinaryWriter {
    private(set) var data = Data()

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func appendByteField(
        _ value: Data,
        maximumBytes: Int = DockerSemanticProtocolV1.maximumByteFieldBytes
    ) throws {
        guard value.count <= maximumBytes else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        append(UInt32(value.count))
        append(value)
    }

    mutating func appendByteList(
        _ values: [Data],
        maximumCount: Int = DockerSemanticProtocolV1.maximumCollectionCount,
        maximumValueBytes: Int = DockerSemanticProtocolV1.maximumByteFieldBytes
    ) throws {
        guard values.count <= maximumCount else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        append(UInt32(values.count))
        for value in values {
            try appendByteField(value, maximumBytes: maximumValueBytes)
        }
    }

    mutating func appendByteMap(
        _ values: [DockerSemanticBytePair]
    ) throws {
        guard values.count <= DockerSemanticProtocolV1.maximumMapCount else {
            throw DockerSemanticHelperError.inputLimitExceeded
        }
        var uniqueKeys = Set<Data>()
        for pair in values {
            guard uniqueKeys.insert(pair.key).inserted else {
                throw DockerSemanticHelperError.inputLimitExceeded
            }
        }
        let sorted = values.sorted {
            $0.key.lexicographicallyPrecedes($1.key)
        }
        append(UInt32(sorted.count))
        for pair in sorted {
            try appendByteField(
                pair.key,
                maximumBytes: DockerSemanticProtocolV1.maximumMapKeyBytes
            )
            try appendByteField(pair.value)
        }
    }

    mutating func appendLogInfo(_ info: DockerLogTemplateInfo) throws {
        try appendByteField(info.containerID)
        try appendByteField(info.containerName)
        try appendByteField(info.containerEntrypoint)
        try appendByteList(info.containerArguments)
        try appendByteField(info.containerImageID)
        try appendByteField(info.containerImageName)
        append(info.containerCreatedSeconds)
        append(info.containerCreatedNanoseconds)
        try appendByteList(info.containerEnvironment)
        try appendByteMap(info.containerLabels)
        try appendByteField(info.logPath)
        try appendByteField(info.daemonName)
        try appendByteField(info.hostname)
    }
}

struct DockerSemanticBinaryReader {
    private let bytes: Data
    private var index: Data.Index

    init(_ bytes: Data) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var isAtEnd: Bool { index == bytes.endIndex }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let count = MemoryLayout<T>.size
        let data = try readData(count: count)
        return data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(as: T.self).bigEndian
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= bytes.distance(from: index, to: bytes.endIndex)
        else {
            throw DockerSemanticHelperError.protocolViolation
        }
        let end = bytes.index(index, offsetBy: count)
        defer { index = end }
        return bytes.subdata(in: index..<end)
    }

    mutating func readByteField(
        maximumBytes: Int = DockerSemanticProtocolV1.maximumByteFieldBytes
    ) throws -> Data {
        let count = try read(UInt32.self)
        guard count <= UInt32(maximumBytes) else {
            throw DockerSemanticHelperError.protocolViolation
        }
        return try readData(count: Int(count))
    }

    mutating func readByteFields(
        count: Int,
        maximumBytes: Int = DockerSemanticProtocolV1.maximumByteFieldBytes
    ) throws -> [Data] {
        guard count <= DockerSemanticProtocolV1.maximumCollectionCount else {
            throw DockerSemanticHelperError.protocolViolation
        }
        var result = [Data]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readByteField(maximumBytes: maximumBytes))
        }
        return result
    }
}
