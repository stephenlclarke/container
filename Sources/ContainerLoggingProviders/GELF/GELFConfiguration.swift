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

public enum GELFProviderError: Error, Equatable, Sendable {
    case unknownOption(String)
    case missingAddress
    case unsupportedAddressScheme(String)
    case malformedAddress(String)
    case optionRequiresUDP(String)
    case optionRequiresTCP(String)
    case invalidCompressionType(String)
    case invalidCompressionLevel(String)
    case invalidNonNegativeInteger(option: String, value: String)
    case invalidTagTemplate(String)
    case tagExceedsUTF8Limit(maximumBytes: Int)
    case invalidMetadataRegularExpression(option: String, value: String)
    case tooManyMetadataFields(maximum: Int)
    case metadataExceedsUTF8Limit(maximumBytes: Int)
    case invalidConnectionPolicy
    case recordPayloadTooLarge(maximumBytes: Int)
    case encodedMessageTooLarge(maximumBytes: Int)
    case compressionFailed
    case chunkIdentifierInvalid
    case tooManyChunks(maximum: Int, actual: Int)
    case connectionTimedOut
    case writeTimedOut
    case closeTimedOut
    case flushTimedOut
    case transportClosed
    case partialWrite(expected: Int, actual: Int)
    case reconnectAttemptsExhausted(attempts: Int)
    case timestampOutOfRange
    case invalidProviderIdentity
    case idempotencyConflict
    case invalidEffectToken
    case invalidSessionFence
    case invalidProviderStateAuthentication
    case providerStateBoundsExceeded
    case readUnsupported
}

public struct GELFNetworkAddress: Equatable, Sendable {
    public let host: String
    public let port: String

    public init(host: String, port: String) {
        self.host = host
        self.port = port
    }
}

public enum GELFEndpoint: Equatable, Sendable {
    case udp(GELFNetworkAddress)
    case tcp(GELFNetworkAddress)

    public var usesUDP: Bool {
        if case .udp = self {
            return true
        }
        return false
    }

    public var usesTCP: Bool { !usesUDP }

    public static func parse(_ requestedAddress: String) throws -> Self {
        guard !requestedAddress.isEmpty else {
            throw GELFProviderError.missingAddress
        }
        guard let separator = requestedAddress.range(of: "://") else {
            throw GELFProviderError.malformedAddress(requestedAddress)
        }

        // net/url.Parse lowercases schemes before Moby checks them.
        let scheme = requestedAddress[..<separator.lowerBound].lowercased()
        guard scheme == "udp" || scheme == "tcp" else {
            throw GELFProviderError.unsupportedAddressScheme(scheme)
        }
        let remainder = requestedAddress[separator.upperBound...]
        let authority = remainder.prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        let hostAndPort =
            authority.split(
                separator: "@",
                omittingEmptySubsequences: false
            ).last ?? ""
        let host: Substring
        let port: Substring
        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else {
                throw GELFProviderError.malformedAddress(requestedAddress)
            }
            host =
                hostAndPort[
                    hostAndPort.index(after: hostAndPort.startIndex)..<closingBracket
                ]
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            guard suffix.first == ":" else {
                throw GELFProviderError.malformedAddress(requestedAddress)
            }
            port = suffix.dropFirst()
        } else {
            guard
                let colon = hostAndPort.lastIndex(of: ":"),
                hostAndPort[..<colon].allSatisfy({ $0 != ":" })
            else {
                throw GELFProviderError.malformedAddress(requestedAddress)
            }
            host = hostAndPort[..<colon]
            port = hostAndPort[hostAndPort.index(after: colon)...]
        }
        guard
            port.allSatisfy({ $0 >= "0" && $0 <= "9" }),
            let decodedHost = String(host).removingPercentEncoding
        else {
            throw GELFProviderError.malformedAddress(requestedAddress)
        }
        let network = GELFNetworkAddress(host: decodedHost, port: String(port))
        return scheme == "udp" ? .udp(network) : .tcp(network)
    }
}

public enum GELFCompressionType: String, CaseIterable, Equatable, Sendable {
    case gzip
    case zlib
    case none
}

