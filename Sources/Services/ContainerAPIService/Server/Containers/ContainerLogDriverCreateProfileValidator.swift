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

/// Exact side-effect-free create grammars selected by a versioned descriptor.
/// Errors mention option names and grammar only; raw values remain redacted.
enum ContainerLogDriverCreateProfileValidator {
    static func validate(
        _ profile: LogDriverCreateValidationProfile,
        options: [String: String],
        driver: String
    ) throws {
        switch profile {
        case .standard:
            return
        case .dockerFluentd29_2_1:
            try validateDockerFluentd(options: options, driver: driver)
        case .dockerGELF29_2_1:
            try validateDockerGELF(options: options, driver: driver)
        case .dockerSyslog29_2_1:
            try validateDockerSyslog(options: options, driver: driver)
        }
    }

    private static func validateDockerSyslog(
        options: [String: String],
        driver: String
    ) throws {
        if let facility = options["syslog-facility"], !facility.isEmpty,
            !dockerSyslogFacilityNames.contains(facility)
        {
            guard let numeric = dockerAtoi(facility), (0...23).contains(numeric) else {
                throw invalidOption(
                    driver: driver,
                    name: "syslog-facility",
                    reason: "expected a Docker syslog facility name or number from 0 through 23"
                )
            }
        }
        if let format = options["syslog-format"],
            !["", "rfc3164", "rfc5424", "rfc5424micro"].contains(format)
        {
            throw invalidOption(
                driver: driver,
                name: "syslog-format",
                reason: "value is not allowed"
            )
        }
    }

    private static let dockerSyslogFacilityNames: Set<String> = [
        "kern",
        "user",
        "mail",
        "daemon",
        "auth",
        "syslog",
        "lpr",
        "news",
        "uucp",
        "cron",
        "authpriv",
        "ftp",
        "local0",
        "local1",
        "local2",
        "local3",
        "local4",
        "local5",
        "local6",
        "local7",
    ]

    private static func validateDockerFluentd(
        options: [String: String],
        driver: String
    ) throws {
        if let address = options["fluentd-address"], !address.isEmpty {
            try validateDockerFluentdAddress(address, driver: driver)
        }
        if let value = options["fluentd-buffer-limit"], !value.isEmpty,
            ContainerLogOptionValueParser.ramSizeInBytes(
                value,
                allowingZero: true
            ) == nil
        {
            throw invalidOption(
                driver: driver,
                name: "fluentd-buffer-limit",
                reason: "expected a non-negative Docker RAM size"
            )
        }
        if let value = options["fluentd-max-retries"], !value.isEmpty {
            guard
                value.allSatisfy(isASCIIDigit),
                let parsed = UInt32(value),
                parsed <= UInt32(Int32.max)
            else {
                throw invalidOption(
                    driver: driver,
                    name: "fluentd-max-retries",
                    reason: "expected a Docker unsigned integer no greater than 2147483647"
                )
            }
        }
        for name in [
            "fluentd-async",
            "fluentd-request-ack",
            "fluentd-sub-second-precision",
        ] {
            guard let value = options[name], !value.isEmpty else {
                continue
            }
            guard ContainerLogOptionValueParser.boolean(value) != nil else {
                throw invalidOption(
                    driver: driver,
                    name: name,
                    reason: "expected a Docker boolean"
                )
            }
        }

        try validateDockerDuration(
            options["fluentd-retry-wait"],
            name: "fluentd-retry-wait",
            requiresNonNegative: false,
            driver: driver
        )
        for name in ["fluentd-read-timeout", "fluentd-write-timeout"] {
            try validateDockerDuration(
                options[name],
                name: name,
                requiresNonNegative: true,
                driver: driver
            )
        }
        if let value = options["fluentd-async-reconnect-interval"], !value.isEmpty {
            let nanoseconds = try dockerDuration(
                value,
                name: "fluentd-async-reconnect-interval",
                driver: driver
            )
            if nanoseconds != 0,
                !(100_000_000...10_000_000_000).contains(nanoseconds)
            {
                throw invalidOption(
                    driver: driver,
                    name: "fluentd-async-reconnect-interval",
                    reason: "expected zero or a duration from 100ms through 10s"
                )
            }
        }
    }

