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
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerLifecycleCommandTests {
    @Test func pauseAndUnpauseAreReachableViaHelp() {
        #expect(HelpCommand.resolveSubcommand(path: ["pause"]) != nil)
        #expect(HelpCommand.resolveSubcommand(path: ["unpause"]) != nil)
        #expect(HelpCommand.resolveSubcommand(path: ["resize"]) != nil)
    }

    @Test func pauseSelectionRequiresContainersOrAll() {
        #expect(throws: ContainerizationError.self) {
            try Application.ContainerPause.validateSelection(containerIds: [], all: false)
        }
        #expect(throws: Never.self) {
            try Application.ContainerPause.validateSelection(containerIds: ["api"], all: false)
        }
        #expect(throws: Never.self) {
            try Application.ContainerPause.validateSelection(containerIds: [], all: true)
        }
        #expect(throws: ContainerizationError.self) {
            try Application.ContainerPause.validateSelection(containerIds: ["api"], all: true)
        }
    }

    @Test func unpauseSelectionRequiresContainersOrAll() {
        #expect(throws: ContainerizationError.self) {
            try Application.ContainerUnpause.validateSelection(containerIds: [], all: false)
        }
        #expect(throws: Never.self) {
            try Application.ContainerUnpause.validateSelection(containerIds: ["api"], all: false)
        }
        #expect(throws: Never.self) {
            try Application.ContainerUnpause.validateSelection(containerIds: [], all: true)
        }
        #expect(throws: ContainerizationError.self) {
            try Application.ContainerUnpause.validateSelection(containerIds: ["api"], all: true)
        }
    }

    @Test func resizeParsesMemoryTargets() throws {
        #expect(try Application.ContainerResize.memoryInBytes("512M") == 512 * 1024 * 1024)
        #expect(try Application.ContainerResize.memoryInBytes("2G") == 2 * 1024 * 1024 * 1024)
        #expect(throws: (any Error).self) {
            try Application.ContainerResize.memoryInBytes("invalid")
        }
    }
}