public struct GELFConnectionPolicy: Equatable, Sendable {
    public static let dockerCompatible: Self = {
        do {
            return try Self(
                connectTimeout: .seconds(30),
                writeTimeout: .seconds(30),
                closeTimeout: .seconds(5)
            )
        } catch {
            preconditionFailure("invalid built-in GELF connection policy: \(error)")
        }
    }()

    public let connectTimeout: Duration
    public let writeTimeout: Duration
    public let closeTimeout: Duration

    public init(
        connectTimeout: Duration,
        writeTimeout: Duration,
        closeTimeout: Duration
    ) throws {
        guard connectTimeout > .zero, writeTimeout > .zero, closeTimeout > .zero else {
            throw GELFProviderError.invalidConnectionPolicy
        }
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
        self.closeTimeout = closeTimeout
    }
}

public typealias GELFContainerInfo = SyslogContainerInfo

public struct GELFDriverConfiguration: Equatable, Sendable {
    public static let defaultCompressionLevel = 1
    public static let defaultMaximumReconnects = 3
    public static let defaultReconnectDelay: Duration = .seconds(1)
    public static let maximumTagUTF8Bytes = ContainerLogRequest.maximumEncodedTransportBytes
    public static let maximumMetadataFields = 128
    public static let maximumMetadataUTF8Bytes = 64 * 1024

    public let endpoint: GELFEndpoint
    public let compressionType: GELFCompressionType
    public let compressionLevel: Int32
    public let maximumReconnects: Int
    public let reconnectDelay: Duration
    public let tag: String
    public let hostname: String
    public let containerID: String
    public let containerName: String
    public let imageID: String
    public let imageName: String
    public let command: String
    public let created: Date
    public let metadata: [String: String]
    public let policy: GELFConnectionPolicy

    public init(
        endpoint: GELFEndpoint,
        compressionType: GELFCompressionType,
        compressionLevel: Int32,
        maximumReconnects: Int,
        reconnectDelay: Duration,
        tag: String,
        hostname: String,
        containerID: String,
        containerName: String,
        imageID: String,
        imageName: String,
        command: String,
        created: Date,
        metadata: [String: String],
        policy: GELFConnectionPolicy
    ) throws {
        guard (-1...9).contains(compressionLevel), maximumReconnects >= 0, reconnectDelay >= .zero else {
            throw GELFProviderError.invalidConnectionPolicy
        }
        guard tag.utf8.count <= Self.maximumTagUTF8Bytes else {
            throw GELFProviderError.tagExceedsUTF8Limit(
                maximumBytes: Self.maximumTagUTF8Bytes
            )
        }
        try Self.validateMetadata(metadata)
        self.endpoint = endpoint
        self.compressionType = compressionType
        self.compressionLevel = compressionLevel
        self.maximumReconnects = maximumReconnects
        self.reconnectDelay = reconnectDelay
        self.tag = tag
        self.hostname = hostname
        self.containerID = containerID
        self.containerName = containerName
        self.imageID = imageID
        self.imageName = imageName
        self.command = command
        self.created = created
        self.metadata = metadata
        self.policy = policy
    }

    public static func resolve(
        options: [String: String],
        info: GELFContainerInfo,
        policy: GELFConnectionPolicy = .dockerCompatible
    ) throws -> Self {
        if let unknown = options.keys.sorted().first(where: { !knownOptionNames.contains($0) }) {
            throw GELFProviderError.unknownOption(unknown)
        }

        let endpoint = try GELFEndpoint.parse(options["gelf-address"] ?? "")
        let compressionType = try compressionType(
            options["gelf-compression-type"],
            endpoint: endpoint
        )
        let compressionLevel = try compressionLevel(
            options["gelf-compression-level"],
            endpoint: endpoint
        )
        let maximumReconnects = try tcpInteger(
            options["gelf-tcp-max-reconnect"],
            option: "gelf-tcp-max-reconnect",
            defaultValue: defaultMaximumReconnects,
            endpoint: endpoint
        )
        let reconnectDelaySeconds = try tcpInteger(
            options["gelf-tcp-reconnect-delay"],
            option: "gelf-tcp-reconnect-delay",
            defaultValue: 1,
            endpoint: endpoint
        )
        let requestedTag = options["tag"] ?? ""
        let tag: String
        do {
            tag = try SyslogTagTemplate.render(
                requestedTag.isEmpty ? "{{.ID}}" : requestedTag,
                info: info,
                configuration: options
            )
        } catch SyslogProviderError.tagExceedsUTF8Limit(let maximumBytes) {
            throw GELFProviderError.tagExceedsUTF8Limit(maximumBytes: maximumBytes)
        } catch {
            throw GELFProviderError.invalidTagTemplate(requestedTag)
        }
        let metadata = try GELFMetadata.resolve(options: options, info: info)

        return try Self(
            endpoint: endpoint,
            compressionType: compressionType,
            compressionLevel: compressionLevel,
            maximumReconnects: maximumReconnects,
            reconnectDelay: .seconds(reconnectDelaySeconds),
            tag: tag,
            hostname: info.hostname,
            containerID: info.containerID,
            containerName: info.name,
            imageID: info.containerImageID,
            imageName: info.containerImageName,
            command: info.command,
            created: info.containerCreated,
            metadata: metadata,
            policy: policy
        )
    }

