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

@testable import ContainerAPIClient

struct DetachKeySequenceTests {
    @Test
    func parsesDockerDefaultSequence() throws {
        #expect(try DetachKeySequence("ctrl-p,ctrl-q").bytes == [16, 17])
    }

    @Test
    func parsesLiteralAndControlTokens() throws {
        #expect(try DetachKeySequence("ctrl-@,ctrl-[,ctrl-\\,ctrl-],ctrl-_,ctrl-^,~,DEL").bytes == [0, 27, 28, 29, 31, 30, 126, 127])
    }

    @Test
    func rejectsUnsupportedSequences() {
        for value in ["", "ctrl-p,", "ctrl-P", "ctrl-,", "xx"] {
            #expect(throws: (any Error).self) {
                _ = try DetachKeySequence(value)
            }
        }
    }

    @Test
    func matcherWithholdsSequencePrefixUntilItCanDecide() {
        let matcher = DetachKeyMatcher(sequence: .standard)
        let first = [UInt8(16)]
        let second = [UInt8(120)]

        #expect(matcher.filter(first).forwarded.isEmpty)
        #expect(matcher.filter(second) == .init(forwarded: [16, 120], detached: false))
    }

    @Test
    func matcherReportsDetachWithoutForwardingSequence() {
        let matcher = DetachKeyMatcher(sequence: .standard)
        let input = [UInt8(16), UInt8(17)]

        #expect(matcher.filter(input) == .init(forwarded: [], detached: true))
        #expect(matcher.isDetached)
        #expect(matcher.filter([120]) == .init(forwarded: [], detached: true))
    }
}
