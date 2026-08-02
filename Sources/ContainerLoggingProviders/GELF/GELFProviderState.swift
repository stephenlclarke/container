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

/// Redaction-safe terminal replay state. It deliberately contains neither an
/// effect token nor a live provider session. The provider authenticates every
/// value before using it.
public struct GELFTerminalTombstoneV1: Sendable {
    public let request: LogDriverStartRequestV1
    public let state: GELFSessionState
    public let fenceReceiptDigest: String
    public let authenticationCode: Data

    public init(
        request: LogDriverStartRequestV1,
        state: GELFSessionState,
        fenceReceiptDigest: String,
        authenticationCode: Data
    ) {
        precondition(state == .writerFenced || state == .closed)
        self.request = request
        self.state = state
        self.fenceReceiptDigest = fenceReceiptDigest
        self.authenticationCode = authenticationCode
    }

    public var retainedByteCount: Int {
        request.idempotencyKey.utf8.count
            + request.semanticRequestDigest.utf8.count
            + request.sessionID.utf8.count
            + request.containerID.utf8.count
            + request.providerID.utf8.count
            + fenceReceiptDigest.utf8.count
            + authenticationCode.count
            + 8 * 6
            + 4
    }
}

/// Narrow provider-state seam. The default implementation is intentionally
/// process-local; a protected durable authority can implement the same bounded
/// contract without changing GELF replay semantics.
public protocol GELFProviderStateStoring: Sendable {
    func terminalTombstones() async throws -> [GELFTerminalTombstoneV1]
    func recordTerminalTombstone(_ tombstone: GELFTerminalTombstoneV1) async throws
}

public protocol GELFProviderStateClock: Sendable {
    func now() -> Duration
}

public struct SystemGELFProviderStateClock: GELFProviderStateClock {
    private let origin = ContinuousClock().now

    public init() {}

    public func now() -> Duration {
        origin.duration(to: ContinuousClock().now)
    }
}

/// Deterministic count-, byte-, and age-bounded process-local tombstones.
public actor InMemoryGELFProviderStateStore: GELFProviderStateStoring {
    public static let defaultMaximumTombstones = 4_096
    public static let defaultMaximumRetainedBytes = 16 * 1_024 * 1_024
    public static let defaultMaximumAge: Duration = .seconds(86_400)

    private struct Entry: Sendable {
        let tombstone: GELFTerminalTombstoneV1
        let insertedAt: Duration
        let ordinal: UInt64
    }

    private struct OrderedIdentity: Sendable {
        let sessionID: String
        let ordinal: UInt64
    }

    private let maximumTombstones: Int
    private let maximumRetainedBytes: Int
    private let maximumAge: Duration
    private let clock: any GELFProviderStateClock
    private var entries = [String: Entry]()
    private var order = [OrderedIdentity]()
    private var orderHead = 0
    private var retainedBytes = 0
    private var nextOrdinal: UInt64 = 1

    public init(
        maximumTombstones: Int = defaultMaximumTombstones,
        maximumRetainedBytes: Int = defaultMaximumRetainedBytes,
        maximumAge: Duration = defaultMaximumAge,
        clock: any GELFProviderStateClock = SystemGELFProviderStateClock()
    ) {
        precondition(maximumTombstones > 0)
        precondition(maximumRetainedBytes > 0)
        precondition(maximumAge > .zero)
        self.maximumTombstones = maximumTombstones
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumAge = maximumAge
        self.clock = clock
    }

    public func terminalTombstones() throws -> [GELFTerminalTombstoneV1] {
        pruneExpired(now: clock.now())
        return entries.values.sorted { $0.ordinal < $1.ordinal }.map(\.tombstone)
    }

    public func recordTerminalTombstone(
        _ tombstone: GELFTerminalTombstoneV1
    ) throws {
        let byteCount = tombstone.retainedByteCount
        guard byteCount <= maximumRetainedBytes else {
            throw GELFProviderError.providerStateBoundsExceeded
        }
        pruneExpired(now: clock.now())
        if let replaced = entries.removeValue(forKey: tombstone.request.sessionID) {
            retainedBytes -= replaced.tombstone.retainedByteCount
        }

        let ordinal = nextOrdinal
        nextOrdinal &+= 1
        let entry = Entry(
            tombstone: tombstone,
            insertedAt: clock.now(),
            ordinal: ordinal
        )
        entries[tombstone.request.sessionID] = entry
        order.append(
            OrderedIdentity(
                sessionID: tombstone.request.sessionID,
                ordinal: ordinal
            )
        )
        retainedBytes += byteCount
        evictToBounds()
        compactOrderIfNeeded()
    }

    private func pruneExpired(now: Duration) {
        for (sessionID, entry) in entries
        where entry.insertedAt + maximumAge <= now {
            entries.removeValue(forKey: sessionID)
            retainedBytes -= entry.tombstone.retainedByteCount
        }
        discardStaleOrderPrefix()
        compactOrderIfNeeded()
    }

    private func evictToBounds() {
        while entries.count > maximumTombstones
            || retainedBytes > maximumRetainedBytes
        {
            guard orderHead < order.count else {
                preconditionFailure("GELF tombstone order lost a live entry")
            }
            let identity = order[orderHead]
            orderHead += 1
            guard let entry = entries[identity.sessionID], entry.ordinal == identity.ordinal else {
                continue
            }
            entries.removeValue(forKey: identity.sessionID)
            retainedBytes -= entry.tombstone.retainedByteCount
        }
    }

    private func discardStaleOrderPrefix() {
        while orderHead < order.count {
            let identity = order[orderHead]
            guard
                let entry = entries[identity.sessionID],
                entry.ordinal == identity.ordinal
            else {
                orderHead += 1
                continue
            }
            break
        }
    }

    private func compactOrderIfNeeded() {
        if orderHead >= 4_096, orderHead >= order.count / 2 {
            order.removeFirst(orderHead)
            orderHead = 0
        }
    }
}
