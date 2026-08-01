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

struct ContainerLogOptionValueParserTests {
    @Test
    func matchesGoBooleanSpellings() {
        for value in ["1", "t", "T", "TRUE", "true", "True"] {
            #expect(ContainerLogOptionValueParser.boolean(value) == true)
        }
        for value in ["0", "f", "F", "FALSE", "false", "False"] {
            #expect(ContainerLogOptionValueParser.boolean(value) == false)
        }
        for value in ["", "yes", " true", "true ", "TrUe"] {
            #expect(ContainerLogOptionValueParser.boolean(value) == nil)
        }
    }

    @Test
    func matchesDockerGoUnitsSizeGrammar() {
        let accepted: [(String, UInt64)] = [
            ("1", 1),
            ("+1", 1),
            ("01", 1),
            ("1.5k", 1_536),
            ("1KB", 1_024),
            ("1KiB", 1_024),
            ("1 k", 1_024),
            (".5m", 512 * 1_024),
            ("1e3", 1_000),
            ("1_0", 10),
            ("0x1p2", 4),
        ]
        for (value, expected) in accepted {
            #expect(
                ContainerLogOptionValueParser.sizeInBytes(value, allowingZero: false)
                    == expected
            )
        }

        for value in ["", "0", "-1", " 1", "1 ", "1k ", "\t1k", "nonsense", "1xb", "1__0"] {
            #expect(ContainerLogOptionValueParser.sizeInBytes(value, allowingZero: false) == nil)
        }
        #expect(ContainerLogOptionValueParser.sizeInBytes("0", allowingZero: true) == 0)
    }
}