    private static func validateDockerDuration(
        _ value: String?,
        name: String,
        requiresNonNegative: Bool,
        driver: String
    ) throws {
        guard let value, !value.isEmpty else {
            return
        }
        let nanoseconds = try dockerDuration(value, name: name, driver: driver)
        if requiresNonNegative, nanoseconds < 0 {
            throw invalidOption(
                driver: driver,
                name: name,
                reason: "expected a non-negative Go duration"
            )
        }
    }

    private static func dockerDuration(
        _ value: String,
        name: String,
        driver: String
    ) throws -> Int64 {
        do {
            return try DockerGoDurationParser.nanoseconds(value)
        } catch {
            throw invalidOption(
                driver: driver,
                name: name,
                reason: "expected a Go duration"
            )
        }
    }

    private static func validateDockerFluentdAddress(
        _ value: String,
        driver: String
    ) throws {
        guard
            !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
            hasValidPercentEscapes(value)
        else {
            throw malformedFluentdAddress(driver: driver)
        }
        let address = value.contains("://") ? value : "tcp://\(value)"
        guard let separator = address.range(of: "://") else {
            throw malformedFluentdAddress(driver: driver)
        }
        let scheme = address[..<separator.lowerBound].lowercased()
        let remainder = address[separator.upperBound...]
        switch scheme {
        case "unix":
            let pathAndSuffix = remainder.drop(while: { $0 != "/" })
            let encodedPath = pathAndSuffix.prefix { $0 != "?" && $0 != "#" }
            guard
                !encodedPath.isEmpty,
                let path = String(encodedPath).removingPercentEncoding,
                !path.drop(while: { $0 == "/" }).isEmpty
            else {
                throw malformedFluentdAddress(driver: driver)
            }
        case "tcp", "tls":
            let authority = remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            let suffix = remainder.dropFirst(authority.count)
            guard suffix.first != "/" else {
                throw invalidOption(
                    driver: driver,
                    name: "fluentd-address",
                    reason: "must not contain a path"
                )
            }
            try validateDockerFluentdAuthority(authority, driver: driver)
        default:
            throw invalidOption(
                driver: driver,
                name: "fluentd-address",
                reason: "endpoint scheme must be TCP, TLS, or Unix"
            )
        }
    }

