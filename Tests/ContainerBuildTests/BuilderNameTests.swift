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

import ContainerBuild
import Testing

struct BuilderNameTests {
    @Test
    func builderContainerIdUsesDefaultBuilder() throws {
        #expect(try Builder.containerId(for: nil) == "buildkit")
        #expect(try Builder.containerId(for: "") == "buildkit")
        #expect(try Builder.containerId(for: "  default  ") == "buildkit")
    }

    @Test
    func builderContainerIdScopesNamedBuilders() throws {
        #expect(try Builder.containerId(for: "remote") == "buildkit-remote")
        #expect(try Builder.containerId(for: "team.builder-1") == "buildkit-team.builder-1")
    }

    @Test
    func builderContainerIdRejectsInvalidNames() {
        #expect(throws: (any Error).self) {
            _ = try Builder.containerId(for: "-remote")
        }
        #expect(throws: (any Error).self) {
            _ = try Builder.containerId(for: "bad/name")
        }
    }
}
