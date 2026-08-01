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

/// Bounded evaluator for Docker's logging tag surface. It implements the
/// fields and helper functions registered by Moby's logger template package,
/// without admitting arbitrary code or host filesystem access.
public enum SyslogTagTemplate {
    private static let maximumActions = 1_024

    public static func render(
        _ template: String,
        info: SyslogContainerInfo,
        configuration: [String: String] = [:]
    ) throws -> String {
        var output = ""
        var cursor = template.startIndex
        var actionCount = 0

        while let opening = template[cursor...].range(of: "{{") {
            output += template[cursor..<opening.lowerBound]
            guard let closing = template[opening.upperBound...].range(of: "}}") else {
                throw invalid(template)
            }
            actionCount += 1
            guard actionCount <= maximumActions else {
                throw invalid(template)
            }
            let action = template[opening.upperBound..<closing.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else {
                throw invalid(template)
            }
            output += try evaluate(
                action,
                info: info,
                configuration: configuration,
                source: template
            ).rendered
            guard output.utf8.count <= SyslogDriverConfiguration.maximumTagUTF8Bytes else {
                throw SyslogProviderError.tagExceedsUTF8Limit(
                    maximumBytes: SyslogDriverConfiguration.maximumTagUTF8Bytes
                )
            }
            cursor = closing.upperBound
        }

        output += template[cursor...]
        guard output.utf8.count <= SyslogDriverConfiguration.maximumTagUTF8Bytes else {
            throw SyslogProviderError.tagExceedsUTF8Limit(
                maximumBytes: SyslogDriverConfiguration.maximumTagUTF8Bytes
            )
        }
        return output
    }

    private static func evaluate(
        _ action: String,
        info: SyslogContainerInfo,
        configuration: [String: String],
        source: String
    ) throws -> TemplateValue {
        let stages = try splitPipeline(action, source: source)
        guard let first = stages.first else {
            throw invalid(source)
        }
        var value = try evaluateStage(
            first,
            piped: nil,
            info: info,
            configuration: configuration,
            source: source
        )
        for stage in stages.dropFirst() {
            value = try evaluateStage(
                stage,
                piped: value,
                info: info,
                configuration: configuration,
                source: source
            )
        }
        return value
    }

    private static func evaluateStage(
        _ stage: String,
        piped: TemplateValue?,
        info: SyslogContainerInfo,
        configuration: [String: String],
        source: String
    ) throws -> TemplateValue {
        var tokens = try tokenize(stage, source: source)
        guard !tokens.isEmpty else {
            throw invalid(source)
        }
        if let piped {
            tokens.append(.value(piped))
        }

        switch tokens[0] {
        case .word(let word) where word.hasPrefix("."):
            guard tokens.count == 1 else {
                throw invalid(source)
            }
            return try field(
                word,
                info: info,
                configuration: configuration,
                source: source
            )
        case .string(let string):
            guard tokens.count == 1 else {
                throw invalid(source)
            }
            return .string(string)
        case .value(let value):
            guard tokens.count == 1 else {
                throw invalid(source)
            }
            return value
        case .word(let function):
            let arguments = try tokens.dropFirst().map { token in
                try resolve(
                    token,
                    info: info,
                    configuration: configuration,
                    source: source
                )
            }
            return try call(function, arguments: arguments, source: source)
        }
    }

    private static func resolve(
        _ token: Token,
        info: SyslogContainerInfo,
        configuration: [String: String],
        source: String
    ) throws -> TemplateValue {
        switch token {
        case .word(let word) where word.hasPrefix("."):
            try field(
                word,
                info: info,
                configuration: configuration,
                source: source
            )
        case .word(let word):
            if let integer = Int(word) {
                .integer(integer)
            } else if word == "true" {
                .boolean(true)
            } else if word == "false" {
                .boolean(false)
            } else {
                .string(word)
            }
        case .string(let string):
            .string(string)
        case .value(let value):
            value
        }
    }

    private static func field(
        _ name: String,
        info: SyslogContainerInfo,
        configuration: [String: String],
        source: String
    ) throws -> TemplateValue {
        switch name {
        case ".ID": .string(info.shortContainerID)
        case ".FullID", ".ContainerID": .string(info.containerID)
        case ".Name": .string(info.name)
        case ".ContainerName": .string(info.containerName)
        case ".Command": .string(info.command)
        case ".ContainerEntrypoint": .string(info.containerEntrypoint)
        case ".ContainerArgs": .strings(info.containerArguments)
        case ".ImageID": .string(info.shortImageID)
        case ".ImageFullID", ".ContainerImageID": .string(info.containerImageID)
        case ".ImageName", ".ContainerImageName": .string(info.containerImageName)
        case ".Hostname": .string(info.hostname)
        case ".ContainerEnv": .strings(info.containerEnvironment)
        case ".ContainerLabels": .dictionary(info.containerLabels)
        case ".Config": .dictionary(configuration)
        case ".LogPath": .string(info.logPath)
        case ".DaemonName": .string(info.daemonName)
        default: throw invalid(source)
        }
    }

    private static func call(
        _ function: String,
        arguments: [TemplateValue],
        source: String
    ) throws -> TemplateValue {
        switch function {
        case "lower":
            return .string(try oneString(arguments, source: source).lowercased())
        case "upper":
            return .string(try oneString(arguments, source: source).uppercased())
        case "title":
            return .string(title(try oneString(arguments, source: source)))
        case "split":
            guard arguments.count == 2 else { throw invalid(source) }
            let value = try arguments[0].string(source: source)
            let separator = try arguments[1].string(source: source)
            return .strings(value.components(separatedBy: separator))
        case "join":
            guard arguments.count == 2 else { throw invalid(source) }
            let values = try arguments[0].strings(source: source)
            let separator = try arguments[1].string(source: source)
            return .string(values.joined(separator: separator))
        case "pad":
            guard arguments.count == 3 else { throw invalid(source) }
            let value = try arguments[0].string(source: source)
            let prefix = try arguments[1].integer(source: source)
            let suffix = try arguments[2].integer(source: source)
            guard prefix >= 0, suffix >= 0 else { throw invalid(source) }
            if value.isEmpty {
                return .string("")
            }
            return .string(
                String(repeating: " ", count: prefix)
                    + value
                    + String(repeating: " ", count: suffix)
            )
        case "truncate":
            guard arguments.count == 2 else { throw invalid(source) }
            let value = try arguments[0].string(source: source)
            let length = try arguments[1].integer(source: source)
            guard length >= 0 else { throw invalid(source) }
            if value.utf8.count < length {
                return .string(value)
            }
            return .string(String(decoding: value.utf8.prefix(length), as: UTF8.self))
        case "json":
            guard arguments.count == 1 else { throw invalid(source) }
            return .string(try arguments[0].json(source: source))
        case "index":
            guard arguments.count == 2 else { throw invalid(source) }
            let key = try arguments[1].string(source: source)
            switch arguments[0] {
            case .dictionary(let values): return .string(values[key] ?? "<no value>")
            case .strings(let values):
                let index = try arguments[1].integer(source: source)
                guard values.indices.contains(index) else { throw invalid(source) }
                return .string(values[index])
            default: throw invalid(source)
            }
        case "print":
            return .string(arguments.map(\.rendered).joined())
        case "println":
            return .string(arguments.map(\.rendered).joined(separator: " ") + "\n")
        case "printf":
            guard let format = arguments.first else { throw invalid(source) }
            return .string(
                try printf(
                    format: format.string(source: source),
                    arguments: Array(arguments.dropFirst()),
                    source: source
                )
            )
        default:
            throw invalid(source)
        }
    }

    private static func printf(
        format: String,
        arguments: [TemplateValue],
        source: String
    ) throws -> String {
        var output = ""
        var argumentIndex = 0
        var cursor = format.startIndex
        while cursor < format.endIndex {
            guard format[cursor] == "%" else {
                output.append(format[cursor])
                cursor = format.index(after: cursor)
                continue
            }
            let next = format.index(after: cursor)
            guard next < format.endIndex else { throw invalid(source) }
            if format[next] == "%" {
                output.append("%")
                cursor = format.index(after: next)
                continue
            }
            guard argumentIndex < arguments.count else { throw invalid(source) }
            let verb = format[next]
            let argument = arguments[argumentIndex]
            argumentIndex += 1
            switch verb {
            case "s", "v": output += argument.rendered
            case "q": output += try TemplateValue.string(argument.rendered).json(source: source)
            case "d": output += String(try argument.integer(source: source))
            default: throw invalid(source)
            }
            cursor = format.index(after: next)
        }
        guard argumentIndex == arguments.count else { throw invalid(source) }
        return output
    }

    private static func oneString(
        _ arguments: [TemplateValue],
        source: String
    ) throws -> String {
        guard arguments.count == 1 else { throw invalid(source) }
        return try arguments[0].string(source: source)
    }

    private static func title(_ value: String) -> String {
        var output = ""
        var startsWord = true
        for character in value {
            if character.isLetter || character.isNumber {
                output += startsWord ? String(character).uppercased() : String(character)
                startsWord = false
            } else {
                output.append(character)
                startsWord = true
            }
        }
        return output
    }

    private static func splitPipeline(_ action: String, source: String) throws -> [String] {
        var stages = [String]()
        var start = action.startIndex
        var cursor = action.startIndex
        var quote: Character?
        var escaped = false
        while cursor < action.endIndex {
            let character = action[cursor]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "`" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == "|", quote == nil {
                stages.append(String(action[start..<cursor]).trimmingCharacters(in: .whitespaces))
                start = action.index(after: cursor)
            }
            cursor = action.index(after: cursor)
        }
        guard quote == nil, !escaped else { throw invalid(source) }
        stages.append(String(action[start...]).trimmingCharacters(in: .whitespaces))
        guard stages.allSatisfy({ !$0.isEmpty }) else { throw invalid(source) }
        return stages
    }

    private static func tokenize(_ stage: String, source: String) throws -> [Token] {
        var tokens = [Token]()
        var cursor = stage.startIndex
        while cursor < stage.endIndex {
            while cursor < stage.endIndex, stage[cursor].isWhitespace {
                cursor = stage.index(after: cursor)
            }
            guard cursor < stage.endIndex else { break }
            if stage[cursor] == "\"" {
                let start = cursor
                cursor = stage.index(after: cursor)
                var escaped = false
                var appended = false
                while cursor < stage.endIndex {
                    let character = stage[cursor]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        cursor = stage.index(after: cursor)
                        let literal = String(stage[start..<cursor])
                        guard
                            let data = literal.data(using: .utf8),
                            let decoded = try? JSONDecoder().decode(String.self, from: data)
                        else {
                            throw invalid(source)
                        }
                        tokens.append(.string(decoded))
                        appended = true
                        break
                    }
                    cursor = stage.index(after: cursor)
                }
                guard appended else { throw invalid(source) }
            } else if stage[cursor] == "`" {
                cursor = stage.index(after: cursor)
                let start = cursor
                guard let closing = stage[cursor...].firstIndex(of: "`") else {
                    throw invalid(source)
                }
                tokens.append(.string(String(stage[start..<closing])))
                cursor = stage.index(after: closing)
            } else {
                let start = cursor
                while cursor < stage.endIndex, !stage[cursor].isWhitespace {
                    cursor = stage.index(after: cursor)
                }
                tokens.append(.word(String(stage[start..<cursor])))
            }
        }
        return tokens
    }

