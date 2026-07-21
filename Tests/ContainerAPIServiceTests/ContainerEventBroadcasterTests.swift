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
import ContainerXPC
import Containerization
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerEventBroadcasterTests {
    @Test func terminalLifecycleEventsReportExitBeforeGenericStop() {
        let events = ContainersService.terminalLifecycleEvents(snapshot: stoppedSnapshot(exitCode: 137))

        #expect(events.map(\.action) == ["die", "stop"])
        #expect(events[0].attributes["exitCode"] == "137")
        #expect(events[0].attributes["status"] == "stopped")
        #expect(events[1].attributes["exitCode"] == nil)
    }

    @Test func removalEventsPreserveGenericDeleteAndAddDockerDestroy() {
        let events = ContainersService.removalEvents(snapshot: stoppedSnapshot())

        #expect(events.map(\.action) == ["delete", "destroy"])
        #expect(events.allSatisfy { $0.attributes["image"] == "alpine:3.20" })
    }

    @Test func killEventUsesCanonicalSignalAndIncludesTargetProcess() {
        let event = ContainersService.killEvent(
            snapshot: stoppedSnapshot(status: .running),
            processID: "demo-api-1",
            signal: Signal.kill.rawValue,
            requestedSignal: "SIGKILL"
        )

        #expect(event.action == "kill")
        #expect(event.attributes["signal"] == "9")
        #expect(event.attributes["process"] == "demo-api-1")
    }

    @Test func streamsPublishedEventsAsJSONLines() async throws {
        let broadcaster = ContainerEventBroadcaster()
        let subscription = await broadcaster.subscribe()
        defer {
            try? subscription.fileHandle.close()
        }

        let event = ContainerEvent(
            time: Date(timeIntervalSince1970: 1),
            type: "container",
            id: "api",
            action: "start",
            attributes: [
                "image": "alpine:3.20",
                "status": "running",
            ]
        )

        await broadcaster.publish(event)
        await broadcaster.cancel(subscription.id)

        let data = try #require(try subscription.fileHandle.readToEnd())
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        try #require(lines.count == 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ContainerEvent.self, from: Data(lines[0].utf8))

        #expect(decoded == event)
    }

    @Test func replaysBufferedEventsWithinTimeWindow() async throws {
        let broadcaster = ContainerEventBroadcaster()
        let old = event(time: Date(timeIntervalSince1970: 1), action: "create")
        let inside = event(time: Date(timeIntervalSince1970: 2), action: "start")
        let newer = event(time: Date(timeIntervalSince1970: 3), action: "stop")

        await broadcaster.publish(old)
        await broadcaster.publish(inside)
        await broadcaster.publish(newer)

        let subscription = await broadcaster.subscribe(
            options: ContainerEventOptions(
                since: Date(timeIntervalSince1970: 1.5),
                until: Date(timeIntervalSince1970: 2.5)
            ))
        defer {
            try? subscription.fileHandle.close()
        }

        let events = try decodedEvents(from: subscription.fileHandle)

        #expect(events == [inside])
    }

    @Test func liveStreamFiltersEventsBySince() async throws {
        let broadcaster = ContainerEventBroadcaster()
        let subscription = await broadcaster.subscribe(
            options: ContainerEventOptions(
                since: Date(timeIntervalSince1970: 2)
            ))
        defer {
            try? subscription.fileHandle.close()
        }

        await broadcaster.publish(event(time: Date(timeIntervalSince1970: 1), action: "create"))
        let expected = event(time: Date(timeIntervalSince1970: 2), action: "start")
        await broadcaster.publish(expected)
        await broadcaster.cancel(subscription.id)

        let events = try decodedEvents(from: subscription.fileHandle)

        #expect(events == [expected])
    }

    @Test func historyLimitDropsOldestEvents() async throws {
        let broadcaster = ContainerEventBroadcaster(historyLimit: 1)
        await broadcaster.publish(event(time: Date(timeIntervalSince1970: 1), action: "create"))
        let expected = event(time: Date(timeIntervalSince1970: 2), action: "start")
        await broadcaster.publish(expected)

        let subscription = await broadcaster.subscribe(
            options: ContainerEventOptions(
                until: Date(timeIntervalSince1970: 3)
            ))
        defer {
            try? subscription.fileHandle.close()
        }

        let events = try decodedEvents(from: subscription.fileHandle)

        #expect(events == [expected])
    }

    @Test func harnessDecodesEventOptions() {
        let message = XPCMessage(route: .containerEvent)
        let since = Date(timeIntervalSince1970: 1)
        let until = Date(timeIntervalSince1970: 2)
        message.set(key: .eventSince, value: since)
        message.set(key: .eventUntil, value: until)

        let options = ContainersHarness.eventOptions(from: message)

        #expect(options.since == since)
        #expect(options.until == until)
    }

    @Test func harnessLeavesAbsentEventOptionsUnset() {
        let message = XPCMessage(route: .containerEvent)

        let options = ContainersHarness.eventOptions(from: message)

        #expect(options.since == nil)
        #expect(options.until == nil)
    }

    private func event(time: Date, action: String) -> ContainerEvent {
        ContainerEvent(
            time: time,
            type: "container",
            id: "api",
            action: action,
            attributes: [
                "image": "alpine:3.20",
                "status": "running",
            ]
        )
    }

    private func decodedEvents(from handle: FileHandle) throws -> [ContainerEvent] {
        let data = try #require(try handle.readToEnd())
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines.map { line in
            try decoder.decode(ContainerEvent.self, from: Data(line.utf8))
        }
    }

    private func stoppedSnapshot(
        status: RuntimeStatus = .stopped,
        exitCode: Int32? = nil
    ) -> ContainerSnapshot {
        let image = ImageDescription(
            reference: "alpine:3.20",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        var configuration = ContainerConfiguration(id: "demo-api-1", image: image, process: process)
        configuration.labels = ["com.example.role": "api"]
        return ContainerSnapshot(
            configuration: configuration,
            status: status,
            networks: [],
            exitCode: exitCode
        )
    }
}
