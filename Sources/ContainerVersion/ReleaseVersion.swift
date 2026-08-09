//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import CVersion
import Foundation

public struct ReleaseVersion {
    public static func singleLine(appName: String) -> String {
        var versionDetails: [String: String] = ["build": buildType()]
        versionDetails["commit"] = gitCommit().map { String($0.prefix(7)) } ?? "unspecified"
        versionDetails["containerization"] = "\(containerizationSource())@\(containerizationRef())"
        versionDetails["vminit"] = vminitImage()
        versionDetails["distribution"] = distribution()
        versionDetails["source"] = containerSource()
        versionDetails["builder-shim"] = builderShimImage()
        let extras: String = versionDetails.map { "\($0): \($1)" }.sorted().joined(separator: ", ")

        return "\(appName) version \(version()) (\(extras))"
    }

    public static func provenanceLines(indent: String = "  ") -> [String] {
        [
            "\(indent)distribution: \(distribution())",
            "\(indent)source: \(containerSource())",
            "\(indent)containerization: \(containerizationSource())@\(containerizationRef())",
            "\(indent)vminit: \(vminitImage())",
            "\(indent)container-builder-shim: \(builderShimImage())",
        ]
    }

    public static func distribution() -> String {
        if containerSource() == "apple/container",
            containerizationSource() == "apple/containerization"
        {
            return "apple"
        }
        return "custom"
    }

    public static func buildType() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    public static func version() -> String {
        let appBundle = Bundle.appBundle(executablePath: CommandLine.executablePath)
        let bundleVersion = appBundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        return bundleVersion ?? get_release_version().map { String(cString: $0) } ?? "0.0.0"
    }

    public static func gitCommit() -> String? {
        get_git_commit().map { String(cString: $0) }
    }

    public static func containerSource() -> String {
        get_container_source().map { String(cString: $0) } ?? "apple/container"
    }

    public static func containerizationSource() -> String {
        get_containerization_source().map { String(cString: $0) } ?? "apple/containerization"
    }

    public static func containerizationRef() -> String {
        get_containerization_ref().map { String(cString: $0) } ?? version()
    }

    public static func containerEngineAPIVersion() -> String {
        get_container_engine_api_version().map { String(cString: $0) }
            ?? "unknown"
    }

    public static func vminitImage() -> String {
        vminitImage(
            containerizationSource: containerizationSource(),
            containerizationRef: containerizationRef(),
            upstreamVersion: String(cString: get_swift_containerization_version())
        )
    }

    package static func vminitImage(
        containerizationSource: String,
        containerizationRef: String,
        upstreamVersion: String
    ) -> String {
        let normalizedSource = containerizationSource.lowercased()
        guard normalizedSource != "apple/containerization" else {
            return upstreamVersion == "latest"
                ? "vminit:latest"
                : "ghcr.io/apple/containerization/vminit:\(upstreamVersion)"
        }
        let sourceParts = containerizationSource.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let safeSource =
            sourceParts.count == 2
            && sourceParts.allSatisfy { part in
                !part.isEmpty && part.utf8.allSatisfy(Self.isImagePathByte)
            }
        let safeRevision =
            (containerizationRef.utf8.count == 40
                || containerizationRef.utf8.count == 64)
            && containerizationRef.utf8.allSatisfy(Self.isHexByte)
        guard safeSource, safeRevision else {
            return "vminit:latest"
        }
        return "ghcr.io/\(normalizedSource)/vminit:\(containerizationRef.lowercased())"
    }

    private static func isImagePathByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    public static func builderShimRepository() -> String {
        get_container_builder_shim_repository().map { String(cString: $0) } ?? "ghcr.io/apple/container-builder-shim/builder"
    }

    public static func builderShimVersion() -> String {
        get_container_builder_shim_version().map { String(cString: $0) } ?? "0.0.0"
    }

    public static func builderShimDigest() -> String {
        get_container_builder_shim_digest().map { String(cString: $0) } ?? ""
    }

    public static func builderShimImage() -> String {
        let digest = builderShimDigest()
        if !digest.isEmpty {
            return "\(builderShimRepository())@\(digest)"
        }
        return "\(builderShimRepository()):\(builderShimVersion())"
    }
}
