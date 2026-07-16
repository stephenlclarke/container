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

import Testing

@testable import ContainerResource

struct ConfigValidationTests {
    @Test(arguments: ["app-config", "app_config", "app.config", "1config", "a" + String(repeating: "x", count: 254)])
    func acceptsSafeConfigNames(_ name: String) {
        #expect(ConfigStorage.isValidConfigName(name))
        #expect(ConfigResource.nameValid(name))
    }

    @Test(arguments: ["", ".config", "_config", "-config", "config/path", "../config", "/tmp/config", "config name", "a" + String(repeating: "x", count: 255)])
    func rejectsUnsafeConfigNames(_ name: String) {
        #expect(!ConfigStorage.isValidConfigName(name))
        #expect(!ConfigResource.nameValid(name))
    }
}
