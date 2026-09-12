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

import ContainerizationError
import ContainerizationExtras
import DNSServer
import Foundation
import SystemPackage

public struct PacketFilter: Sendable {
    public static let anchor = "com.apple/container"
    public static let defaultConfigPath = FilePath("/etc/pf.conf")
    public static let defaultAnchorsPath = FilePath("/etc/pf.anchors")

    private static let legacyAnchor = "com.apple.container"
    private static let anchorFileName = "com.apple.container"

    private let configPath: FilePath
    private let anchorsPath: FilePath
    private let run: @Sendable ([String]) throws -> Int32

    public init(configPath: FilePath = Self.defaultConfigPath, anchorsPath: FilePath = Self.defaultAnchorsPath) {
        self.init(configPath: configPath, anchorsPath: anchorsPath, run: Self.runPFCTL)
    }

    init(configPath: FilePath, anchorsPath: FilePath, run: @escaping @Sendable ([String]) throws -> Int32) {
        self.configPath = configPath
        self.anchorsPath = anchorsPath
        self.run = run
    }

    public func createRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchorFileName)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        var content = ""
        if fm.fileExists(atPath: anchorPath.string) {
            content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        }
        try updateConfig(removing: false)

        var lines = content.components(separatedBy: .newlines)
        if !content.contains(redirectRule) {
            lines.insert(redirectRule, at: lines.endIndex - 1)
        }

        try lines.joined(separator: "\n").write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
    }

    public func removeRedirectRule(from: IPAddress, to: IPAddress, domain: DNSName) throws {
        guard type(of: from) == type(of: to) else {
            throw ContainerizationError(.invalidArgument, message: "protocol does not match: \(from) vs. \(to)")
        }

        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchorFileName)

        let inet: String
        switch from {
        case .v4: inet = "inet"
        case .v6: inet = "inet6"
        }
        let redirectRule = "rdr \(inet) from any to \(from.description) -> \(to.description) # \(domain.pqdn)"

        guard fm.fileExists(atPath: anchorPath.string) else {
            try updateConfig(removing: true)
            return
        }

        let content = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        let removedLines = lines.filter { l in
            l != redirectRule
        }

        if removedLines == [""] {
            try fm.removeItem(atPath: anchorPath.string)
            try updateConfig(removing: true)
        } else {
            try removedLines.joined(separator: "\n").write(toFile: anchorPath.string, atomically: true, encoding: .utf8)
            try updateConfig(removing: false)
        }
    }

    private func updateConfig(removing: Bool) throws {
        let fm: FileManager = FileManager.default

        let anchorPath = self.anchorsPath.appending(Self.anchorFileName)

        let anchorKeywords = ["scrub-anchor", "nat-anchor", "rdr-anchor", "dummynet-anchor", "anchor"]
        let redirectAnchorText = "rdr-anchor \"\(Self.anchor)\" # managed by container"
        let loadAnchorText = "load anchor \"\(Self.anchor)\" from \"\(anchorPath.string)\""
        let ownedDirectives = Set(
            anchorKeywords.map { "\($0) \"\(Self.legacyAnchor)\"" } + [
                "load anchor \"\(Self.legacyAnchor)\" from \"\(anchorPath.string)\"",
                loadAnchorText,
            ])
        let normalizedManagedRedirectAnchor = Self.normalizedLine(redirectAnchorText, retainingComment: true)

        var content: String = ""
        if fm.fileExists(atPath: self.configPath.string) {
            content = try String(contentsOfFile: self.configPath.string, encoding: .utf8)
        }
        var lines = content.components(separatedBy: .newlines).filter { line in
            let directive = Self.normalizedLine(line)
            let completeLine = Self.normalizedLine(line, retainingComment: true)
            return !ownedDirectives.contains(directive) && completeLine != normalizedManagedRedirectAnchor
        }
        if !removing {
            if lines.last != "" {
                lines.append("")
            }
            let redirectAnchors = Set(["rdr-anchor \"com.apple/*\"", "rdr-anchor \"\(Self.anchor)\""])
            let hasApplicableRedirectAnchor = lines.contains { line in
                let directive = Self.normalizedLine(line)
                return redirectAnchors.contains(directive)
            }
            if !hasApplicableRedirectAnchor {
                lines.insert(redirectAnchorText, at: Self.redirectAnchorInsertionIndex(in: lines))
            }
            lines.insert(loadAnchorText, at: lines.endIndex - 1)
        }

        let updatedContent = lines.joined(separator: "\n")
        guard updatedContent != content else {
            return
        }

        do {
            try updatedContent.write(toFile: configPath.string, atomically: true, encoding: .utf8)
        } catch {
            throw ContainerizationError(.invalidState, message: "failed to write \"\(configPath.string)\"")
        }
    }

    private static func redirectAnchorInsertionIndex(in lines: [String]) -> Int {
        let filteringKeywords: Set<String> = ["anchor", "antispoof", "block", "dummynet", "dummynet-anchor", "match", "pass"]
        for (index, line) in lines.enumerated() {
            let directive = normalizedLine(line)
            guard !directive.isEmpty else {
                continue
            }
            if directive.hasPrefix("load anchor ") {
                return index
            }
            if let keyword = directive.split(separator: " ", maxSplits: 1).first,
                filteringKeywords.contains(String(keyword))
            {
                return index
            }
        }
        return lines.last == "" ? lines.index(before: lines.endIndex) : lines.endIndex
    }

    private static func normalizedLine(_ line: String, retainingComment: Bool = false) -> String {
        var content = ""
        var insideQuotes = false
        var escaped = false
        for character in line {
            if character == "#" && !insideQuotes && !retainingComment {
                break
            }
            content.append(character)
            if character == "\\" && insideQuotes {
                escaped.toggle()
                continue
            }
            if character == "\"" && !escaped {
                insideQuotes.toggle()
            }
            escaped = false
        }
        return content.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public func reinitialize() throws {
        let anchorPath = self.anchorsPath.appending(Self.anchorFileName)
        let fm = FileManager.default
        let hasAnchorFile = fm.fileExists(atPath: anchorPath.string)
        let path = hasAnchorFile ? anchorPath.string : "/dev/null"

        try validateRules(arguments: ["-n", "-a", Self.anchor, "-f", path], path: path)

        if fm.fileExists(atPath: self.configPath.string) {
            try validateRules(arguments: ["-n", "-f", self.configPath.string], path: self.configPath.string)
            try loadRules(arguments: ["-f", self.configPath.string])
            if !hasAnchorFile {
                try loadRules(anchor: Self.anchor, path: "/dev/null")
            }
        } else {
            try loadRules(anchor: Self.anchor, path: path)
        }

        try loadRules(anchor: Self.legacyAnchor, path: "/dev/null")
    }

    private func validateRules(arguments: [String], path: String) throws {
        let checkStatus: Int32
        do {
            checkStatus = try run(arguments)
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl rule check exec failed: \"\(error)\"")
        }
        guard checkStatus == 0 else {
            throw ContainerizationError(.internalError, message: "invalid pf config \"\(path)\"")
        }
    }

    private func loadRules(anchor: String, path: String) throws {
        try loadRules(arguments: ["-a", anchor, "-f", path])
    }

    private func loadRules(arguments: [String]) throws {
        let reloadStatus: Int32
        do {
            reloadStatus = try run(arguments)
        } catch {
            throw ContainerizationError(.internalError, message: "pfctl reload exec failed: \"\(error)\"")
        }
        guard reloadStatus == 0 else {
            throw ContainerizationError(.invalidState, message: "pfctl \(arguments.joined(separator: " ")) failed with status \(reloadStatus)")
        }
    }

    private static func runPFCTL(_ arguments: [String]) throws -> Int32 {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
