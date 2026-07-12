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

struct ContainerProcessesTests {
    @Test func roundTripsThroughJSON() throws {
        let processes = ContainerProcesses(
            id: "api",
            processIdentifiers: [42, 99],
            processes: [
                ContainerProcessInfo(
                    uid: "root",
                    pid: 42,
                    ppid: 7,
                    cpu: 0,
                    startTime: "15:33",
                    tty: "?",
                    time: "00:00:00",
                    command: "sleep 60"
                )
            ]
        )

        let data = try JSONEncoder().encode(processes)
        let decoded = try JSONDecoder().decode(ContainerProcesses.self, from: data)

        #expect(decoded == processes)
    }

    @Test func decodesLegacyProcessIdentifierPayloads() throws {
        let data = Data(#"{"id":"api","processIdentifiers":[42,99]}"#.utf8)

        let decoded = try JSONDecoder().decode(ContainerProcesses.self, from: data)

        #expect(decoded == ContainerProcesses(id: "api", processIdentifiers: [42, 99]))
    }
}
