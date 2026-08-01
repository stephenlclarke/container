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

import ContainerResource
import Foundation

package struct ContainerLogDualCacheSnapshot: Equatable, Sendable {
    package let primaryNonBlockingDelivery: ContainerLogDeliverySnapshot?
    package let cacheNonBlockingDelivery: ContainerLogDeliverySnapshot?
    package let primaryWriteFailureCount: UInt64
    package let cacheWriteFailureCount: UInt64
    package let primaryCloseFailureCount: UInt64
    package let cacheCloseFailureCount: UInt64
    package let closing: Bool
    package let closed: Bool
}

/// Docker-compatible local-cache wrapper for a driver without native reads.
///
/// The primary endpoint and cache intentionally own separate delivery rings.
/// Docker wraps the primary in a ring only for explicit non-blocking mode, but
/// wraps the cache for omitted or non-blocking mode. A primary write failure
/// skips the cache. Closing always attempts both endpoints and reports only the
/// primary close error while retaining cache failures in diagnostics.
package final class ContainerLogDualCacheDestination: ContainerLogRecordDestination,
    @unchecked Sendable
{
    private enum State: Equatable {
        case open
        case closing
        case closed
    }

    private enum Endpoint {
        case direct(any ContainerLogRecordDestination)
        case nonBlocking(ContainerLogNonBlockingDelivery)

        func write(_ record: ContainerLogRecordV2) throws {
            switch self {
            case .direct(let destination):
                try destination.write(record)
            case .nonBlocking(let delivery):
                _ = try delivery.enqueue(record)
            }
        }

        func close() throws {
            switch self {
            case .direct(let destination):
                try destination.close()
            case .nonBlocking(let delivery):
                try delivery.close()
            }
        }

        var nonBlockingSnapshot: ContainerLogDeliverySnapshot? {
            if case .nonBlocking(let delivery) = self {
                return delivery.snapshot
            }
            return nil
        }
    }

    private let primary: Endpoint
    private let cache: Endpoint
    private let condition = NSCondition()
    private var state = State.open
    private var primaryWriteFailureCount: UInt64 = 0
    private var cacheWriteFailureCount: UInt64 = 0
    private var primaryCloseFailureCount: UInt64 = 0
    private var cacheCloseFailureCount: UInt64 = 0
    private var primaryCloseError: (any Error)?

    package init(
        primary: any ContainerLogRecordDestination,
        cache: any ContainerLogRecordDestination,
        deliveryConfiguration: LogDeliveryConfiguration
    ) {
        let capacity =
            deliveryConfiguration.effectiveMaxBufferSizeInBytes
            ?? LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes
        if deliveryConfiguration.effectiveMode == .nonBlocking {
            self.primary = .nonBlocking(
                ContainerLogNonBlockingDelivery(
                    destination: primary,
                    capacityInBytes: capacity
                ))
        } else {
            self.primary = .direct(primary)
        }

        if deliveryConfiguration.requestedMode == .blocking {
            self.cache = .direct(cache)
        } else {
            self.cache = .nonBlocking(
                ContainerLogNonBlockingDelivery(
                    destination: cache,
                    capacityInBytes: capacity
                ))
        }
    }

    deinit {
        try? close()
    }

    package func write(_ record: ContainerLogRecordV2) throws {
        try condition.withLock {
            guard state == .open else {
                throw ContainerLogDeliveryError.closed
            }
            do {
                try primary.write(record)
            } catch {
                increment(&primaryWriteFailureCount)
                throw error
            }
            do {
                try cache.write(record)
            } catch {
                increment(&cacheWriteFailureCount)
                throw error
            }
        }
    }

    package func close() throws {
        condition.lock()
        switch state {
        case .closed:
            let error = primaryCloseError
            condition.unlock()
            if let error {
                throw error
            }
            return
        case .closing:
            while state != .closed {
                condition.wait()
            }
            let error = primaryCloseError
            condition.unlock()
            if let error {
                throw error
            }
            return
        case .open:
            state = .closing
            condition.unlock()
        }

        var primaryError: (any Error)?
        do {
            try primary.close()
        } catch {
            primaryError = error
            condition.withLock {
                increment(&primaryCloseFailureCount)
            }
        }
        do {
            try cache.close()
        } catch {
            condition.withLock {
                increment(&cacheCloseFailureCount)
            }
        }

        condition.withLock {
            primaryCloseError = primaryError
            state = .closed
            condition.broadcast()
        }
        if let primaryError {
            throw primaryError
        }
    }

    package var snapshot: ContainerLogDualCacheSnapshot {
        condition.withLock {
            ContainerLogDualCacheSnapshot(
                primaryNonBlockingDelivery: primary.nonBlockingSnapshot,
                cacheNonBlockingDelivery: cache.nonBlockingSnapshot,
                primaryWriteFailureCount: primaryWriteFailureCount,
                cacheWriteFailureCount: cacheWriteFailureCount,
                primaryCloseFailureCount: primaryCloseFailureCount,
                cacheCloseFailureCount: cacheCloseFailureCount,
                closing: state == .closing,
                closed: state == .closed
            )
        }
    }

    private func increment(_ value: inout UInt64) {
        let (result, overflow) = value.addingReportingOverflow(1)
        value = overflow ? UInt64.max : result
    }
}
