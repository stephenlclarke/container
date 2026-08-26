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

import ContainerizationError
import Testing

@testable import MachineAPIService

struct MachineCreationReservationsTests {
    @Test("Independent machines can reserve their identifiers")
    func reserveIndependentMachines() throws {
        var reservations = MachineCreationReservations()

        try reservations.reserve("first", existing: [])
        try reservations.reserve("second", existing: [])

        #expect(reservations.ids == ["first", "second"])
    }

    @Test("A pending creation reserves its machine identifier")
    func rejectPendingIdentifierConflict() throws {
        var reservations = MachineCreationReservations()
        try reservations.reserve("duplicate", existing: [])

        let error = #expect(throws: ContainerizationError.self) {
            try reservations.reserve("duplicate", existing: [])
        }
        #expect(error?.code == .exists)
        #expect(error?.message == "container machine already exists: duplicate")
    }

    @Test("A committed machine reserves its identifier")
    func rejectCommittedIdentifierConflict() {
        var reservations = MachineCreationReservations()

        let error = #expect(throws: ContainerizationError.self) {
            try reservations.reserve("duplicate", existing: ["duplicate"])
        }
        #expect(error?.code == .exists)
        #expect(error?.message == "container machine already exists: duplicate")
    }

    @Test("Rolling back creation releases the identifier")
    func rollbackReleasesIdentifier() throws {
        var reservations = MachineCreationReservations()
        try reservations.reserve("retry", existing: [])

        let removed = reservations.remove("retry")
        #expect(removed)
        try reservations.reserve("retry", existing: [])

        #expect(reservations.ids == ["retry"])
    }

    @Test("Committing creation consumes the identifier")
    func commitConsumesIdentifier() throws {
        var reservations = MachineCreationReservations()
        try reservations.reserve("committed", existing: [])

        let committed = reservations.remove("committed")
        let missing = reservations.remove("committed")
        #expect(committed)
        #expect(!missing)
        #expect(reservations.ids.isEmpty)
    }
}
