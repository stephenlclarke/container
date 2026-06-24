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
import Darwin
import Foundation

struct ContainerEventSubscription {
    let id: UUID
    let fileHandle: FileHandle
}

actor ContainerEventBroadcaster {
    private struct Subscriber {
        let writer: FileHandle
        let options: ContainerEventOptions
    }

    private var subscribers: [UUID: Subscriber] = [:]
    private var untilTasks: [UUID: Task<Void, Never>] = [:]
    private var history: [ContainerEvent] = []
    private let historyLimit: Int

    init(historyLimit: Int = 1_024) {
        self.historyLimit = historyLimit
    }

    func subscribe(options: ContainerEventOptions = .default) -> ContainerEventSubscription {
        let id = UUID()
        let pipe = Pipe()
        Self.setNonBlocking(pipe.fileHandleForWriting.fileDescriptor)
        for event in replayEvents(options: options) {
            guard write(event, to: pipe.fileHandleForWriting) else {
                try? pipe.fileHandleForWriting.close()
                return ContainerEventSubscription(id: id, fileHandle: pipe.fileHandleForReading)
            }
        }
        guard !hasElapsed(until: options.until) else {
            try? pipe.fileHandleForWriting.close()
            return ContainerEventSubscription(id: id, fileHandle: pipe.fileHandleForReading)
        }

        subscribers[id] = Subscriber(writer: pipe.fileHandleForWriting, options: options)
        scheduleUntilClose(id: id, until: options.until)
        return ContainerEventSubscription(id: id, fileHandle: pipe.fileHandleForReading)
    }

    func cancel(_ id: UUID) {
        untilTasks.removeValue(forKey: id)?.cancel()
        guard let subscriber = subscribers.removeValue(forKey: id) else {
            return
        }
        try? subscriber.writer.close()
    }

    func publish(_ event: ContainerEvent) {
        record(event)
        guard !subscribers.isEmpty else {
            return
        }

        guard let data = Self.encoded(event) else {
            return
        }

        var stale = [UUID]()
        for (id, subscriber) in subscribers {
            guard shouldKeepStreamOpen(event: event, options: subscriber.options) else {
                stale.append(id)
                continue
            }
            guard contains(event: event, options: subscriber.options) else {
                continue
            }
            if !write(data, to: subscriber.writer) {
                stale.append(id)
            }
        }

        for id in stale {
            cancel(id)
        }
    }

    private func record(_ event: ContainerEvent) {
        guard historyLimit > 0 else {
            return
        }
        history.append(event)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func replayEvents(options: ContainerEventOptions) -> [ContainerEvent] {
        history.filter { contains(event: $0, options: options) }
    }

    private func contains(event: ContainerEvent, options: ContainerEventOptions) -> Bool {
        if let since = options.since, event.time < since {
            return false
        }
        if let until = options.until, event.time > until {
            return false
        }
        return true
    }

    private func shouldKeepStreamOpen(event: ContainerEvent, options: ContainerEventOptions) -> Bool {
        guard let until = options.until else {
            return true
        }
        return event.time <= until
    }

    private func hasElapsed(until: Date?) -> Bool {
        guard let until else {
            return false
        }
        return until <= Date()
    }

    private func scheduleUntilClose(id: UUID, until: Date?) {
        guard let until else {
            return
        }
        let interval = until.timeIntervalSinceNow
        guard interval > 0 else {
            cancel(id)
            return
        }
        untilTasks[id] = Task {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(from: interval))
            self.closeIfElapsed(id: id, until: until)
        }
    }

    private func closeIfElapsed(id: UUID, until: Date) {
        guard let subscriber = subscribers[id],
            subscriber.options.until == until,
            until <= Date()
        else {
            return
        }
        cancel(id)
    }

    private func write(_ event: ContainerEvent, to writer: FileHandle) -> Bool {
        guard let data = Self.encoded(event) else {
            return false
        }
        return write(data, to: writer)
    }

    private func write(_ data: Data, to writer: FileHandle) -> Bool {
        do {
            try writer.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func encoded(_ event: ContainerEvent) -> Data? {
        var data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(event)
            data.append(0x0a)
        } catch {
            return nil
        }
        return data
    }

    private static func nanoseconds(from interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else {
            return 0
        }
        let nanoseconds = interval * 1_000_000_000
        return UInt64(min(nanoseconds.rounded(.up), Double(UInt64.max)))
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            return
        }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
}
