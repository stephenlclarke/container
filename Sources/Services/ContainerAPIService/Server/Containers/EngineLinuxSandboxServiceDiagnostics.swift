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

import Darwin
import Foundation

package enum EngineLinuxSandboxServiceDiagnosticsV1 {
    package static func stdio(workloadRoot: URL) throws -> [FileHandle?] {
        [
            nil,
            try handle(
                at: workloadRoot.appendingPathComponent("service.stdout.log")
            ),
            try handle(
                at: workloadRoot.appendingPathComponent("service.stderr.log")
            ),
        ]
    }

    private static func handle(at url: URL) throws -> FileHandle {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
