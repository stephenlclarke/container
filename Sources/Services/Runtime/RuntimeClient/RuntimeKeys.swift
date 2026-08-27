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

public enum RuntimeKeys: String {
    /// ID key.
    case id
    /// Vsock port number key.
    case port
    /// Exit code for a process
    case exitCode
    /// Exit timestamp for a process
    case exitedAt
    /// FD to a container resource key.
    case fd
    /// Options for stopping a container key.
    case stopOptions
    /// An endpoint to talk to the runtime service.
    case runtimeServiceEndpoint

    /// Process request keys.
    case signal
    case snapshot
    case stdin
    case stdout
    case stderr
    case width
    case height
    case processConfig
    /// Validated request for the retained active logging reader.
    case logReadRequest

    /// Container statistics
    case statistics
    /// Container process information
    case processes

    /// Copy parameters
    case sourcePath
    case destinationPath
    case fileMode
    case createParents
    case followSymlink
    case preserveOwnership
    case copyArchive
    case copyContents
    /// Image path for snapshot operations
    case imagePath
    /// Whether a live snapshot should avoid freezing the guest filesystem.
    case noFreeze

    /// Special-case environment variables recomputed on each container start
    case dynamicEnv

    /// Whether bootstrap is preparing a dedicated runtime before its first
    /// client-owned standard streams arrive.
    case prewarming

    /// Whether the first foreground client has no stdin and the deferred
    /// prewarming relay must therefore receive end-of-file.
    case closeStdin

    /// Per-network connection info passed to the runtime so it can allocate directly.
    case networkBootstrapInfos

    /// Codable request or response for the Engine-owned shared sandbox.
    case engineSandboxPayload
}
