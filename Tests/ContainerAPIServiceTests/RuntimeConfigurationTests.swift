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
import ContainerRuntimeClient
import ContainerRuntimeLinuxClient
import Containerization
import ContainerizationOCI
import Foundation
import Testing

/// Unit tests for RuntimeConfiguration functionality.
///
/// These tests verify the runtime configuration serialization and deserialization,
/// ensuring that configuration can be properly written, read, and used to create bundles.
struct RuntimeConfigurationTests {

    /// Test that reading non-existent runtime configuration file throws
    /// appropriate error
    @Test
    func testReadNonExistentRuntimeConfiguration() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let nonExistentPath = tempDir.appendingPathComponent("non-existent-\(UUID()).json")

        #expect(throws: Error.self) {
            _ = try RuntimeConfiguration.readRuntimeConfiguration(from: nonExistentPath)
        }
    }

    /// Test that runtime configuration reads and writes as expected
    @Test
    func testRuntimeConfigurationReadWrite() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let initFs = Filesystem.virtiofs(
            source: "/path/to/initfs",
            destination: "/",
            options: ["ro"]
        )

        let kernel = Kernel(
            path: URL(fileURLWithPath: "/path/to/kernel"),
            platform: .linuxArm
        )

        let runtimeConfig = RuntimeConfiguration(
            path: bundlePath,
            initialFilesystem: initFs,
            kernel: kernel,
            containerConfiguration: nil,
            containerRootFilesystem: nil,
            options: nil
        )

        try runtimeConfig.writeRuntimeConfiguration()

        let readRuntimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(
            readRuntimeConfig.path == bundlePath,
            "Path should match")
        #expect(
            readRuntimeConfig.kernel.path == kernel.path,
            "Kernel path should match")
        #expect(
            readRuntimeConfig.initialFilesystem.source == initFs.source,
            "Initial filesystem source should match")
        #expect(
            readRuntimeConfig.containerConfiguration == nil,
            "Container configuration should be nil")
        #expect(
            readRuntimeConfig.containerRootFilesystem == nil,
            "Root filesystem should be nil")
        #expect(
            readRuntimeConfig.options == nil,
            "Options should be nil")
    }

    @Test
    func testRuntimeConfigurationWithVariant() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let bundlePath = tempDir.appendingPathComponent("test-bundle-\(UUID())")

        defer {
            try? FileManager.default.removeItem(at: bundlePath)
        }

        let initFs = Filesystem.virtiofs(
            source: "/path/to/initfs",
            destination: "/",
            options: ["ro"]
        )

        let kernel = Kernel(
            path: URL(fileURLWithPath: "/path/to/kernel"),
            platform: .linuxArm
        )

        let linuxData = LinuxRuntimeData(
            variant: "test-variant",
            blockIO: ContainerizationOCI.LinuxBlockIO(
                weight: 500,
                leafWeight: nil,
                weightDevice: [],
                throttleReadBpsDevice: [ContainerizationOCI.LinuxThrottleDevice(major: 8, minor: 0, rate: 1_048_576)],
                throttleWriteBpsDevice: [],
                throttleReadIOPSDevice: [],
                throttleWriteIOPSDevice: []
            ),
            pidsLimit: 128,
            deviceCgroupRules: [
                ContainerizationOCI.LinuxDeviceCgroup(allow: true, type: "c", major: 1, minor: 3, access: "mr")
            ],
            devices: [
                LinuxDeviceMapping(source: "/dev/null", target: "/dev/xnull", permissions: "rw")
            ],
            gpuRequests: [
                LinuxGPURequest(count: -1)
            ]
        )
        let encodedData = try JSONEncoder().encode(linuxData)

        let runtimeConfig = RuntimeConfiguration(
            path: bundlePath,
            initialFilesystem: initFs,
            kernel: kernel,
            runtimeData: encodedData
        )

        try runtimeConfig.writeRuntimeConfiguration()

        let readRuntimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: bundlePath)

        #expect(readRuntimeConfig.runtimeData != nil, "runtimeData should be persisted")

        let decodedData = try JSONDecoder().decode(LinuxRuntimeData.self, from: readRuntimeConfig.runtimeData!)
        #expect(decodedData.variant == "test-variant", "Variant should round-trip through RuntimeConfiguration")
        #expect(decodedData.blockIO?.weight == 500, "Block I/O weight should round-trip through RuntimeConfiguration")
        #expect(decodedData.blockIO?.throttleReadBpsDevice.first?.rate == 1_048_576, "Block I/O throttles should round-trip through RuntimeConfiguration")
        #expect(decodedData.pidsLimit == 128, "Pids limit should round-trip through RuntimeConfiguration")
        #expect(decodedData.deviceCgroupRules.first?.major == 1, "Device cgroup rules should round-trip through RuntimeConfiguration")
        #expect(decodedData.deviceCgroupRules.first?.access == "mr", "Device cgroup rule access should round-trip through RuntimeConfiguration")
        #expect(decodedData.devices.first?.source == "/dev/null", "Device source should round-trip through RuntimeConfiguration")
        #expect(decodedData.devices.first?.target == "/dev/xnull", "Device target should round-trip through RuntimeConfiguration")
        #expect(decodedData.devices.first?.permissions == "rw", "Device permissions should round-trip through RuntimeConfiguration")
        #expect(decodedData.gpuRequests.first?.count == -1, "GPU requests should round-trip through RuntimeConfiguration")
    }

    @Test("LinuxRuntimeData decodes old payloads without device fields")
    func linuxRuntimeDataDecodesMissingDeviceFields() throws {
        let data = Data(#"{"variant":"legacy"}"#.utf8)
        let decoded = try JSONDecoder().decode(LinuxRuntimeData.self, from: data)

        #expect(decoded.variant == "legacy")
        #expect(decoded.blockIO == nil)
        #expect(decoded.pidsLimit == nil)
        #expect(decoded.deviceCgroupRules.isEmpty)
        #expect(decoded.devices.isEmpty)
        #expect(decoded.gpuRequests.isEmpty)
    }
}
