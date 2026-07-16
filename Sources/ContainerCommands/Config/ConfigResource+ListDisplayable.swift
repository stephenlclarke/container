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

extension ConfigResource: ListDisplayable {
    public static var tableHeader: [String] {
        ["NAME", "SIZE", "LABELS"]
    }

    public var tableRow: [String] {
        let labels = configuration.labels.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return [
            name,
            ByteCountFormatter.string(fromByteCount: Int64(configuration.sizeInBytes), countStyle: .file),
            labels,
        ]
    }

    public var quietValue: String {
        name
    }
}