    public static let knownOptionNames: Set<String> = [
        "cache-compress",
        "cache-disabled",
        "cache-max-file",
        "cache-max-size",
        "env",
        "env-regex",
        "gelf-address",
        "gelf-compression-level",
        "gelf-compression-type",
        "gelf-tcp-max-reconnect",
        "gelf-tcp-reconnect-delay",
        "labels",
        "labels-regex",
        "max-buffer-size",
        "mode",
        "tag",
    ]

    private static func compressionType(
        _ value: String?,
        endpoint: GELFEndpoint
    ) throws -> GELFCompressionType {
        guard let value else {
            return .gzip
        }
        guard endpoint.usesUDP else {
            throw GELFProviderError.optionRequiresUDP("gelf-compression-type")
        }
        guard let parsed = GELFCompressionType(rawValue: value) else {
            throw GELFProviderError.invalidCompressionType(value)
        }
        return parsed
    }

    private static func compressionLevel(
        _ value: String?,
        endpoint: GELFEndpoint
    ) throws -> Int32 {
        guard let value else {
            return Int32(defaultCompressionLevel)
        }
        guard endpoint.usesUDP else {
            throw GELFProviderError.optionRequiresUDP("gelf-compression-level")
        }
        guard let parsed = parseAtoi(value), (-1...9).contains(parsed) else {
            throw GELFProviderError.invalidCompressionLevel(value)
        }
        return Int32(parsed)
    }

    private static func tcpInteger(
        _ value: String?,
        option: String,
        defaultValue: Int,
        endpoint: GELFEndpoint
    ) throws -> Int {
        guard let value else {
            return defaultValue
        }
        guard endpoint.usesTCP else {
            throw GELFProviderError.optionRequiresTCP(option)
        }
        guard let parsed = parseAtoi(value), parsed >= 0 else {
            throw GELFProviderError.invalidNonNegativeInteger(
                option: option,
                value: value
            )
        }
        return parsed
    }

