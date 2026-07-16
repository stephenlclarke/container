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
import Foundation

/// A Docker-compatible client-side terminal sequence that detaches an attach
/// session without stopping the container process.
public struct DetachKeySequence: Sendable, Equatable {
    /// The Docker-compatible default: control-P followed by control-Q.
    public static let standard = try! DetachKeySequence("ctrl-p,ctrl-q")

    let bytes: [UInt8]

    /// Parses comma-separated literal or `ctrl-` key tokens.
    ///
    /// A literal token is one ASCII byte, `DEL`, or the Docker spelling
    /// `ctrl-a` through `ctrl-z`, `ctrl-@`, `ctrl-[`, `ctrl-\\`, `ctrl-]`,
    /// `ctrl-_`, or `ctrl-^`.
    public init(_ value: String) throws {
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else {
            throw Self.invalid(value)
        }

        bytes = try tokens.map { token in
            let value = String(token)
            if value.hasPrefix("ctrl-") {
                return try Self.controlByte(String(value.dropFirst("ctrl-".count)), value: value)
            }
            if value == "DEL" {
                return 127
            }
            guard value.utf8.count == 1, let byte = value.utf8.first else {
                throw Self.invalid(value)
            }
            return byte
        }
    }

    private static func controlByte(_ suffix: String, value: String) throws -> UInt8 {
        guard suffix.utf8.count == 1, let byte = suffix.utf8.first else {
            throw invalid(value)
        }
        switch byte {
        case 64:  // @
            return 0
        case 91...95:  // [, \\, ], ^, _
            return byte & 0x1F
        case 97...122:  // a-z
            return byte & 0x1F
        default:
            throw invalid(value)
        }
    }

    private static func invalid(_ value: String) -> ContainerizationError {
        ContainerizationError(
            .invalidArgument,
            message: "invalid detach key sequence '\(value)'; use comma-separated ASCII bytes, DEL, or ctrl-a through ctrl-z, ctrl-@, ctrl-[, ctrl-\\\\, ctrl-], ctrl-_, or ctrl-^"
        )
    }
}
