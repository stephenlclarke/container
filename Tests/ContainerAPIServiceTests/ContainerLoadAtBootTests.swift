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

import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import ContainerAPIService
@testable import ContainerPlugin

struct ContainerLoadAtBootTests {
    @Test
    func prebootstrapMutationUpdatesRuntimeConfigurationOnly() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "created-not-bootstrapped"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        let originalOptions = ContainerCreateOptions(
            autoRemove: false,
            restartPolicy: .no
        )
        try RuntimeConfiguration(
            path: bundlePath,
            initialFilesystem: .virtiofs(
                source: "/path/to/initfs",
                destination: "/",
                options: ["ro"]
            ),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/path/to/kernel"),
                platform: .linuxArm
            ),
            containerConfiguration: testConfiguration(id: id),
            options: originalOptions
        ).writeRuntimeConfiguration()

        var updatedConfiguration = testConfiguration(id: id)
        updatedConfiguration.dockerName = "renamed"
        let updatedOptions = ContainerCreateOptions(
            autoRemove: true,
            restartPolicy: ContainerRestartPolicy(mode: .always)
        )
        try ContainersService.persistContainerConfiguration(
            updatedConfiguration,
            options: updatedOptions,
            at: bundlePath
        )

        let persisted = try RuntimeConfiguration.readRuntimeConfiguration(
            from: bundlePath
        )
        #expect(persisted.containerConfiguration?.dockerName == "renamed")
        #expect(persisted.options?.autoRemove == true)
        #expect(persisted.options?.restartPolicy.mode == .always)
        #expect(
            !FileManager.default.fileExists(
                atPath: bundlePath.appendingPathComponent("config.json").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: bundlePath.appendingPathComponent("options.json").path
            )
        )
    }

    @Test
    func persistedTransientLifecycleIsDurablyNormalizedAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "interrupted-running"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        var configuration = testConfiguration(id: id)
        configuration.dockerID = String(repeating: "a", count: 64)
        try bundle.set(configuration: configuration)
        let record = ContainerLifecycleRecordV2(
            containerID: String(repeating: "a", count: 64),
            canonicalName: id,
            immutableBundleKey: id,
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .running,
                running: true,
                pid: 42,
                processGeneration: 1,
                transitionRevision: 7,
                operationGeneration: 8
            )
        )
        try bundle.setDurably(lifecycleRecordV2: record)

        var deregisteredLabels = [String]()
        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log,
            deregisterService: { deregisteredLabels.append($0) }
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(recovered.snapshot.state == .exited)
        #expect(!recovered.snapshot.running)
        #expect(recovered.snapshot.pid == 0)
        #expect(recovered.snapshot.finishedAt != nil)
        #expect(recovered.snapshot.transitionRevision == 8)
        #expect(recovered.snapshot.operationGeneration == 9)
        #expect(try bundle.lifecycleRecordV2 == recovered)
        #expect(deregisteredLabels.count == 1)
        #expect(deregisteredLabels[0].hasSuffix(".container-runtime-linux.\(id)"))
    }

    @Test
    func transientRuntimeStopFailureRetriesBeforeLoadingContainer() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "runtime-still-live"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let running = ContainerLifecycleRecordV2.migrate(
            bundleKey: id,
            canonicalName: id,
            selectedProviderFingerprint: "container-runtime-linux",
            legacy: ContainerLifecycleStateV1(startedDate: Date())
        )
        var persisted = running
        persisted.snapshot.state = .running
        persisted.snapshot.running = true
        persisted.snapshot.pid = 42
        try bundle.setDurably(lifecycleRecordV2: persisted)

        var deregistrationAttempts = 0
        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log,
            deregisterService: { _ in
                deregistrationAttempts += 1
                if deregistrationAttempts == 1 {
                    throw ContainerizationError(
                        .internalError,
                        message: "transient deregistration failure"
                    )
                }
            },
            waitBeforeDeregistrationRetry: {}
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )

        #expect(states[id] != nil)
        #expect(records[id]?.snapshot.state == .exited)
        #expect(deregistrationAttempts == 2)
        #expect(try bundle.lifecycleRecordV2?.snapshot.state == .exited)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func persistentRuntimeStopFailurePreventsAuthorityStartup() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "runtime-still-live"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let running = ContainerLifecycleRecordV2.migrate(
            bundleKey: id,
            canonicalName: id,
            selectedProviderFingerprint: "container-runtime-linux",
            legacy: ContainerLifecycleStateV1(startedDate: Date())
        )
        var persisted = running
        persisted.snapshot.state = .running
        persisted.snapshot.running = true
        persisted.snapshot.pid = 42
        try bundle.setDurably(lifecycleRecordV2: persisted)

        var deregistrationAttempts = 0
        #expect(throws: ContainerizationError.self) {
            try ContainersService.loadAtBoot(
                root: fixture.containers,
                loader: fixture.loader,
                log: fixture.log,
                deregisterService: { _ in
                    deregistrationAttempts += 1
                    throw ContainerizationError(
                        .internalError,
                        message: "runtime remains registered"
                    )
                },
                waitBeforeDeregistrationRetry: {}
            )
        }

        #expect(deregistrationAttempts == 3)
        #expect(try bundle.lifecycleRecordV2 == persisted)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func terminalLifecycleStillReconcilesSurvivingRuntimeService() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "bootstrapped-before-start-commit"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let created = ContainerLifecycleRecordV2.migrate(
            bundleKey: id,
            canonicalName: id,
            selectedProviderFingerprint: "container-runtime-linux",
            legacy: nil
        )
        try bundle.setDurably(lifecycleRecordV2: created)

        var deregisteredLabels = [String]()
        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log,
            deregisterService: { deregisteredLabels.append($0) }
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )

        #expect(records[id] == created)
        #expect(deregisteredLabels.count == 1)
        #expect(deregisteredLabels[0].hasSuffix(".container-runtime-linux.\(id)"))
    }

    @Test
    func interruptedPolicyUpdateResumesEligibleRestartAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "restart-after-authority-boot"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let updatedPolicy = ContainerRestartPolicy(mode: .always)
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: false, restartPolicy: updatedPolicy)
        )
        var persisted = ContainerLifecycleRecordV2.migrate(
            bundleKey: id,
            canonicalName: id,
            selectedProviderFingerprint: "container-runtime-linux",
            legacy: ContainerLifecycleStateV1(startedDate: Date())
        )
        persisted.snapshot.state = .running
        persisted.snapshot.running = true
        persisted.snapshot.pid = 42
        persisted.intent.restartPolicy = .no
        try bundle.setDurably(lifecycleRecordV2: persisted)

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(recovered.intent.restartPolicy == updatedPolicy)
        #expect(recovered.snapshot.state == .restarting)
        #expect(recovered.snapshot.restarting)
        #expect(recovered.snapshot.pid == 0)
        #expect(recovered.snapshot.restartCount == 1)
        #expect(recovered.snapshot.restartConsecutiveFailureCount == 1)
        #expect(try bundle.lifecycleRecordV2 == recovered)
    }

    @Test
    func interruptedExplicitRestartResumesWithoutAutomaticPolicy() {
        #expect(
            ContainersService.shouldResumeRestartAtBoot(
                previousState: .restarting,
                policy: .no,
                exitCode: 0,
                manualRestartSuppressed: true
            )
        )
        #expect(
            ContainersService.restartIntentAllowsPendingRestart(
                lifecycleState: .restarting,
                manualRestartSuppressed: true,
                policy: .no,
                exitCode: 0,
                restartConsecutiveFailureCount: 0
            )
        )
        #expect(
            !ContainersService.shouldResumeRestartAtBoot(
                previousState: .running,
                policy: ContainerRestartPolicy(mode: .onFailure),
                exitCode: 1
            )
        )
        #expect(
            !ContainersService.shouldResumeRestartAtBoot(
                previousState: .removing,
                policy: ContainerRestartPolicy(mode: .always),
                exitCode: 1
            )
        )
        #expect(
            !ContainersService.shouldResumeRestartAtBoot(
                previousState: .running,
                policy: ContainerRestartPolicy(mode: .always),
                exitCode: 0,
                manualRestartSuppressed: true
            )
        )
        #expect(
            !ContainersService.shouldResumeRestartAtBoot(
                previousState: .restarting,
                policy: ContainerRestartPolicy(
                    mode: .onFailure,
                    maximumRetryCount: 1
                ),
                exitCode: 1,
                restartConsecutiveFailureCount: 2
            )
        )
    }

    @Test
    func interruptedRenameIsCompletedFromDurableConfigurationAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "rename-interrupted"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        var configuration = testConfiguration(id: id)
        configuration.dockerName = "renamed"
        try bundle.set(configuration: configuration)
        var record = ContainerLifecycleRecordV2.migrate(
            bundleKey: id,
            canonicalName: id,
            selectedProviderFingerprint: configuration.runtimeHandler,
            legacy: nil
        )
        record.snapshot.operationGeneration = 4
        try bundle.setDurably(lifecycleRecordV2: record)

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(recovered.canonicalName == "renamed")
        #expect(recovered.snapshot.transitionRevision == 2)
        #expect(recovered.snapshot.operationGeneration == 5)
        #expect(try bundle.lifecycleRecordV2 == recovered)
    }

    @Test
    func stagedCreateOptionsArePreservedDuringLifecycleMigration() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "staged-options"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        let options = ContainerCreateOptions(autoRemove: true)
        try RuntimeConfiguration(
            path: bundlePath,
            initialFilesystem: .virtiofs(
                source: "/path/to/initfs",
                destination: "/",
                options: ["ro"]
            ),
            kernel: Kernel(
                path: URL(fileURLWithPath: "/path/to/kernel"),
                platform: .linuxArm
            ),
            containerConfiguration: testConfiguration(id: id),
            options: options
        ).writeRuntimeConfiguration()

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(recovered.intent.autoRemove)
        #expect(recovered.snapshot.state == .created)
        #expect(!recovered.intent.removalRequested)
        #expect(try ContainerResource.Bundle(path: bundlePath).lifecycleRecordV2 == recovered)
    }

    @Test
    func neverStartedAutoRemoveContainerSurvivesAuthorityRestart() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "auto-remove-created"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: true)
        )
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2.migrate(
                bundleKey: id,
                canonicalName: id,
                selectedProviderFingerprint: "container-runtime-linux",
                legacy: nil,
                intent: ContainerLifecycleIntentV2(autoRemove: true)
            )
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(recovered.snapshot.state == .created)
        #expect(!recovered.intent.removalRequested)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func interruptedRemovalRemainsQueuedForBootCleanup() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "interrupted-removal"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: true)
        )
        let removing = ContainerLifecycleRecordV2(
            containerID: ContainerLifecycleRecordV2.migrate(
                bundleKey: id,
                canonicalName: id,
                selectedProviderFingerprint: "container-runtime-linux",
                legacy: nil
            ).containerID,
            canonicalName: id,
            immutableBundleKey: id,
            selectedProviderFingerprint: "container-runtime-linux",
            intent: ContainerLifecycleIntentV2(
                autoRemove: true,
                removalRequested: true
            ),
            snapshot: ContainerLifecycleSnapshotV2(
                state: .removing,
                removalInProgress: false,
                transitionRevision: 4,
                operationGeneration: 5
            )
        )
        try bundle.setDurably(lifecycleRecordV2: removing)

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )

        #expect(states[id] != nil)
        let recovered = try #require(records[id])
        #expect(recovered.snapshot.state == .removing)
        #expect(recovered.snapshot.removalInProgress)
        #expect(recovered.snapshot.transitionRevision == 5)
        #expect(recovered.snapshot.operationGeneration == 6)
        #expect(try bundle.lifecycleRecordV2 == recovered)
    }

    @Test
    func autoRemoveExitIsQueuedWhenBootInterruptedBeforeRemovalIntent() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "auto-remove-exited"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: true)
        )
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2(
                containerID: ContainerLifecycleRecordV2.migrate(
                    bundleKey: id,
                    canonicalName: id,
                    selectedProviderFingerprint: "container-runtime-linux",
                    legacy: nil
                ).containerID,
                canonicalName: id,
                immutableBundleKey: id,
                selectedProviderFingerprint: "container-runtime-linux",
                intent: ContainerLifecycleIntentV2(autoRemove: true),
                snapshot: ContainerLifecycleSnapshotV2(state: .exited)
            )
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(states[id] != nil)
        #expect(recovered.intent.removalRequested)
        #expect(recovered.snapshot.state == .removing)
        #expect(recovered.snapshot.removalInProgress)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func staleAutoRemoveIntentIsReconciledFromCreationOptionsAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "stale-auto-remove"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try bundle.write(
            filename: "options.json",
            value: ContainerCreateOptions(autoRemove: false)
        )
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2(
                containerID: ContainerLifecycleRecordV2.migrate(
                    bundleKey: id,
                    canonicalName: id,
                    selectedProviderFingerprint: "container-runtime-linux",
                    legacy: nil
                ).containerID,
                canonicalName: id,
                immutableBundleKey: id,
                selectedProviderFingerprint: "container-runtime-linux",
                intent: ContainerLifecycleIntentV2(autoRemove: true),
                snapshot: ContainerLifecycleSnapshotV2(
                    state: .exited,
                    transitionRevision: 4,
                    operationGeneration: 5
                )
            )
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(!recovered.intent.autoRemove)
        #expect(!recovered.intent.removalRequested)
        #expect(recovered.snapshot.state == .exited)
        #expect(recovered.snapshot.transitionRevision == 5)
        #expect(recovered.snapshot.operationGeneration == 6)
        #expect(try bundle.lifecycleRecordV2 == recovered)
    }

    @Test
    func terminalLifecycleFlagsAreNormalizedAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "contradictory-terminal-flags"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2(
                containerID: ContainerLifecycleRecordV2.migrate(
                    bundleKey: id,
                    canonicalName: id,
                    selectedProviderFingerprint: "container-runtime-linux",
                    legacy: nil
                ).containerID,
                canonicalName: id,
                immutableBundleKey: id,
                selectedProviderFingerprint: "container-runtime-linux",
                snapshot: ContainerLifecycleSnapshotV2(
                    state: .exited,
                    running: true,
                    paused: true,
                    restarting: true,
                    removalInProgress: true,
                    dead: true,
                    pid: 42
                )
            )
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )
        let recovered = try #require(records[id])

        #expect(!recovered.snapshot.running)
        #expect(!recovered.snapshot.paused)
        #expect(!recovered.snapshot.restarting)
        #expect(!recovered.snapshot.removalInProgress)
        #expect(!recovered.snapshot.dead)
        #expect(recovered.snapshot.pid == 0)
        #expect(try bundle.lifecycleRecordV2 == recovered)
    }

    @Test
    func malformedLifecycleV2DoesNotTakeTheContainerAPIOffline() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let validID = "valid-lifecycle"
        let validPath = fixture.containers.appendingPathComponent(validID)
        try FileManager.default.createDirectory(at: validPath, withIntermediateDirectories: true)
        try ContainerResource.Bundle(path: validPath).set(configuration: testConfiguration(id: validID))

        let malformedID = "malformed-lifecycle-v2"
        let malformedPath = fixture.containers.appendingPathComponent(malformedID)
        try FileManager.default.createDirectory(at: malformedPath, withIntermediateDirectories: true)
        let malformedBundle = ContainerResource.Bundle(path: malformedPath)
        try malformedBundle.set(configuration: testConfiguration(id: malformedID))
        try Data("{".utf8).write(
            to: malformedBundle.filePath(for: ContainerResource.Bundle.lifecycleRecordV2Filename)
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )

        #expect(records[validID] != nil)
        #expect(records[malformedID] == nil)
        #expect(FileManager.default.fileExists(atPath: malformedPath.path))
        _ = try ContainersService(
            appRoot: fixture.root,
            pluginLoader: fixture.loader,
            containerSystemConfig: ContainerSystemConfig(),
            log: fixture.log
        )
    }

    @Test
    func lifecycleRecordBoundToAnotherBundleIsIsolatedAtBoot() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "local-bundle"
        let configuration = testConfiguration(id: id)
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: configuration)
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2.migrate(
                bundleKey: "foreign-bundle",
                canonicalName: id,
                selectedProviderFingerprint: configuration.runtimeHandler,
                legacy: nil
            )
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        let records = ContainersService.loadLifecycleRecords(
            containers: states,
            root: fixture.containers,
            log: fixture.log
        )

        #expect(records[id] == nil)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
        _ = try ContainersService(
            appRoot: fixture.root,
            pluginLoader: fixture.loader,
            containerSystemConfig: ContainerSystemConfig(),
            log: fixture.log
        )
    }

    @Test
    func lifecycleViewsPairResourceAndAuthorityIdentityFromOneServiceRevision() async throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "api-bundle"
        let dockerID = String(repeating: "a", count: 64)
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        var configuration = testConfiguration(id: id)
        configuration.dockerID = dockerID
        configuration.dockerName = "api-after-rename"
        try bundle.set(configuration: configuration)
        try bundle.setDurably(
            lifecycleRecordV2: ContainerLifecycleRecordV2(
                containerID: dockerID,
                canonicalName: "api-after-rename",
                immutableBundleKey: id,
                selectedProviderFingerprint: configuration.runtimeHandler,
                snapshot: ContainerLifecycleSnapshotV2(
                    state: .exited,
                    transitionRevision: 9
                )
            )
        )

        let service = try ContainersService(
            appRoot: fixture.root,
            pluginLoader: fixture.loader,
            containerSystemConfig: ContainerSystemConfig(),
            log: fixture.log
        )
        let views = try await service.lifecycleViewsForAPI(
            filters: ContainerListFilters(ids: [id])
        )

        let view = try #require(views.first)
        #expect(views.count == 1)
        #expect(view.container.id == id)
        #expect(view.container.configuration.dockerName == "api-after-rename")
        #expect(view.lifecycle.immutableBundleKey == id)
        #expect(view.lifecycle.containerID == dockerID)
        #expect(view.lifecycle.canonicalName == "api-after-rename")
        #expect(view.lifecycle.snapshot.state == .exited)
    }

    @Test
    func lifecycleEventsRetainTheRevisionThatCreatedThem() throws {
        let configuration = testConfiguration(id: "api")
        let snapshot = ContainerSnapshot(
            configuration: configuration,
            status: .stopped,
            networks: [],
            exitCode: 0
        )
        let lifecycle = ContainerLifecycleRecordV2(
            containerID: String(repeating: "b", count: 64),
            canonicalName: "api",
            immutableBundleKey: "api",
            selectedProviderFingerprint: "container-runtime-linux",
            snapshot: ContainerLifecycleSnapshotV2(
                state: .exited,
                transitionRevision: 11,
                operationGeneration: 12
            )
        )

        let events = ContainersService.stampEvents(
            ContainersService.terminalLifecycleEvents(snapshot: snapshot),
            with: lifecycle
        )

        #expect(events.allSatisfy { $0.transitionRevision == 11 })
        #expect(events.allSatisfy { $0.operationGeneration == 12 })
    }

    @Test
    func dockerLifecycleStateSurvivesAuthorityRestart() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "previously-run"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        let started = Date(timeIntervalSince1970: 1_234)
        let exited = Date(timeIntervalSince1970: 1_250)
        try bundle.setDurably(
            lifecycleState: ContainerLifecycleStateV1(
                startedDate: started,
                exitCode: 17,
                exitedDate: exited
            )
        )

        let state = try #require(
            ContainersService.loadAtBoot(
                root: fixture.containers,
                loader: fixture.loader,
                log: fixture.log
            )[id]
        )
        #expect(state.snapshot.status == .stopped)
        #expect(state.snapshot.startedDate == started)
        #expect(state.snapshot.exitCode == 17)
        #expect(state.snapshot.exitedDate == exited)
    }

    @Test
    func corruptLifecycleStateLeavesBundleOnDisk() throws {
        let fixture = try Fixture(includeRuntime: true)
        defer { fixture.remove() }

        let id = "corrupt-lifecycle"
        let bundlePath = fixture.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: bundlePath,
            withIntermediateDirectories: true
        )
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.set(configuration: testConfiguration(id: id))
        try Data("{".utf8).write(
            to: bundle.filePath(for: ContainerResource.Bundle.lifecycleStateFilename)
        )

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )
        #expect(states[id] == nil)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func malformedConfigurationFilesRemainOnDisk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let bundlePath = fixture.containers.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bundlePath.appendingPathComponent("config.json"))
        try Data("{".utf8).write(to: bundlePath.appendingPathComponent("runtime-configuration.json"))

        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log
        )

        #expect(states.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
    }

    @Test
    func missingRuntimeBundleRemainsOnDiskButIsNotLoaded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let bundlePath = fixture.containers.appendingPathComponent("missing-runtime")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        let bundle = ContainerResource.Bundle(path: bundlePath)
        var configuration = testConfiguration(id: "missing-runtime")
        configuration.dockerName = "reserved-missing-runtime"
        configuration.dockerID = String(repeating: "a", count: 64)
        try bundle.set(configuration: configuration)

        var deregisteredLabels = [String]()
        let states = try ContainersService.loadAtBoot(
            root: fixture.containers,
            loader: fixture.loader,
            log: fixture.log,
            deregisterService: { deregisteredLabels.append($0) }
        )

        #expect(states.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bundlePath.path))
        let recovered: ContainerConfiguration = try bundle.load(filename: "config.json")
        #expect(recovered.id == "missing-runtime")
        let reservedNames = try ContainersService.quarantinedContainerNamesAtBoot(
            root: fixture.containers,
            acceptedContainerIDs: []
        )
        #expect(reservedNames.contains("missing-runtime"))
        #expect(reservedNames.contains("reserved-missing-runtime"))
        #expect(reservedNames.contains(String(repeating: "a", count: 64)))
        #expect(deregisteredLabels.count == 1)
        #expect(
            deregisteredLabels[0].hasSuffix(
                ".container-runtime-linux.missing-runtime"
            )
        )
    }

    private func testConfiguration(id: String) -> ContainerConfiguration {
        let image = ImageDescription(
            reference: "docker.io/library/alpine:latest",
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
        return ContainerConfiguration(id: id, image: image, process: process)
    }
}

