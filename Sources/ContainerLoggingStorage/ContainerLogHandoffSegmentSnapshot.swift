//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.
//===----------------------------------------------------------------------===//

import Foundation

/// Immutable physical file evidence captured from a pinned local log inode.
///
/// Handoff carries the exact stored representation, including gzip bytes, so
/// destination publication never repairs, re-encodes, or re-sequences source
/// history.
package struct ContainerLogHandoffSegmentSnapshot: Equatable, Sendable {
    package let rotationIndex: UInt64
    package let compressed: Bool
    package let sourceDeviceID: UInt64
    package let sourceInode: UInt64
    package let bytes: Data

    package init(
        rotationIndex: UInt64,
        compressed: Bool,
        sourceDeviceID: UInt64,
        sourceInode: UInt64,
        bytes: Data
    ) {
        self.rotationIndex = rotationIndex
        self.compressed = compressed
        self.sourceDeviceID = sourceDeviceID
        self.sourceInode = sourceInode
        self.bytes = bytes
    }
}
