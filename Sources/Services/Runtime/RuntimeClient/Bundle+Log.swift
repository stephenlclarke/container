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

extension ContainerResource.Bundle {
    public static let jsonFileLogName = "json.log"
    public static let nativeLocalLogName = "local.bin"

    /// The pathname for the workload log file.
    public var containerLog: URL {
        path.appendingPathComponent("stdio.log")
    }

    /// The pathname for timestamped workload log records.
    public var containerLogRecords: URL {
        path.appendingPathComponent("stdio.jsonl")
    }

    /// Private root for logging-v2 controller state and canonical stores.
    public var containerLoggingV2: URL {
        path.appendingPathComponent("logging-v2", isDirectory: true)
    }

    /// Public-path-capable canonical `json-file` store directory.
    public var containerJSONFileLogDirectory: URL {
        containerLoggingV2.appendingPathComponent("json-file", isDirectory: true)
    }

    public var containerJSONFileLog: URL {
        containerJSONFileLogDirectory.appendingPathComponent(Self.jsonFileLogName)
    }

    /// Private canonical `local` store directory.
    public var containerNativeLocalLogDirectory: URL {
        containerLoggingV2.appendingPathComponent("local", isDirectory: true)
    }

    public var containerNativeLocalLog: URL {
        containerNativeLocalLogDirectory.appendingPathComponent(Self.nativeLocalLogName)
    }
}