    private static func parseAtoi(_ value: String) -> Int? {
        guard !value.isEmpty else {
            return nil
        }
        let digits: Substring
        if value.first == "+" || value.first == "-" {
            digits = value.dropFirst()
        } else {
            digits = value[...]
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int(value)
    }

    private static func validateMetadata(_ metadata: [String: String]) throws {
        guard metadata.count <= maximumMetadataFields else {
            throw GELFProviderError.tooManyMetadataFields(maximum: maximumMetadataFields)
        }
        var total = 0
        for (key, value) in metadata {
            let (entry, entryOverflow) = key.utf8.count.addingReportingOverflow(value.utf8.count)
            let (next, totalOverflow) = total.addingReportingOverflow(entry)
            guard !entryOverflow, !totalOverflow, next <= maximumMetadataUTF8Bytes else {
                throw GELFProviderError.metadataExceedsUTF8Limit(
                    maximumBytes: maximumMetadataUTF8Bytes
                )
            }
            total = next
        }
    }
}

private enum GELFMetadata {
    static func resolve(
        options: [String: String],
        info: GELFContainerInfo
    ) throws -> [String: String] {
        var result = [String: String]()
        addNamed(options["labels"] ?? "", values: info.containerLabels, to: &result)
        try addMatching(
            options["labels-regex"] ?? "",
            option: "labels-regex",
            values: info.containerLabels,
            to: &result
        )

        var environment = [String: String]()
        for entry in info.containerEnvironment {
            guard let equals = entry.firstIndex(of: "=") else {
                continue
            }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        addNamed(options["env"] ?? "", values: environment, to: &result)
        try addMatching(
            options["env-regex"] ?? "",
            option: "env-regex",
            values: environment,
            to: &result
        )
        return result
    }

    private static func addNamed(
        _ names: String,
        values: [String: String],
        to result: inout [String: String]
    ) {
        guard !names.isEmpty else {
            return
        }
        for name in names.split(separator: ",", omittingEmptySubsequences: false) {
            let key = String(name)
            if let value = values[key] {
                result[prefixed(key)] = value
            }
        }
    }

    private static func addMatching(
        _ pattern: String,
        option: String,
        values: [String: String],
        to result: inout [String: String]
    ) throws {
        guard !pattern.isEmpty else {
            return
        }
        let expression = try GELFRE2Expression(pattern: pattern, option: option)
        for (key, value) in values where expression.matches(key) {
            result[prefixed(key)] = value
        }
    }

    private static func prefixed(_ key: String) -> String {
        key.hasPrefix("_") ? key : "_" + key
    }
}

private struct GELFRE2Expression {
    private let expression: NSRegularExpression

    init(pattern: String, option: String) throws {
        do {
            expression = try NSRegularExpression(
                pattern: GELFRE2Compatibility.translate(
                    pattern,
                    option: option
                )
            )
        } catch let error as GELFProviderError {
            throw error
        } catch {
            throw GELFProviderError.invalidMetadataRegularExpression(
                option: option,
                value: pattern
            )
        }
    }

    func matches(_ value: String) -> Bool {
        expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        ) != nil
    }
}

private enum GELFRE2Compatibility {
    private struct Repetition {
        let minimum: Int
        let maximum: Int?
        let end: Int
    }

    /// ICU is the available host engine. Normalize Go's ASCII-only classes
    /// and reject constructs with known non-RE2 behavior before compiling.
    static func translate(_ pattern: String, option: String) throws -> String {
        let characters = Array(pattern)
        var translated = ""
        var index = 0
        var inCharacterClass = false

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                guard index + 1 < characters.count else {
                    throw invalid(pattern, option: option)
                }
                let escaped = characters[index + 1]
                if escaped == "Q", !inCharacterClass {
                    let quoted = quotedLiteral(in: characters, at: index)
                    translated += NSRegularExpression.escapedPattern(
                        for: quoted.literal
                    )
                    index = quoted.end
                    continue
                } else if escaped == "b" || escaped == "B", !inCharacterClass {
                    translated += asciiWordBoundary(negated: escaped == "B")
                } else if let octal = octalEscape(in: characters, at: index) {
                    translated += octal.replacement
                    index = octal.end
                    continue
                } else if let replacement = asciiClass(for: escaped) {
                    translated += replacement
                } else {
                    guard isSupportedEscape(escaped, inCharacterClass: inCharacterClass)
                    else {
                        throw invalid(pattern, option: option)
                    }
                    translated.append(character)
                    translated.append(escaped)
                }
                index += 2
                continue
            }

            if inCharacterClass,
                character == "[",
                index + 1 < characters.count,
                characters[index + 1] == ":"
            {
                guard let posix = posixClass(in: characters, at: index) else {
                    throw invalid(pattern, option: option)
                }
                translated += posix.replacement
                index = posix.end
                continue
            }

            if character == "[", !inCharacterClass {
                inCharacterClass = true
            } else if character == "]", inCharacterClass {
                inCharacterClass = false
            } else if !inCharacterClass, character == "(" {
                if let group = try translatedGroup(
                    in: characters,
                    at: index,
                    pattern: pattern,
                    option: option
                ) {
                    translated += group.replacement
                    index = group.end
                    continue
                }
            } else if !inCharacterClass,
                character == "*" || character == "+" || character == "?",
                index + 1 < characters.count,
                characters[index + 1] == "+"
            {
                throw invalid(pattern, option: option)
            } else if !inCharacterClass,
                character == "{",
                let repetition = repetition(in: characters, at: index)
            {
                guard
                    repetition.minimum <= 1_000,
                    repetition.maximum.map({ $0 <= 1_000 }) ?? true,
                    repetition.end >= characters.count
                        || characters[repetition.end] != "+"
                else {
                    throw invalid(pattern, option: option)
                }
            }

