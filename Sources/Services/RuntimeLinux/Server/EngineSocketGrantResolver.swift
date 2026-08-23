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

import ContainerEngineRuntimeSPI
import ContainerXPC
import Containerization
import ContainerizationError
import CryptoKit
import Darwin
import Foundation
import SystemPackage

enum EngineSocketGrantResolver {
    // Docker Compose 5.4.0 on the pinned Colima Docker 29.2.1 oracle exposes
    // the projected socket as root:991 with mode 0660. A non-root process that
    // is not a member of group 991 receives EACCES.
    static let guestMode = FilePermissions(rawValue: 0o660)
    static let guestOwnership = UnixSocketOwnership(uid: 0, gid: 991)

    static func resolve(
        _ intent: InboundUnixSocketIntentV1,
        containerID: String,
        serviceNamespace: ContainerServiceNamespace = .current,
        effectiveUserID: uid_t = geteuid()
    ) throws -> UnixSocketConfiguration {
        let sourcePath = serviceNamespace.enginePublicSocketPath(
            effectiveUserID: UInt32(effectiveUserID)
        )
        var sourceStatus = stat()
        guard lstat(sourcePath, &sourceStatus) == 0 else {
            throw ContainerizationError(
                .notFound,
                message: "selected Container Engine socket is unavailable"
            )
        }
        try validateSourceIdentity(
            mode: sourceStatus.st_mode,
            owner: sourceStatus.st_uid,
            effectiveUserID: effectiveUserID
        )

        return try configuration(
            intent,
            containerID: containerID,
            serviceNamespace: serviceNamespace,
            source: URL(filePath: sourcePath)
        )
    }

    static func validateSourceIdentity(
        mode: mode_t,
        owner: uid_t,
        effectiveUserID: uid_t
    ) throws {
        guard mode & S_IFMT == S_IFSOCK, owner == effectiveUserID else {
            throw ContainerizationError(
                .invalidState,
                message: "selected Container Engine socket has unsafe identity"
            )
        }
    }

    static func configuration(
        _ intent: InboundUnixSocketIntentV1,
        containerID: String,
        serviceNamespace: ContainerServiceNamespace,
        source: URL
    ) throws -> UnixSocketConfiguration {
        guard intent.kind == .engineAPI,
            intent.target.value == InboundUnixSocketIntentV1.dockerSocketPath,
            intent.inspectSource == InboundUnixSocketIntentV1.dockerSocketPath
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid Container Engine socket intent"
            )
        }

        let identity = [
            serviceNamespace.value,
            containerID,
            intent.kind.rawValue,
            intent.target.value,
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()

        return UnixSocketConfiguration(
            id: "engine-api-\(digest)",
            source: source,
            destination: URL(filePath: intent.target.value),
            permissions: guestMode,
            guestOwnership: guestOwnership,
            direction: .into
        )
    }
}
