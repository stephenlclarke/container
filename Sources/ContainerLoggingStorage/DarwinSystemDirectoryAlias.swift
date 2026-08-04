//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// Resolves only Darwin's immutable system directory aliases before a secure
/// descriptor-relative traversal. Arbitrary user-controlled symlinks remain
/// rejected by `O_NOFOLLOW` at every component.
package enum DarwinSystemDirectoryAlias {
    package static func canonicalPath(for path: String) -> String {
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/")
        {
            return "/private" + path
        }
        return path
    }
}
