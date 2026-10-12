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
import MachineAPIClient
import Testing

struct UserSetupTests {
    @Test func namedUserPreservesSupplementaryGroups() {
        let setup = UserSetup(username: "machine-user", uid: 501, gid: 20)

        #expect(setup.user == .raw(userString: "machine-user"))
    }

    @Test func unnamedUserFallsBackToNumericIdentity() {
        let setup = UserSetup(username: "", uid: 501, gid: 20)

        #expect(setup.user == .id(uid: 501, gid: 20))
    }

    @Test func legacyBundleWithoutHomeKeepsItsDefaultHome() throws {
        let legacy = Data(#"{"username":"machine-user","uid":501,"gid":20}"#.utf8)
        let setup = try JSONDecoder().decode(UserSetup.self, from: legacy)

        #expect(setup.home == "/home/machine-user")
        #expect(setup.processEnvironment.contains("CONTAINER_HOME=/home/machine-user"))
    }

    @Test func customHomeSurvivesPersistenceAndProvisioningEnvironment() throws {
        let persisted = Data(#"{"username":"machine-user","uid":501,"gid":20,"home":"/srv/home with spaces"}"#.utf8)
        let setup = try JSONDecoder().decode(UserSetup.self, from: persisted)
        let reloaded = try JSONDecoder().decode(UserSetup.self, from: JSONEncoder().encode(setup))

        #expect(reloaded.home == "/srv/home with spaces")
        #expect(reloaded.processEnvironment.contains("CONTAINER_HOME=/srv/home with spaces"))
    }
}