            translated.append(character)
            index += 1
        }
        guard !inCharacterClass else {
            throw invalid(pattern, option: option)
        }
        return translated
    }

    private static func asciiClass(for escaped: Character) -> String? {
        switch escaped {
        case "d": return "[0-9]"
        case "D": return "[^0-9]"
        case "s": return "[\\t\\n\\f\\r ]"
        case "S": return "[^\\t\\n\\f\\r ]"
        case "w": return "[0-9A-Za-z_]"
        case "W": return "[^0-9A-Za-z_]"
        default: return nil
        }
    }

    private static func asciiWordBoundary(negated: Bool) -> String {
        if negated {
            return "(?:(?<=[0-9A-Za-z_])(?=[0-9A-Za-z_])|(?<![0-9A-Za-z_])(?![0-9A-Za-z_]))"
        }
        return "(?:(?<![0-9A-Za-z_])(?=[0-9A-Za-z_])|(?<=[0-9A-Za-z_])(?![0-9A-Za-z_]))"
    }

    private static func quotedLiteral(
        in characters: [Character],
        at start: Int
    ) -> (literal: String, end: Int) {
        var end = start + 2
        while end + 1 < characters.count {
            if characters[end] == "\\", characters[end + 1] == "E" {
                return (String(characters[(start + 2)..<end]), end + 2)
            }
            end += 1
        }
        return (String(characters[(start + 2)...]), characters.count)
    }

    private static func octalEscape(
        in characters: [Character],
        at start: Int
    ) -> (replacement: String, end: Int)? {
        guard
            start + 1 < characters.count,
            let first = asciiDigit(characters[start + 1]),
            first < 8
        else {
            return nil
        }
        if first != 0 {
            guard
                start + 2 < characters.count,
                let second = asciiDigit(characters[start + 2]),
                second < 8
            else {
                return nil
            }
        }

        var value = first
        var end = start + 2
        while end < characters.count, end < start + 4,
            let digit = asciiDigit(characters[end]), digit < 8
        {
            value = value * 8 + digit
            end += 1
        }
        return (String(format: "\\x{%llX}", value), end)
    }

    private static func isSupportedEscape(
        _ escaped: Character,
        inCharacterClass: Bool
    ) -> Bool {
        if asciiDigit(escaped) != nil {
            // Non-octal decimal escapes are unsupported backreferences in RE2.
            return false
        }
        if escaped == "b" || escaped == "B" {
            // Go word boundaries are ASCII-only; ICU boundaries are Unicode.
            return false
        }
        if escaped.isLetter {
            return ["a", "f", "n", "r", "t", "v", "p", "P", "x", "A", "z"]
                .contains(escaped)
                && !(inCharacterClass && (escaped == "A" || escaped == "z"))
        }
        return true
    }

    private static func posixClass(
        in characters: [Character],
        at start: Int
    ) -> (replacement: String, end: Int)? {
        guard
            start + 3 < characters.count,
            characters[start] == "[",
            characters[start + 1] == ":"
        else {
            return nil
        }
        var index = start + 2
        var negated = false
        if characters[index] == "^" {
            negated = true
            index += 1
        }
        let nameStart = index
        while index < characters.count, characters[index].isLetter {
            index += 1
        }
        guard
            index > nameStart,
            index + 1 < characters.count,
            characters[index] == ":",
            characters[index + 1] == "]"
        else {
            return nil
        }
        let name = String(characters[nameStart..<index])
        let body: String
        switch name {
        case "alnum": body = "0-9A-Za-z"
        case "alpha": body = "A-Za-z"
        case "ascii": body = "\\x00-\\x7F"
        case "blank": body = "\\t "
        case "cntrl": body = "\\x00-\\x1F\\x7F"
        case "digit": body = "0-9"
        case "graph": body = "\\x21-\\x7E"
        case "lower": body = "a-z"
        case "print": body = "\\x20-\\x7E"
        case "punct": body = "\\x21-\\x2F\\x3A-\\x40\\x5B-\\x60\\x7B-\\x7E"
        case "space": body = "\\t\\n\\v\\f\\r "
        case "upper": body = "A-Z"
        case "word": body = "0-9A-Za-z_"
        case "xdigit": body = "0-9A-Fa-f"
        default: return nil
        }
        return (negated ? "[^\(body)]" : body, index + 2)
    }

    private static func translatedGroup(
        in characters: [Character],
        at start: Int,
        pattern: String,
        option: String
    ) throws -> (replacement: String, end: Int)? {
        guard
            start + 1 < characters.count,
            characters[start + 1] == "?"
        else {
            return nil
        }
        guard start + 2 < characters.count else {
            throw invalid(pattern, option: option)
        }
        let kind = characters[start + 2]
        if kind == ":" {
            return ("(?:", start + 3)
        }
        if kind == "=" || kind == "!" || kind == ">" || kind == "#" || kind == "(" {
            throw invalid(pattern, option: option)
        }
        if kind == "<" {
            guard
                start + 3 < characters.count,
                characters[start + 3] != "=",
                characters[start + 3] != "!"
            else {
                throw invalid(pattern, option: option)
            }
            return nil
        }
        if kind == "P" {
            guard start + 3 < characters.count, characters[start + 3] == "<" else {
                throw invalid(pattern, option: option)
            }
            var end = start + 4
            while end < characters.count, characters[end] != ">" {
                end += 1
            }
            guard end < characters.count, end > start + 4 else {
                throw invalid(pattern, option: option)
            }
            let name = String(characters[(start + 4)..<end])
            return ("(?<\(name)>", end + 1)
        }

        var end = start + 2
        var sawFlag = false
        var retainedFlags = ""
        while end < characters.count,
            characters[end] != ":",
            characters[end] != ")"
        {
            let flag = characters[end]
            guard flag == "i" || flag == "m" || flag == "s" || flag == "U" || flag == "-"
            else {
                throw invalid(pattern, option: option)
            }
            if flag != "U" {
                retainedFlags.append(flag)
            }
            sawFlag = sawFlag || flag != "-"
            end += 1
        }
        guard sawFlag, end < characters.count else {
            throw invalid(pattern, option: option)
        }
        let delimiter = characters[end]
        guard let normalizedFlags = normalizedFlags(retainedFlags) else {
            throw invalid(pattern, option: option)
        }
        if normalizedFlags.isEmpty {
            return (delimiter == ":" ? "(?:" : "(?:)", end + 1)
        }
        return (
            delimiter == ":" ? "(?\(normalizedFlags):" : "(?\(normalizedFlags))",
            end + 1
        )
    }

    private static func normalizedFlags(_ flags: String) -> String? {
        let pieces = flags.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count <= 2 else {
            return nil
        }
        let enabled = pieces[0].filter { $0 != "U" }
        let disabled = pieces.count == 2 ? pieces[1].filter { $0 != "U" } : ""
        if enabled.isEmpty {
            return disabled.isEmpty ? "" : "-" + disabled
        }
        return disabled.isEmpty ? enabled : enabled + "-" + disabled
    }

    private static func repetition(
        in characters: [Character],
        at start: Int
    ) -> Repetition? {
        var index = start + 1
        guard let minimum = count(in: characters, index: &index) else {
            return nil
        }
        var maximum: Int? = minimum
        if index < characters.count, characters[index] == "," {
            index += 1
            maximum = count(in: characters, index: &index)
        }
        guard index < characters.count, characters[index] == "}" else {
            return nil
        }
        return Repetition(minimum: minimum, maximum: maximum, end: index + 1)
    }

    private static func count(
        in characters: [Character],
        index: inout Int
    ) -> Int? {
        let start = index
        var value = 0
        while index < characters.count,
            let digit = asciiDigit(characters[index])
        {
            value = min(1_001, value * 10 + Int(digit))
            index += 1
        }
        return index == start ? nil : value
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

    private static func invalid(
        _ pattern: String,
        option: String
    ) -> GELFProviderError {
        .invalidMetadataRegularExpression(option: option, value: pattern)
    }
}
