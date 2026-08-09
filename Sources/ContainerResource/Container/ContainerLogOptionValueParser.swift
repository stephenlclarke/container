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

/// Side-effect-free scalar parsing shared by create/start validation and the
/// lower runtime's final defensive configuration fence.
package enum ContainerLogOptionValueParser {
    /// Matches Go's `strconv.ParseBool` accepted spellings.
    package static func boolean(_ value: String) -> Bool? {
        switch value {
        case "1", "t", "T", "TRUE", "true", "True": true
        case "0", "f", "F", "FALSE", "false", "False": false
        default: nil
        }
    }

    /// Matches Docker/go-units `FromHumanSize`, used by file-driver
    /// `max-size`. Its SI suffixes are decimal: `4k` is 4,000 bytes.
    package static func humanSizeInBytes(_ input: String, allowingZero: Bool) -> UInt64? {
        sizeInBytes(input, allowingZero: allowingZero, unitBase: 1_000)
    }

    /// Matches Docker/go-units `RAMInBytes`, used by `max-buffer-size` and
    /// cache ring sizing. Its suffixes are binary: `4k` is 4,096 bytes.
    package static func ramSizeInBytes(_ input: String, allowingZero: Bool) -> UInt64? {
        sizeInBytes(input, allowingZero: allowingZero, unitBase: 1_024)
    }

    private static func sizeInBytes(
        _ input: String,
        allowingZero: Bool,
        unitBase: Double
    ) -> UInt64? {
        guard
            let first = input.first,
            let last = input.last,
            !first.isWhitespace,
            !last.isWhitespace
        else {
            return nil
        }
        guard let separator = input.lastIndex(where: isDockerSizeSeparator) else {
            return nil
        }

        let numberText: Substring
        let suffixText: Substring
        if input[separator] == " " {
            numberText = input[..<separator]
            suffixText = input[input.index(after: separator)...]
        } else {
            numberText = input[...separator]
            suffixText = input[input.index(after: separator)...]
        }
        guard
            let number = parseGoFloat(String(numberText)),
            number.isFinite,
            allowingZero ? number >= 0 : number > 0
        else {
            return nil
        }

        let suffix = suffixText.lowercased()
        guard suffix.utf8.count <= 3 else {
            return nil
        }

        let multiplier: Double
        switch suffix {
        case "", "b":
            multiplier = 1
        case "k", "kb", "kib":
            multiplier = unitBase
        case "m", "mb", "mib":
            multiplier = unitBase * unitBase
        case "g", "gb", "gib":
            multiplier = unitBase * unitBase * unitBase
        case "t", "tb", "tib":
            multiplier = unitBase * unitBase * unitBase * unitBase
        case "p", "pb", "pib":
            multiplier = unitBase * unitBase * unitBase * unitBase * unitBase
        default:
            return nil
        }
        let bytes = number * multiplier
        // go-units returns int64. Double(Int64.max) rounds to 2^63, so use
        // that exclusive bound before conversion.
        guard bytes.isFinite, bytes < 9_223_372_036_854_775_808 else {
            return nil
        }
        let result = UInt64(Int64(bytes))
        guard allowingZero || result > 0 else {
            return nil
        }
        return result
    }

    private static func isDockerSizeSeparator(_ character: Character) -> Bool {
        character == "." || character == " " || character.wholeNumberValue != nil
    }

    private static func parseGoFloat(_ input: String) -> Double? {
        guard input.contains("_") else {
            return Double(input)
        }

        let characters = Array(input)
        guard characters.first != "_", characters.last != "_" else {
            return nil
        }
        let isHex = input.drop(while: { $0 == "+" || $0 == "-" }).lowercased().hasPrefix("0x")
        for index in characters.indices where characters[index] == "_" {
            guard index > characters.startIndex, index < characters.index(before: characters.endIndex) else {
                return nil
            }
            let previous = characters[characters.index(before: index)]
            let next = characters[characters.index(after: index)]
            let validPrevious =
                isASCIIDigit(previous)
                || (isHex && (isASCIIHexDigit(previous) || previous.lowercased() == "x"))
            let validNext = isASCIIDigit(next) || (isHex && isASCIIHexDigit(next))
            guard validPrevious, validNext else {
                return nil
            }
        }
        return Double(input.replacingOccurrences(of: "_", with: ""))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        isASCIIDigit(character)
            || (character.lowercased() >= "a" && character.lowercased() <= "f")
    }
}
