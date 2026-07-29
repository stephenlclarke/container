//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import Foundation

public struct ServiceManager {
    enum RegistrationAction: Equatable {
        case register
        case reuse
        case replace
    }

    private struct LaunchctlCommandResult {
        let status: Int32
        let standardError: String
    }

    private static func runLaunchctlCommand(args: [String]) throws -> LaunchctlCommandResult {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = args

        let standardError = Pipe()
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = standardError

        try launchctl.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()

        return LaunchctlCommandResult(
            status: launchctl.terminationStatus,
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }

    /// Register a service by providing the path to a plist.
    ///
    /// A launchd label is global to its domain. Reusing a label from another
    /// application root would direct this installation to the previous helper,
    /// so replace only services whose plist path does not match this registration.
    public static func register(plistPath: String) throws {
        let label = try launchdLabel(inPlistAt: plistPath)
        let domain = try Self.getDomainString()
        let service = "\(domain)/\(label)"

        let loadedPath = try loadedPlistPath(fullServiceLabel: service)
        switch registrationAction(loadedPlistPath: loadedPath, expectedPlistPath: plistPath) {
        case .reuse:
            return
        case .replace:
            let args = ["bootout", service]
            let result = try runLaunchctlCommand(args: args)
            try validateLaunchctlSuccess(
                status: result.status,
                standardError: result.standardError,
                args: args
            )
        case .register:
            break
        }

        let args = ["bootstrap", domain, plistPath]
        let result = try runLaunchctlCommand(args: args)
        try validateLaunchctlSuccess(
            status: result.status,
            standardError: result.standardError,
            args: args
        )
    }

    static func registrationAction(loadedPlistPath: String?, expectedPlistPath: String) -> RegistrationAction {
        guard let loadedPlistPath else {
            return .register
        }
        guard canonicalPath(loadedPlistPath) == canonicalPath(expectedPlistPath) else {
            return .replace
        }
        return .reuse
    }

    static func plistPath(fromLaunchctlPrint output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .lazy
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("path = ") else {
                    return nil
                }
                return String(trimmed.dropFirst("path = ".count))
            }
            .first
    }

    static func validateLaunchctlSuccess(status: Int32, standardError: String = "", args: [String]) throws {
        guard status == 0 else {
            let diagnostic = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnosticSuffix = diagnostic.isEmpty ? "" : ": \(diagnostic)"
            throw ContainerizationError(
                .internalError,
                message: "command `launchctl \(args.joined(separator: " "))` failed with status \(status)\(diagnosticSuffix)"
            )
        }
    }

    private static func loadedPlistPath(fullServiceLabel: String) throws -> String? {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", fullServiceLabel]

        let output = Pipe()
        launchctl.standardOutput = output
        launchctl.standardError = FileHandle.nullDevice

        try launchctl.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        guard launchctl.terminationStatus == 0,
            let outputText = String(data: outputData, encoding: .utf8)
        else {
            return nil
        }
        return plistPath(fromLaunchctlPrint: outputText)
    }

    private static func launchdLabel(inPlistAt plistPath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let label = plist["Label"] as? String,
            !label.isEmpty
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "launchd plist at \(plistPath) does not contain a Label"
            )
        }
        return label
    }

    private static func canonicalPath(_ path: String) -> String {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else {
                return URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Deregister a service by a launchd label.
    public static func deregister(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["bootout", label])
    }

    /// Deregister a service and pass return status
    public static func deregister(fullServiceLabel label: String, status: inout Int32) throws {
        status = try runLaunchctlCommand(args: ["bootout", label]).status
    }

    /// Restart a service by a launchd label.
    public static func kickstart(fullServiceLabel label: String) throws {
        _ = try runLaunchctlCommand(args: ["kickstart", "-k", label])
    }

    /// Send a signal to a service by a launchd label.
    public static func kill(fullServiceLabel label: String, signal: Int32 = 15) throws {
        _ = try runLaunchctlCommand(args: ["kill", "\(signal)", label])
    }

    /// Retrieve labels for all loaded launch units.
    public static func enumerate() throws -> [String] {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["list"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = stderrPipe

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(
                .internalError, message: "command `launchctl list` failed with status \(status), message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(
                .internalError, message: "could not decode output of command `launchctl list`, message: \(String(data: stderrData, encoding: .utf8) ?? "no error message")")
        }

        // The third field of each line of launchctl list output is the label
        return outputText.split { $0.isNewline }
            .map { String($0).split { $0.isWhitespace } }
            .filter { $0.count >= 3 }
            .map { String($0[2]) }
    }

    /// Check if a service has been registered or not.
    public static func isRegistered(fullServiceLabel label: String) throws -> Bool {
        let result = try runLaunchctlCommand(args: ["list", label])
        return result.status == 0
    }

    private static func getLaunchdSessionType() throws -> String {
        let launchctl = Foundation.Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["managername"]

        let null = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        launchctl.standardOutput = stdoutPipe
        launchctl.standardError = null

        try launchctl.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        launchctl.waitUntilExit()
        let status = launchctl.terminationStatus
        guard status == 0 else {
            throw ContainerizationError(.internalError, message: "command `launchctl managername` failed with status \(status)")
        }
        guard let outputText = String(data: outputData, encoding: .utf8) else {
            throw ContainerizationError(.internalError, message: "could not decode output of command `launchctl managername`")
        }
        return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func getDomainString() throws -> String {
        let effectiveUserID = geteuid()
        if effectiveUserID == 0 {
            return LaunchPlist.Domain.System.rawValue.lowercased()
        }
        let currentSessionType = try getLaunchdSessionType()
        return try domainString(sessionType: currentSessionType, effectiveUserID: effectiveUserID)
    }

    static func domainString(sessionType: String, effectiveUserID: uid_t) throws -> String {
        if effectiveUserID == 0 {
            return LaunchPlist.Domain.System.rawValue.lowercased()
        }

        switch sessionType {
        case LaunchPlist.Domain.System.rawValue:
            return LaunchPlist.Domain.System.rawValue.lowercased()
        case LaunchPlist.Domain.Background.rawValue:
            return "user/\(effectiveUserID)"
        case LaunchPlist.Domain.Aqua.rawValue:
            return "gui/\(effectiveUserID)"
        default:
            throw ContainerizationError(.internalError, message: "unsupported session type \(sessionType)")
        }
    }
}
