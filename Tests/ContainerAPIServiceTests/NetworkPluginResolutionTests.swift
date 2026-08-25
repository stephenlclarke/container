//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Testing

@testable import ContainerAPIService

struct NetworkPluginResolutionTests {
    @Test("Batch plugin resolution preserves attachment order")
    func preservesOrder() throws {
        let available = [
            "frontend": "vmnet",
            "backend": "socket",
        ]
        let plugins = try NetworksService.resolvePlugins(
            for: ["backend", "frontend", "backend"]
        ) { available[$0] }

        #expect(plugins == ["socket", "vmnet", "socket"])
    }

    @Test("Batch plugin resolution reports the first missing network")
    func reportsFirstMissingNetwork() {
        let available = ["present": "vmnet"]
        let error = #expect(throws: ContainerizationError.self) {
            try NetworksService.resolvePlugins(
                for: ["present", "first-missing", "second-missing"]
            ) { available[$0] }
        }

        #expect(error?.code == .notFound)
        #expect(error?.message == "no network for id first-missing")
    }

    @Test("An empty attachment list resolves without networks")
    func resolvesEmptyList() throws {
        #expect(try NetworksService.resolvePlugins(for: []) { _ in nil }.isEmpty)
    }
}
