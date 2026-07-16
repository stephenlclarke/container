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

@testable import ContainerRuntimeLinuxServer

struct RuntimeAttachIOTests {
    @Test
    func outputForwardsToInitialAndReattachedClients() throws {
        let initial = Pipe()
        let reattached = Pipe()
        let output = AttachableOutput(initial: initial.fileHandleForWriting)
        output.add(reattached.fileHandleForWriting)

        try output.write(Data("attached output\n".utf8))
        try output.close()

        #expect(try initial.fileHandleForReading.readToEnd() == Data("attached output\n".utf8))
        #expect(try reattached.fileHandleForReading.readToEnd() == Data("attached output\n".utf8))
    }

    @Test
    func inputRemainsOpenWhenOneClientEnds() async throws {
        let first = Pipe()
        let second = Pipe()
        let input = AttachableInput(initial: first.fileHandleForReading)
        input.add(second.fileHandleForReading)
        var iterator = input.stream().makeAsyncIterator()

        try first.fileHandleForWriting.close()
        try second.fileHandleForWriting.write(contentsOf: Data("next session\n".utf8))

        let received = await iterator.next()
        #expect(received == Data("next session\n".utf8))

        input.close()
        let finished = await iterator.next()
        #expect(finished == nil)
    }
}
