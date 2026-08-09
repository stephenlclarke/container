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

package enum DockerGoDurationParseError: Error, Equatable, Sendable {
    case invalidSyntax
    case valueOutOfRange
}

/// A side-effect-free parser for Go `time.ParseDuration`'s documented
/// grammar and signed 64-bit nanosecond result.
package enum DockerGoDurationParser {
    private static let magnitudeLimit = UInt64(1) << 63

    package static func nanoseconds(_ value: String) throws -> Int64 {
        guard !value.isEmpty else {
            throw DockerGoDurationParseError.invalidSyntax
        }
        var remainder = value[...]
        var negative = false
        if remainder.first == "+" || remainder.first == "-" {
            negative = remainder.first == "-"
            remainder.removeFirst()
        }
        guard !remainder.isEmpty else {
            throw DockerGoDurationParseError.invalidSyntax
        }
        if remainder == "0" {
            return 0
        }

        var total: UInt64 = 0
        while !remainder.isEmpty {
            let integerStart = remainder.startIndex
            var integer = try leadingInteger(in: &remainder)
            let hasInteger = remainder.startIndex != integerStart

            var fraction: UInt64 = 0
            var fractionScale = 1.0
            var hasFraction = false
            if remainder.first == "." {
                remainder.removeFirst()
                let fractionStart = remainder.startIndex
                (fraction, fractionScale) = leadingFraction(in: &remainder)
                hasFraction = remainder.startIndex != fractionStart
            }
            guard hasInteger || hasFraction else {
                throw DockerGoDurationParseError.invalidSyntax
            }

            var unit = ""
            while let character = remainder.first {
                if character == "." || asciiDigit(character) != nil {
                    break
                }
                unit.append(character)
                remainder.removeFirst()
            }
            let multiplier: UInt64
            switch unit {
            case "ns": multiplier = 1
            case "us", "µs", "μs": multiplier = 1_000
            case "ms": multiplier = 1_000_000
            case "s": multiplier = 1_000_000_000
            case "m": multiplier = 60 * 1_000_000_000
            case "h": multiplier = 3_600 * 1_000_000_000
            default: throw DockerGoDurationParseError.invalidSyntax
            }

            guard integer <= magnitudeLimit / multiplier else {
                throw DockerGoDurationParseError.valueOutOfRange
            }
            integer *= multiplier
            if fraction > 0 {
                let fractionalNanoseconds = UInt64(
                    Double(fraction) * (Double(multiplier) / fractionScale)
                )
                let (component, overflow) = integer.addingReportingOverflow(
                    fractionalNanoseconds
                )
                guard !overflow, component <= magnitudeLimit else {
                    throw DockerGoDurationParseError.valueOutOfRange
                }
                integer = component
            }
            let (next, overflow) = total.addingReportingOverflow(integer)
            guard !overflow, next <= magnitudeLimit else {
                throw DockerGoDurationParseError.valueOutOfRange
            }
            total = next
        }

        if negative {
            return total == magnitudeLimit ? Int64.min : -Int64(total)
        }
        guard total <= UInt64(Int64.max) else {
            throw DockerGoDurationParseError.valueOutOfRange
        }
        return Int64(total)
    }

    private static func leadingInteger(
        in remainder: inout Substring
    ) throws -> UInt64 {
        var value: UInt64 = 0
        while let character = remainder.first,
            let digit = asciiDigit(character)
        {
            guard value <= magnitudeLimit / 10 else {
                throw DockerGoDurationParseError.valueOutOfRange
            }
            let next = value * 10 + digit
            guard next <= magnitudeLimit else {
                throw DockerGoDurationParseError.valueOutOfRange
            }
            value = next
            remainder.removeFirst()
        }
        return value
    }

    private static func leadingFraction(
        in remainder: inout Substring
    ) -> (value: UInt64, scale: Double) {
        var value: UInt64 = 0
        var scale = 1.0
        var overflow = false
        while let character = remainder.first,
            let digit = asciiDigit(character)
        {
            remainder.removeFirst()
            if overflow {
                continue
            }
            guard value <= (magnitudeLimit - 1) / 10 else {
                overflow = true
                continue
            }
            let next = value * 10 + digit
            guard next <= magnitudeLimit else {
                overflow = true
                continue
            }
            value = next
            scale *= 10
        }
        return (value, scale)
    }

    private static func asciiDigit(_ character: Character) -> UInt64? {
        guard
            character >= "0",
            character <= "9",
            let scalar = character.unicodeScalars.first,
            scalar.isASCII
        else {
            return nil
        }
        return UInt64(scalar.value - 48)
    }
}
