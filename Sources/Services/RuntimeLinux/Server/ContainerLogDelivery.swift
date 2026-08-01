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

package protocol ContainerLogRecordDestination: AnyObject, Sendable {
    func write(_ record: ContainerLogRecordV2) throws
    func close() throws
}

package enum ContainerLogDeliveryError: Error, Equatable, Sendable {
    case closed
    case invalidMaximumQueuedRecordCount(Int)
    case payloadByteCountOverflow
}

package enum ContainerLogEnqueueResult: Equatable, Sendable {
    case enqueued
    case dropped
}

package struct ContainerLogDeliverySnapshot: Equatable, Sendable {
    package let enqueuedRecordCount: UInt64
    package let droppedRecordCount: UInt64
    package let payloadLimitDroppedRecordCount: UInt64
    package let recordLimitDroppedRecordCount: UInt64
    package let deliveredRecordCount: UInt64
    package let deliveryFailureCount: UInt64
    package let discardedDuringCloseCount: UInt64
    package let queuedRecordCount: Int
    package let queuedPayloadBytes: UInt64
    package let closing: Bool
    package let closed: Bool
}

/// Docker-compatible non-blocking primary-driver delivery.
///
/// Capacity first applies Docker's payload-byte accounting and one-oversized-
/// record rule. A secondary 65,536-record ceiling bounds Docker's otherwise
/// unbounded zero-payload metadata flood; it does not change payload-limit
/// decisions. The background consumer keeps running after driver errors. Close
/// stops the consumer, drains queued records synchronously until the first
/// driver error, discards the remainder, and then closes the destination.
package final class ContainerLogNonBlockingDelivery: @unchecked Sendable {
    package static let defaultMaximumQueuedRecordCount = 65_536
    package static let maximumSupportedQueuedRecordCount = 65_536

    private enum State: Equatable {
        case open
        case closing
        case closed
    }

    package let capacityInBytes: UInt64
    package let maximumQueuedRecordCount: Int

    private let destination: any ContainerLogRecordDestination
    private let condition = NSCondition()
    private let consumerQueue = DispatchQueue(label: "com.apple.container.logging.non-blocking-delivery")
    private var records: [ContainerLogRecordV2] = []
    private var recordHead = 0
    private var queuedPayloadBytes: UInt64 = 0
    private var state = State.open
    private var consumerRunning = false
    private var closeError: (any Error)?
    private var enqueuedRecordCount: UInt64 = 0
    private var droppedRecordCount: UInt64 = 0
    private var payloadLimitDroppedRecordCount: UInt64 = 0
    private var recordLimitDroppedRecordCount: UInt64 = 0
    private var deliveredRecordCount: UInt64 = 0
    private var deliveryFailureCount: UInt64 = 0
    private var discardedDuringCloseCount: UInt64 = 0

    package init(
        destination: any ContainerLogRecordDestination,
        capacityInBytes: UInt64 = LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes
    ) {
        self.destination = destination
        self.capacityInBytes = capacityInBytes
        maximumQueuedRecordCount = Self.defaultMaximumQueuedRecordCount
    }

    package init(
        destination: any ContainerLogRecordDestination,
        capacityInBytes: UInt64 = LogDeliveryConfiguration.defaultNonBlockingBufferSizeInBytes,
        maximumQueuedRecordCount: Int
    ) throws {
        guard (1...Self.maximumSupportedQueuedRecordCount).contains(maximumQueuedRecordCount) else {
            throw ContainerLogDeliveryError.invalidMaximumQueuedRecordCount(maximumQueuedRecordCount)
        }
        self.destination = destination
        self.capacityInBytes = capacityInBytes
        self.maximumQueuedRecordCount = maximumQueuedRecordCount
    }

    deinit {
        try? close()
    }

    @discardableResult
    package func enqueue(_ record: ContainerLogRecordV2) throws -> ContainerLogEnqueueResult {
        condition.lock()
        guard state == .open else {
            condition.unlock()
            throw ContainerLogDeliveryError.closed
        }
        let payloadBytes = UInt64(record.payload.count)
        let (prospectiveBytes, overflow) = queuedPayloadBytes.addingReportingOverflow(payloadBytes)
        guard !overflow else {
            condition.unlock()
            throw ContainerLogDeliveryError.payloadByteCountOverflow
        }
        if queuedRecordCount > 0, prospectiveBytes > capacityInBytes {
            increment(&droppedRecordCount)
            increment(&payloadLimitDroppedRecordCount)
            condition.signal()
            condition.unlock()
            return .dropped
        }
        if queuedRecordCount >= maximumQueuedRecordCount {
            increment(&droppedRecordCount)
            increment(&recordLimitDroppedRecordCount)
            condition.signal()
            condition.unlock()
            return .dropped
        }

        records.append(record)
        queuedPayloadBytes = prospectiveBytes
        increment(&enqueuedRecordCount)
        let startConsumer = !consumerRunning
        if startConsumer {
            consumerRunning = true
        }
        condition.unlock()
        if startConsumer {
            consumerQueue.async { [self] in
                consume()
            }
        }
        return .enqueued
    }

    package func close() throws {
        condition.lock()
        switch state {
        case .closed:
            let error = closeError
            condition.unlock()
            if let error {
                throw error
            }
            return
        case .closing:
            while state != .closed {
                condition.wait()
            }
            let error = closeError
            condition.unlock()
            if let error {
                throw error
            }
            return
        case .open:
            state = .closing
            condition.broadcast()
        }

        while consumerRunning {
            condition.wait()
        }
        let remaining = drainLocked()
        condition.unlock()

        var driverFailed = false
        for (index, record) in remaining.enumerated() {
            if driverFailed {
                condition.withLock {
                    add(UInt64(remaining.count - index), to: &discardedDuringCloseCount)
                }
                break
            }
            do {
                try destination.write(record)
                condition.withLock {
                    increment(&deliveredRecordCount)
                }
            } catch {
                driverFailed = true
                condition.withLock {
                    increment(&deliveryFailureCount)
                }
            }
        }

        var terminalError: (any Error)?
        do {
            try destination.close()
        } catch {
            terminalError = error
        }

        condition.withLock {
            closeError = terminalError
            state = .closed
            condition.broadcast()
        }
        if let terminalError {
            throw terminalError
        }
    }

    package var snapshot: ContainerLogDeliverySnapshot {
        condition.withLock {
            ContainerLogDeliverySnapshot(
                enqueuedRecordCount: enqueuedRecordCount,
                droppedRecordCount: droppedRecordCount,
                payloadLimitDroppedRecordCount: payloadLimitDroppedRecordCount,
                recordLimitDroppedRecordCount: recordLimitDroppedRecordCount,
                deliveredRecordCount: deliveredRecordCount,
                deliveryFailureCount: deliveryFailureCount,
                discardedDuringCloseCount: discardedDuringCloseCount,
                queuedRecordCount: queuedRecordCount,
                queuedPayloadBytes: queuedPayloadBytes,
                closing: state == .closing,
                closed: state == .closed
            )
        }
    }

    private var queuedRecordCount: Int {
        records.count - recordHead
    }

    private func consume() {
        while true {
            condition.lock()
            guard state == .open, queuedRecordCount > 0 else {
                consumerRunning = false
                condition.broadcast()
                condition.unlock()
                return
            }
            let record = removeFirstLocked()
            condition.unlock()

            do {
                try destination.write(record)
                condition.withLock {
                    increment(&deliveredRecordCount)
                }
            } catch {
                condition.withLock {
                    increment(&deliveryFailureCount)
                }
            }
        }
    }

    private func removeFirstLocked() -> ContainerLogRecordV2 {
        precondition(queuedRecordCount > 0)
        let record = records[recordHead]
        recordHead += 1
        queuedPayloadBytes -= UInt64(record.payload.count)
        compactQueueIfNeededLocked()
        return record
    }

    private func drainLocked() -> [ContainerLogRecordV2] {
        let remaining = Array(records[recordHead...])
        records.removeAll(keepingCapacity: false)
        recordHead = 0
        queuedPayloadBytes = 0
        return remaining
    }

    private func compactQueueIfNeededLocked() {
        guard recordHead >= 1_024, recordHead * 2 >= records.count else {
            return
        }
        records.removeFirst(recordHead)
        recordHead = 0
    }

    private func increment(_ value: inout UInt64) {
        add(1, to: &value)
    }

    private func add(_ amount: UInt64, to value: inout UInt64) {
        let (result, overflow) = value.addingReportingOverflow(amount)
        value = overflow ? UInt64.max : result
    }
}

extension NSCondition {
    fileprivate func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
