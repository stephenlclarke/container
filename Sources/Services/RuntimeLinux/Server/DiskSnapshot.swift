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

/// Creates host-side copy-on-write snapshots of virtual disk images.
enum DiskSnapshot {
    /// Clones a disk image without stopping writers in its guest.
    ///
    /// This requires the source and destination to be on an APFS volume. The
    /// caller is responsible for documenting that an active guest can produce
    /// an image that is not guaranteed to be filesystem or application
    /// consistent.
    static func clone(from source: String, to destination: String) throws {
        guard clonefile(source, destination, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
    }
}