    private static func validateDockerFluentdAuthority(
        _ authority: Substring,
        driver: String
    ) throws {
        guard !authority.contains(where: { $0.isWhitespace }) else {
            throw malformedFluentdAddress(driver: driver)
        }
        let hostAndPort =
            authority.split(
                separator: "@",
                omittingEmptySubsequences: false
            ).last ?? ""
        let port: Substring?
        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.lastIndex(of: "]") else {
                throw malformedFluentdAddress(driver: driver)
            }
            let trailing = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard trailing.isEmpty || trailing.first == ":" else {
                throw malformedFluentdAddress(driver: driver)
            }
            port = trailing.isEmpty ? nil : trailing.dropFirst()
        } else if let colon = hostAndPort.lastIndex(of: ":") {
            guard hostAndPort[..<colon].allSatisfy({ $0 != ":" }) else {
                throw malformedFluentdAddress(driver: driver)
            }
            port = hostAndPort[hostAndPort.index(after: colon)...]
        } else {
            port = nil
        }
        if let port, !port.isEmpty {
            guard
                port.allSatisfy(isASCIIDigit),
                UInt16(port) != nil
            else {
                throw invalidOption(
                    driver: driver,
                    name: "fluentd-address",
                    reason: "expected a decimal port from 0 through 65535"
                )
            }
        }
    }

    private static func malformedFluentdAddress(
        driver: String
    ) -> ContainerLogResolutionError {
        invalidOption(
            driver: driver,
            name: "fluentd-address",
            reason: "expected a Docker Fluentd endpoint"
        )
    }

    private enum GELFScheme {
        case udp
        case tcp
    }

    private static func validateDockerGELF(
        options: [String: String],
        driver: String
    ) throws {
        guard let address = options["gelf-address"], !address.isEmpty else {
            throw invalidOption(
                driver: driver,
                name: "gelf-address",
                reason: "is required"
            )
        }
        let scheme = try dockerGELFScheme(address, driver: driver)

        if let value = options["gelf-compression-level"] {
            guard scheme == .udp else {
                throw invalidOption(
                    driver: driver,
                    name: "gelf-compression-level",
                    reason: "compression is only supported on UDP"
                )
            }
            guard let parsed = dockerAtoi(value), (-1...9).contains(parsed) else {
                throw invalidOption(
                    driver: driver,
                    name: "gelf-compression-level",
                    reason: "expected a Docker compression level from -1 through 9"
                )
            }
        }

        if let value = options["gelf-compression-type"] {
            guard scheme == .udp else {
                throw invalidOption(
                    driver: driver,
                    name: "gelf-compression-type",
                    reason: "compression is only supported on UDP"
                )
            }
            guard ["gzip", "zlib", "none"].contains(value) else {
                throw invalidOption(
                    driver: driver,
                    name: "gelf-compression-type",
                    reason: "value is not allowed"
                )
            }
        }

        for name in ["gelf-tcp-max-reconnect", "gelf-tcp-reconnect-delay"] {
            guard let value = options[name] else {
                continue
            }
            guard scheme == .tcp else {
                throw invalidOption(
                    driver: driver,
                    name: name,
                    reason: "is only valid for TCP"
                )
            }
            guard let parsed = dockerAtoi(value), parsed >= 0 else {
                throw invalidOption(
                    driver: driver,
                    name: name,
                    reason: "expected a non-negative Docker integer"
                )
            }
        }
    }

    private static func dockerGELFScheme(
        _ address: String,
        driver: String
    ) throws -> GELFScheme {
        guard
            !address.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
            hasValidPercentEscapes(address),
            let separator = address.range(of: "://")
        else {
            throw malformedAddress(driver: driver)
        }

        let rawScheme = address[..<separator.lowerBound]
        guard isValidURLScheme(rawScheme) else {
            throw malformedAddress(driver: driver)
        }
        let scheme: GELFScheme
        switch rawScheme.lowercased() {
        case "udp": scheme = .udp
        case "tcp": scheme = .tcp
        default:
            throw invalidOption(
                driver: driver,
                name: "gelf-address",
                reason: "endpoint scheme must be TCP or UDP"
            )
        }

        let remainder = address[separator.upperBound...]
        let authority = remainder.prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        guard
            !authority.isEmpty,
            !authority.contains(where: { $0.isWhitespace })
        else {
            throw malformedAddress(driver: driver)
        }
        let hostAndPort =
            authority.split(
                separator: "@",
                omittingEmptySubsequences: false
            ).last ?? ""
        let rawPort: Substring
        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else {
                throw malformedAddress(driver: driver)
            }
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard suffix.first == ":" else {
                throw malformedAddress(driver: driver)
            }
            rawPort = suffix.dropFirst()
        } else {
            guard
                let colon = hostAndPort.lastIndex(of: ":"),
                hostAndPort[..<colon].allSatisfy({ $0 != ":" })
            else {
                throw malformedAddress(driver: driver)
            }
            rawPort = hostAndPort[hostAndPort.index(after: colon)...]
        }
        guard rawPort.allSatisfy(isASCIIDigit) else {
            throw malformedAddress(driver: driver)
        }
        return scheme
    }

    private static func dockerAtoi(_ value: String) -> Int? {
        guard !value.isEmpty else {
            return nil
        }
        let digits: Substring
        if value.first == "+" || value.first == "-" {
            digits = value.dropFirst()
        } else {
            digits = value[...]
        }
        guard !digits.isEmpty, digits.allSatisfy(isASCIIDigit) else {
            return nil
        }
        return Int(value)
    }

    private static func isValidURLScheme(_ value: Substring) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { character in
            character.isASCII
                && (character.isLetter
                    || isASCIIDigit(character)
                    || character == "+"
                    || character == "-"
                    || character == ".")
        }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let characters = Array(value)
        for index in characters.indices where characters[index] == "%" {
            guard
                index + 2 < characters.count,
                isASCIIHexDigit(characters[index + 1]),
                isASCIIHexDigit(characters[index + 2])
            else {
                return false
            }
        }
        return true
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        isASCIIDigit(character)
            || (character >= "A" && character <= "F")
            || (character >= "a" && character <= "f")
    }

    private static func malformedAddress(driver: String) -> ContainerLogResolutionError {
        invalidOption(
            driver: driver,
            name: "gelf-address",
            reason: "expected proto://host:port with a decimal port"
        )
    }

    private static func invalidOption(
        driver: String,
        name: String,
        reason: String
    ) -> ContainerLogResolutionError {
        .invalidOption(driver: driver, name: name, reason: reason)
    }
}
