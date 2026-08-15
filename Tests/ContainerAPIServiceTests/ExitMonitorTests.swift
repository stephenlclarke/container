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

import ContainerRuntimeClient
import Containerization
import Testing

private actor ExitMonitorCallbackProbe {
    private var cancelled: Bool?
    private var waiters = [CheckedContinuation<Bool, Never>]()

    func record(cancelled: Bool) {
        self.cancelled = cancelled
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: cancelled)
        }
    }

    func value() async -> Bool {
        if let cancelled {
            return cancelled
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor ExitMonitorCallbackCount {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

struct ExitMonitorTests {
    @Test
    func completedCallbackCanStopTrackingWithoutCancellingItself()
        async throws
    {
        let monitor = ExitMonitor()
        let probe = ExitMonitorCallbackProbe()
        let id = "completed-callback"
        try await monitor.registerProcess(id: id) { callbackID, _ in
            await monitor.stopTracking(id: callbackID)
            await probe.record(cancelled: Task.isCancelled)
        }
        try await monitor.track(id: id) {
            ExitStatus(exitCode: 0)
        }

        #expect(!(await probe.value()))
    }

    @Test
    func cancelledTrackerCannotInvokeStaleCallback() async throws {
        let monitor = ExitMonitor()
        let staleCallbacks = ExitMonitorCallbackCount()
        let replacementCallback = ExitMonitorCallbackProbe()
        let id = "replacement-runtime"

        try await monitor.registerProcess(id: id) { _, _ in
            await staleCallbacks.increment()
        }
        try await monitor.track(id: id) {
            try await Task.sleep(for: .seconds(60))
            return ExitStatus(exitCode: 0)
        }
        await monitor.stopTracking(id: id)

        try await monitor.registerProcess(id: id) { _, _ in
            await replacementCallback.record(cancelled: Task.isCancelled)
        }
        try await monitor.track(id: id) {
            ExitStatus(exitCode: 0)
        }

        #expect(!(await replacementCallback.value()))
        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(await staleCallbacks.value() == 0)
    }
}