private struct Fixture {
    let root: URL
    let containers: URL
    let loader: PluginLoader
    let log = Logger(label: "ContainerLoadAtBootTests")

    init(includeRuntime: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        containers = root.appendingPathComponent("containers")
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        let pluginRoot = root.appendingPathComponent("plugins")
        if includeRuntime {
            try FileManager.default.createDirectory(
                at: pluginRoot.appendingPathComponent("container-runtime-linux"),
                withIntermediateDirectories: true
            )
        }
        loader = try PluginLoader(
            appRoot: root,
            installRoot: root,
            logRoot: nil,
            pluginDirectories: includeRuntime ? [pluginRoot] : [],
            pluginFactories: includeRuntime
                ? [LifecycleRuntimePluginFactory()]
                : []
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LifecycleRuntimePluginFactory: PluginFactory {
    func create(installURL: URL) throws -> Plugin? {
        guard installURL.lastPathComponent == "container-runtime-linux" else {
            return nil
        }
        let services = PluginConfig.ServicesConfig(
            loadAtBoot: false,
            runAtLoad: false,
            services: [
                PluginConfig.Service(type: .runtime, description: nil)
            ],
            defaultArguments: []
        )
        return Plugin(
            binaryURL: installURL.appendingPathComponent(
                "container-runtime-linux"
            ),
            config: PluginConfig(
                abstract: "runtime",
                author: nil,
                servicesConfig: services
            )
        )
    }

    func create(parentURL: URL, name: String) throws -> Plugin? {
        try create(installURL: parentURL.appendingPathComponent(name))
    }
}
