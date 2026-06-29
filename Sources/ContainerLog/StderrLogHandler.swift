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

import Foundation
import Logging

/// Basic log handler for where simple message output is needed,
/// such as CLI commands.
public struct StderrLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public init() {}

    public func log(event: LogEvent) {
        writeLog(
            level: event.level,
            message: event.message,
            metadata: event.metadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line
        )
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        writeLog(
            level: level,
            message: message,
            metadata: metadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
    }

    private func writeLog(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let data: Data
        switch logLevel {
        case .debug, .trace:
            let timestamp = isoTimestamp()
            if let metadata, !metadata.isEmpty {
                data = Data("\(timestamp) \(message.description): \(metadata.description)\n".utf8)
            } else {
                data = Data("\(timestamp) \(message.description)\n".utf8)
            }
        default:
            if let metadata, !metadata.isEmpty {
                data = Data("\(message.description): \(metadata.description)\n".utf8)
            } else {
                data = Data("\(message.description)\n".utf8)
            }
        }

        FileHandle.standardError.write(data)
    }

    private func isoTimestamp() -> String {
        let date = Date()
        var time = time_t(date.timeIntervalSince1970)
        var milliseconds = Int(date.timeIntervalSince1970 * 1000) % 1000
        if milliseconds < 0 { milliseconds += 1000 }
        var utcTime = tm()
        gmtime_r(&time, &utcTime)
        let buf = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 32) { ptr -> String in
            strftime(ptr.baseAddress!, 32, "%Y-%m-%dT%H:%M:%S", &utcTime)
            return String(cString: ptr.baseAddress!)
        }
        return String(format: "%@.%03dZ", buf, milliseconds)
    }
}
