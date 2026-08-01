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

/// Shared, side-effect-free validation for provider-declared option contracts.
/// Create validates create-phase values; start applies the same grammar to the
/// values deliberately frozen for start-phase validation.
enum ContainerLogOptionContractValidator {
    static func validate(
        _ value: String,
        for option: LogDriverOptionDescriptor,
        driver: String
    ) throws {
        if !option.allowedValues.isEmpty, !option.allowedValues.contains(value) {
            throw invalidOption(driver: driver, name: option.name, reason: "value is not allowed")
        }
        switch option.valueKind {
        case .string, .commaSeparatedNames, .tagTemplate:
            return
        case .boolean:
            guard parseBoolean(value) != nil else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a boolean")
            }
        case .positiveInteger:
            guard let value = Int(value), value > 0 else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a positive integer")
            }
        case .size:
            guard parseSize(value, allowingZero: option.name == "max-buffer-size") != nil else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a valid byte size")
            }
        case .regularExpression:
            do {
                _ = try Regex(value)
            } catch {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a regular expression")
            }
        }
    }

    static func validateCrossOptionConstraints(
        _ constraints: [LogDriverCrossOptionConstraint],
        options: [String: String],
        driver: String
    ) throws {
        for constraint in constraints where options[constraint.whenOptionPresent] != nil {
            guard
                let required = options[constraint.requiredOption],
                constraint.requiredAllowedValues.contains(required)
            else {
                throw invalidOption(
                    driver: driver,
                    name: constraint.whenOptionPresent,
                    reason:
                        "requires \(String(reflecting: constraint.requiredOption)) to use an allowed value"
                )
            }
        }
    }

    static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "1", "t", "T", "TRUE", "true", "True": true
        case "0", "f", "F", "FALSE", "false", "False": false
        default: nil
        }
    }

    static func parseSize(_ input: String, allowingZero: Bool) -> UInt64? {
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
            multiplier = 1024
        case "m", "mb", "mib":
            multiplier = 1024 * 1024
        case "g", "gb", "gib":
            multiplier = 1024 * 1024 * 1024
        case "t", "tb", "tib":
            multiplier = 1024 * 1024 * 1024 * 1024
        case "p", "pb", "pib":
            multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default:
            return nil
        }
        let bytes = number * multiplier
        // go-units returns int64. Keep the conversion below 2^63 because
        // Double(Int64.max) rounds up to that boundary.
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

    private static func invalidOption(
        driver: String,
        name: String,
        reason: String
    ) -> ContainerLogResolutionError {
        .invalidOption(driver: driver, name: name, reason: reason)
    }
}
