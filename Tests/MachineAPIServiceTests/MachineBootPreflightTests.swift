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

@testable import MachineAPIService

struct MachineBootPreflightTests {
    @Test("Independent machine boot preparation overlaps")
    func preparationRunsConcurrently() async throws {
        let entrants = PollingCountdown(count: 3)
        let release = PollingGate()
        let preparation = Task {
            try await ConcurrentMachineBootPreparation.run(
                discovery: {
                    await entrants.arrive()
                    try await release.wait()
                    return ["container"]
                },
                configuration: {
                    await entrants.arrive()
                    try await release.wait()
                    return "configuration"
                },
                kernel: {
                    await entrants.arrive()
                    try await release.wait()
                    return "kernel"
                }
            )
        }

        do {
            try await entrants.wait(timeout: .seconds(1))
        } catch {
            preparation.cancel()
            await release.open()
            throw error
        }
        await release.open()
        let result = try await preparation.value

        #expect(result.discovery == ["container"])
        #expect(result.configuration == "configuration")
        #expect(result.kernel == "kernel")
    }

    @Test("A failed preparation cancels unfinished siblings")
    func failureCancelsSiblings() async throws {
        let entrants = PollingCountdown(count: 3)
        let cancellations = PollingCountdown(count: 2)

        let error = await #expect(throws: PreparationError.self) {
            try await ConcurrentMachineBootPreparation.run(
                discovery: {
                    await entrants.arrive()
                    try await entrants.wait(timeout: .seconds(1))
                    throw PreparationError.expected
                },
                configuration: {
                    await entrants.arrive()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return "configuration"
                    } catch {
                        await cancellations.arrive()
                        throw error
                    }
                },
                kernel: {
                    await entrants.arrive()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        return "kernel"
                    } catch {
                        await cancellations.arrive()
                        throw error
                    }
                }
            )
        }
        #expect(error == .expected)
        try await cancellations.wait(timeout: .seconds(1))
    }
}

struct MachineCreationPreflightTests {
    @Test("Bundle and image preparation overlap before rootfs finalization")
    func preparationRunsConcurrently() async throws {
        let entrants = PollingCountdown(count: 2)
        let release = PollingGate()
        let finalized = PollingCountdown(count: 1)
        let preparation = Task {
            try await ConcurrentMachineCreationPreparation.run(
                bundle: {
                    await entrants.arrive()
                    try await release.wait()
                    return "bundle"
                },
                filesystem: {
                    await entrants.arrive()
                    try await release.wait()
                    return "filesystem"
                },
                finalize: { bundle, filesystem in
                    #expect(bundle == "bundle")
                    #expect(filesystem == "filesystem")
                    await finalized.arrive()
                }
            )
        }

        do {
            try await entrants.wait(timeout: .seconds(1))
        } catch {
            preparation.cancel()
            await release.open()
            throw error
        }
        await release.open()
        let bundle = try await preparation.value

        #expect(bundle == "bundle")
        try await finalized.wait(timeout: .seconds(1))
    }
}

private enum PreparationError: Error {
    case expected
    case timedOut
}

private actor PollingCountdown {
    private var remaining: Int

    init(count: Int) {
        self.remaining = count
    }

    func arrive() {
        remaining -= 1
    }

    func wait(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while remaining > 0 {
            guard clock.now < deadline else {
                throw PreparationError.timedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor PollingGate {
    private var isOpen = false

    func wait() async throws {
        while !isOpen {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func open() {
        isOpen = true
    }
}
