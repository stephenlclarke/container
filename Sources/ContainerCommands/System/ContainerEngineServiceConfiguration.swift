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

import ContainerPlugin
import ContainerXPC
import ContainerizationError
import Darwin
import Foundation
import SystemPackage

struct ContainerEngineServiceConfiguration: Equatable, Sendable {
    static let defaultLaunchdLabel = ContainerServiceNamespace.defaultEngineLaunchdLabel

    let launchdLabel: String
    let publicSocketPath: FilePath
    let providerSocketPath: FilePath
    let stateDirectory: FilePath
    let plistPath: FilePath

    init(
        appRoot: FilePath,
        serviceNamespace: ContainerServiceNamespace = .current,
        effectiveUserID: uid_t = geteuid()
    ) {
        launchdLabel = serviceNamespace.engineLaunchdLabel
        publicSocketPath = FilePath(
            serviceNamespace.enginePublicSocketPath(
                effectiveUserID: UInt32(effectiveUserID)
            )
        )
        providerSocketPath =
            appRoot
            .appending(FilePath.Component("engine-provider"))
            .appending(FilePath.Component("provider.sock"))
        stateDirectory = appRoot.appending(
            FilePath.Component("engine-gateway")
        )
        plistPath = stateDirectory.appending(
            FilePath.Component("container-engine.plist")
        )
    }

    func arguments(executablePath: FilePath) -> [String] {
        [
            executablePath.string,
            "--socket", publicSocketPath.string,
            "--provider-socket", providerSocketPath.string,
            "--state-directory", stateDirectory.string,
        ]
    }

    func writeLaunchPlist(_ plist: LaunchPlist) throws {
        let directoryURL = URL(fileURLWithPath: stateDirectory.string)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directoryStatus = stat()
        guard
            lstat(stateDirectory.string, &directoryStatus) == 0,
            directoryStatus.st_uid == geteuid(),
            directoryStatus.st_mode & S_IFMT == S_IFDIR,
            chmod(stateDirectory.string, S_IRWXU) == 0
        else {
            throw ContainerizationError(
                .invalidState,
                message: "unsafe Container Engine state directory \(stateDirectory.string)"
            )
        }

        let plistURL = URL(fileURLWithPath: plistPath.string)
        try plist.encode().write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plistPath.string
        )
        var plistStatus = stat()
        guard
            lstat(plistPath.string, &plistStatus) == 0,
            plistStatus.st_uid == geteuid(),
            plistStatus.st_mode & S_IFMT == S_IFREG,
            plistStatus.st_mode & (S_IRWXG | S_IRWXO) == 0,
            plistStatus.st_nlink == 1
        else {
            throw ContainerizationError(
                .invalidState,
                message: "unsafe Container Engine launchd plist \(plistPath.string)"
            )
        }
    }

    func deregister() throws {
        let domain = try ServiceManager.getDomainString()
        let fullLabel = "\(domain)/\(launchdLabel)"
        var status: Int32 = 0
        try ServiceManager.deregister(
            fullServiceLabel: fullLabel,
            status: &status
        )
        guard status == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "command `launchctl bootout \(fullLabel)` failed with status \(status)"
            )
        }
    }
}
