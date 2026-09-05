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
import ContainerXPC
import Containerization
import Testing

@testable import ContainerRuntimeLinuxServer

struct ExitWaiterTests {
    @Test
    func repeatedExitResumesPendingWaiterOnce() async {
        let waiter = RuntimeService.ExitWaiter()

        let received = await withCheckedContinuation { continuation in
            waiter.wait(continuation)
            #expect(waiter.continuations.count == 1)

            waiter.doExit(exitStatus: ExitStatus(exitCode: 7))
            waiter.doExit(exitStatus: ExitStatus(exitCode: 9))
        }

        #expect(received.exitCode == 7)
        #expect(waiter.exitStatus?.exitCode == 7)
        #expect(waiter.continuations.isEmpty)
        #expect(waiter.didDeliverExit)

        let late = await withCheckedContinuation { continuation in
            waiter.wait(continuation)
        }
        #expect(late.exitCode == 7)
    }

    @Test
    func exitWithoutWaiterRemainsUndeliveredUntilLateWait() async {
        let waiter = RuntimeService.ExitWaiter()

        waiter.doExit(exitStatus: ExitStatus(exitCode: 11))
        #expect(!waiter.didDeliverExit)

        let late = await withCheckedContinuation { continuation in
            waiter.wait(continuation)
        }
        #expect(late.exitCode == 11)
        #expect(waiter.didDeliverExit)
    }

    @Test
    func internalKillWaitDoesNotConsumeClientExitStatus() async {
        let waiter = RuntimeService.ExitWaiter()

        let internalStatus = await withCheckedContinuation { continuation in
            waiter.wait(continuation, deliversToClient: false)
            waiter.doExit(exitStatus: ExitStatus(exitCode: 137))
        }

        #expect(internalStatus.exitCode == 137)
        #expect(!waiter.didDeliverExit)

        let clientStatus = await withCheckedContinuation { continuation in
            waiter.wait(continuation)
        }
        #expect(clientStatus.exitCode == 137)
        #expect(waiter.didDeliverExit)
    }

    @Test
    func waitRequestsDefaultToClientDeliveryButSupportObservers() {
        let legacy = XPCMessage(route: RuntimeRoutes.wait.rawValue)
        #expect(RuntimeService.waitDeliversToClient(legacy))

        let observer = XPCMessage(route: RuntimeRoutes.wait.rawValue)
        observer.set(key: RuntimeKeys.deliversToClient.rawValue, value: false)
        #expect(!RuntimeService.waitDeliversToClient(observer))
    }
}
