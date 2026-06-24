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
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerEventsCommandTests {
    @Test func parsesRFC3339Timestamp() throws {
        let timestamp = try #require(ContainerEventTimestamp(argument: "2026-06-18T10:00:00Z"))

        #expect(timestamp.date == date("2026-06-18T10:00:00Z"))
    }

    @Test func parsesUnixTimestamp() throws {
        let timestamp = try #require(ContainerEventTimestamp(argument: "1781776800.25"))

        #expect(timestamp.date == Date(timeIntervalSince1970: 1_781_776_800.25))
    }

    @Test func rejectsInvalidTimestamp() {
        #expect(ContainerEventTimestamp(argument: "not-a-date") == nil)
    }

    @Test func eventOptionsUseParsedTimestamps() throws {
        let since = try #require(ContainerEventTimestamp(argument: "2026-06-18T10:00:00Z"))
        let until = try #require(ContainerEventTimestamp(argument: "2026-06-18T11:00:00Z"))

        let options = Application.ContainerEvents.eventOptions(since: since, until: until)

        #expect(options.since == since.date)
        #expect(options.until == until.date)
    }
}

private func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
}
