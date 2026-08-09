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
import Testing

@testable import DockerSemanticHelper

@Suite("Docker semantic helper protocol")
struct DockerSemanticHelperProtocolTests {
    @Test("binary byte fields preserve invalid UTF-8")
    func byteFieldsPreserveArbitraryBytes() throws {
        let expected = Data([0xff, 0x00, 0xc0, 0x80])
        var writer = DockerSemanticBinaryWriter()
        try writer.appendByteField(expected)

        var reader = DockerSemanticBinaryReader(writer.data)
        #expect(try reader.readByteField() == expected)
        #expect(reader.isAtEnd)
    }

    @Test("duplicate map keys fail before transport")
    func duplicateMapKeysFail() {
        var writer = DockerSemanticBinaryWriter()
        #expect(throws: DockerSemanticHelperError.inputLimitExceeded) {
            try writer.appendByteMap([
                DockerSemanticBytePair(key: "same", value: "one"),
                DockerSemanticBytePair(key: "same", value: "two"),
            ])
        }
    }

    @Test("protocol header round trips")
    func protocolHeaderRoundTrips() throws {
        let expected = DockerSemanticProtocolV1.Header(
            kind: .request,
            opcode: .templateRender,
            requestID: 42,
            timeoutNanoseconds: 250_000_000,
            status: 0,
            flags: 0
        )
        let encoded = try expected.encode(payloadByteCount: 7)
        #expect(encoded.count == 4 + DockerSemanticProtocolV1.headerBytes)
        #expect(
            try DockerSemanticProtocolV1.Header.decode(encoded.dropFirst(4))
                == expected
        )
    }
}
