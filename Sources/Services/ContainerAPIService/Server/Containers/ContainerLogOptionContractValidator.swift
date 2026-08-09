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
        case .string, .commaSeparatedNames, .providerRegularExpression, .tagTemplate:
            return
        case .boolean:
            guard ContainerLogOptionValueParser.boolean(value) != nil else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a boolean")
            }
        case .positiveInteger:
            guard let value = Int(value), value > 0 else {
                throw invalidOption(driver: driver, name: option.name, reason: "expected a positive integer")
            }
        case .size:
            let parsed =
                if option.name == "max-size" {
                    ContainerLogOptionValueParser.humanSizeInBytes(
                        value,
                        allowingZero: false
                    )
                } else {
                    ContainerLogOptionValueParser.ramSizeInBytes(
                        value,
                        allowingZero: option.name == "max-buffer-size"
                    )
                }
            guard
                parsed != nil
            else {
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

    private static func invalidOption(
        driver: String,
        name: String,
        reason: String
    ) -> ContainerLogResolutionError {
        .invalidOption(driver: driver, name: name, reason: reason)
    }
}
