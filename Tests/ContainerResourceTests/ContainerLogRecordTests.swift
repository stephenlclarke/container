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

@testable import ContainerResource

struct ContainerLogRecordTests {
    @Test func encodesFractionalTimestampAsString() throws {
        let timestamp = try #require(date("2026-06-18T10:00:00.123Z"))
        let record = ContainerLogRecord(timestamp: timestamp, stream: .stdout, data: Data("out\n".utf8))

        let data = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["timestamp"] as? String == "2026-06-18T10:00:00.123Z")
    }

    @Test func decodesLegacyNumericTimestamp() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.25)
        let payload = Data("out\n".utf8).base64EncodedString()
        let json = """
            {
              "timestamp": \(timestamp.timeIntervalSinceReferenceDate),
              "stream": "stdout",
              "data": "\(payload)"
            }
            """

        let record = try JSONDecoder().decode(ContainerLogRecord.self, from: Data(json.utf8))

        #expect(abs(record.timestamp.timeIntervalSince(timestamp)) < 0.000001)
        #expect(record.stream == .stdout)
        #expect(record.data == Data("out\n".utf8))
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
