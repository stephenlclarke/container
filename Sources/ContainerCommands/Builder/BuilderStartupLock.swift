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

/// Serializes startup for one BuildKit container across CLI processes.
///
/// Build requests are allowed to execute concurrently once BuildKit is running.
/// This lock protects only the inspect/create/bootstrap lifecycle, which uses a
/// singleton container ID for each named builder.
final class BuilderStartupLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        self.unlock()
    }

    static func acquire(
        appRoot: URL,
        builderContainerId: String,
        nonBlocking: Bool = false
    ) throws -> BuilderStartupLock {
        let lockPath = Self.path(appRoot: appRoot, builderContainerId: builderContainerId)
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard Self.setLock(descriptor: descriptor, type: F_WRLCK, nonBlocking: nonBlocking) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = Darwin.close(descriptor)
            throw error
        }
        return BuilderStartupLock(descriptor: descriptor)
    }

    static func path(appRoot: URL, builderContainerId: String) -> String {
        appRoot
            .appendingPathComponent(".container-builder-\(builderContainerId).lock", isDirectory: false)
            .path
    }

    func unlock() {
        guard self.descriptor >= 0 else {
            return
        }
        _ = Self.setLock(descriptor: self.descriptor, type: F_UNLCK, nonBlocking: true)
        _ = Darwin.close(self.descriptor)
        self.descriptor = -1
    }

    private static func setLock(descriptor: Int32, type: Int32, nonBlocking: Bool) -> Int32 {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, nonBlocking ? F_SETLK : F_SETLKW, &lock)
    }
}
