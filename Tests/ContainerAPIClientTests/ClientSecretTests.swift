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

@testable import ContainerAPIClient

struct ClientSecretTests {
    @Test(.enabled(if: !isCI))
    func `secrets preserve opaque data and hide list values`() throws {
        let name = "container-secret-test-\(UUID().uuidString.lowercased())"
        let contents = Data([0x00, 0xFF, 0x0A])
        defer { try? ClientSecret.delete(name: name) }

        do {
            let created = try ClientSecret.create(name: name, contents: contents)
            #expect(created.sizeInBytes == UInt64(contents.count))

            let listed = try ClientSecret.list()
            #expect(listed.contains(where: { $0.name == name && $0.sizeInBytes == nil }))

            let inspected = try ClientSecret.inspect(name)
            #expect(inspected.sizeInBytes == UInt64(contents.count))
            #expect(try ClientSecret.read(name: name) == contents)

            do {
                _ = try ClientSecret.create(name: name, contents: contents)
                Issue.record("creating an existing secret unexpectedly succeeded")
            } catch SecretError.secretAlreadyExists(let duplicate) {
                #expect(duplicate == name)
            } catch {
                Issue.record("creating an existing secret failed with an unexpected error: \(error)")
            }
        } catch SecretError.storageError(let message) where message.contains("-25308") {
            // Ignore errSecInteractionNotAllowed when the test process has no keychain UI access.
        }
    }

    private static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }
}