    private static func invalid(_ source: String) -> SyslogProviderError {
        .invalidTagTemplate(source)
    }
}

private enum Token {
    case word(String)
    case string(String)
    case value(TemplateValue)
}

private enum TemplateValue {
    case string(String)
    case strings([String])
    case dictionary([String: String])
    case integer(Int)
    case boolean(Bool)

    var rendered: String {
        switch self {
        case .string(let value): value
        case .strings(let values): "[" + values.joined(separator: " ") + "]"
        case .dictionary(let values):
            "map[" + values.keys.sorted().map { "\($0):\(values[$0] ?? "")" }.joined(separator: " ") + "]"
        case .integer(let value): String(value)
        case .boolean(let value): String(value)
        }
    }

    func string(source: String) throws -> String {
        guard case .string(let value) = self else {
            throw SyslogProviderError.invalidTagTemplate(source)
        }
        return value
    }

    func strings(source: String) throws -> [String] {
        guard case .strings(let values) = self else {
            throw SyslogProviderError.invalidTagTemplate(source)
        }
        return values
    }

    func integer(source: String) throws -> Int {
        switch self {
        case .integer(let value): return value
        case .string(let value):
            guard let parsed = Int(value) else {
                throw SyslogProviderError.invalidTagTemplate(source)
            }
            return parsed
        default: throw SyslogProviderError.invalidTagTemplate(source)
        }
    }

    func json(source: String) throws -> String {
        let object: Any
        switch self {
        case .string(let value): object = value
        case .strings(let values): object = values
        case .dictionary(let values): object = values
        case .integer(let value): object = value
        case .boolean(let value): object = value
        }
        guard JSONSerialization.isValidJSONObject([object]) else {
            throw SyslogProviderError.invalidTagTemplate(source)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw SyslogProviderError.invalidTagTemplate(source)
        }
        return encoded
    }
}
