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

/// XPC routes exposed by the runtime service.
public enum RuntimeRoutes: String {
    // MARK: - Service lifecycle

    /// Create an XPC endpoint for communicating with the runtime service.
    case createEndpoint = "com.apple.container.runtime/createEndpoint"
    /// Shut down the runtime service process. Requires the sandbox to be stopped first.
    case shutdown = "com.apple.container.runtime/shutdown"

    // MARK: - Sandbox lifecycle

    /// Bootstrap the sandbox: create the VM, configure networks, and boot the guest.
    case bootstrap = "com.apple.container.runtime/bootstrap"
    /// Stop the sandbox and all processes running inside it.
    case stop = "com.apple.container.runtime/stop"
    /// Pause the sandbox without terminating its processes.
    case pause = "com.apple.container.runtime/pause"
    /// Resume a paused sandbox.
    case resume = "com.apple.container.runtime/resume"
    /// Request a live workload-memory target for the sandbox.
    case setMemoryTarget = "com.apple.container.runtime/setMemoryTarget"
    /// Return the current state of the sandbox.
    case state = "com.apple.container.runtime/state"
    /// Get resource usage statistics for the sandbox.
    case statistics = "com.apple.container.runtime/statistics"
    /// Get process identifiers for the sandbox.
    case processes = "com.apple.container.runtime/processes"
    /// Open a vsock connection to a port inside the sandbox.
    case dial = "com.apple.container.runtime/dial"

    // MARK: - Shared Engine Linux sandbox

    /// Boot the single Engine-owned Linux sandbox for an exact generation.
    case engineSandboxBoot = "com.apple.container.runtime/engineSandbox/boot"
    /// Observe an exact sandbox boot after an interrupted response.
    case engineSandboxObserveBoot = "com.apple.container.runtime/engineSandbox/observeBoot"
    /// Stop the Engine-owned Linux sandbox for an exact generation.
    case engineSandboxShutdown = "com.apple.container.runtime/engineSandbox/shutdown"
    /// Observe an exact sandbox shutdown after an interrupted response.
    case engineSandboxObserveShutdown = "com.apple.container.runtime/engineSandbox/observeShutdown"
    /// Materialize and start one workload in the Engine-owned Linux sandbox.
    case engineSandboxStartWorkload = "com.apple.container.runtime/engineSandbox/startWorkload"
    /// Observe an exact workload start after an interrupted response.
    case engineSandboxObserveWorkloadStart = "com.apple.container.runtime/engineSandbox/observeWorkloadStart"
    /// Stop one exact workload generation in the Engine-owned Linux sandbox.
    case engineSandboxStopWorkload = "com.apple.container.runtime/engineSandbox/stopWorkload"
    /// Observe an exact workload stop after an interrupted response.
    case engineSandboxObserveWorkloadStop = "com.apple.container.runtime/engineSandbox/observeWorkloadStop"
    /// Control one exact active workload generation without affecting peers.
    case engineSandboxControlWorkload = "com.apple.container.runtime/engineSandbox/controlWorkload"
    /// Open a generation-fenced connection to a protected sandbox service.
    case engineSandboxDialService = "com.apple.container.runtime/engineSandbox/dialService"

    // MARK: - Process management

    /// Register a new process inside the sandbox (used by exec).
    case createProcess = "com.apple.container.runtime/createProcess"
    /// Start a registered process inside the sandbox.
    case start = "com.apple.container.runtime/start"
    /// Send a signal to a process inside the sandbox.
    case kill = "com.apple.container.runtime/kill"
    /// Resize the PTY of a process inside the sandbox.
    case resize = "com.apple.container.runtime/resize"
    /// Wait for a process inside the sandbox to exit.
    case wait = "com.apple.container.runtime/wait"
    /// Execute a new process in the sandbox.
    case exec = "com.apple.container.runtime/exec"
    /// Attach standard streams to the already-running init process.
    case attach = "com.apple.container.runtime/attach"
    /// Follow raw records from the retained active logging generation.
    case followLogs = "com.apple.container.runtime/followLogs"
    /// Follow structured records from the retained active logging generation.
    case followLogRecords = "com.apple.container.runtime/followLogRecords"
    /// Follow exact versioned read records from the active logging generation.
    case followLogReadRecordsV1 = "com.apple.container.runtime/followLogReadRecordsV1"

    // MARK: - File Management
    /// Copy a file or directory into the container.
    case copyIn = "com.apple.container.runtime/copyIn"
    /// Copy a file or directory out of the container.
    case copyOut = "com.apple.container.runtime/copyOut"
    /// Snapshot the container's root filesystem to an image file.
    case snapshotDisk = "com.apple.container.runtime/snapshotDisk"
    /// Clean up unused space in the container filesystem.
    case clean = "com.apple.container.runtime/clean"
}
