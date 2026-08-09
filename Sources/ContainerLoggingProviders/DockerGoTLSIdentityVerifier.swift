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

import Darwin
import NIOSSL

/// Docker Engine 29.2.1's modern-Go TLS identity rules shared by remote log
/// drivers. The TLS stack must still perform chain validation; this verifier
/// applies the requested DNS/IP identity to SANs after the handshake.
public enum DockerGoTLSIdentityVerifier {
    /// Returns the SNI value modern Go sends. Literal IP addresses, including
    /// bracketed or scoped IPv6 literals, deliberately send no SNI.
    public static func serverHostname(for requestedIdentity: String) -> String? {
        guard !requestedIdentity.isEmpty else {
            return nil
        }
        var identity = unbracketed(requestedIdentity)
        if let scope = identity.firstIndex(of: "%") {
            identity = String(identity[..<scope])
        }
        guard ipAddressBytes(identity) == nil else {
            return nil
        }
        return requestedIdentity
    }

    /// Matches IP literals only against IP SANs and DNS names only against DNS
    /// SANs. Common Name fallback is intentionally not supported.
    public static func matches(
        _ requestedIdentity: String,
        certificate: NIOSSLCertificate
    ) -> Bool {
        let identity = unbracketed(requestedIdentity)
        if let address = ipAddressBytes(identity) {
            return certificate._subjectAlternativeNames().contains { name in
                name.nameType == .ipAddress && Array(name.contents) == address
            }
        }

        let candidate = lowercaseASCII(Array(requestedIdentity.utf8))
        let validCandidate = validHostname(candidate, isPattern: false)
        let candidateParts = splitHostname(candidate)
        for name in certificate._subjectAlternativeNames()
        where name.nameType == .dnsName {
            let pattern = Array(name.contents)
            if validCandidate, validHostname(pattern, isPattern: true) {
                if wildcardMatch(
                    pattern: lowercaseASCII(pattern),
                    candidateParts: candidateParts
                ) {
                    return true
                }
            } else if exactMatch(pattern, candidate) {
                return true
            }
        }
        return false
    }

    private static func unbracketed(_ identity: String) -> String {
        if identity.first == "[",
            identity.last == "]",
            identity.count >= 3
        {
            return String(identity.dropFirst().dropLast())
        }
        return identity
    }

    private static func ipAddressBytes(_ value: String) -> [UInt8]? {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: &ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: &ipv6) { Array($0) }
        }
        return nil
    }

    private static func validHostname(
        _ bytes: [UInt8],
        isPattern: Bool
    ) -> Bool {
        var value = bytes[...]
        if !isPattern, value.last == UInt8(ascii: ".") {
            value = value.dropLast()
        }
        guard !value.isEmpty, value != [UInt8(ascii: "*")][...] else {
            return false
        }
        let labels = value.split(
            separator: UInt8(ascii: "."),
            omittingEmptySubsequences: false
        )
        for (labelIndex, label) in labels.enumerated() {
            guard !label.isEmpty else {
                return false
            }
            if isPattern,
                labelIndex == 0,
                label.elementsEqual([UInt8(ascii: "*")])
            {
                continue
            }
            for (index, byte) in label.enumerated() {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"),
                    UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
                    continue
                case UInt8(ascii: "-") where index != 0:
                    continue
                default:
                    return false
                }
            }
        }
        return true
    }

    private static func splitHostname(_ value: [UInt8]) -> [[UInt8]] {
        let trimmed =
            value.last == UInt8(ascii: ".") ? value.dropLast() : value[...]
        return trimmed.split(
            separator: UInt8(ascii: "."),
            omittingEmptySubsequences: false
        ).map(Array.init)
    }

    private static func wildcardMatch(
        pattern: [UInt8],
        candidateParts: [[UInt8]]
    ) -> Bool {
        let patternParts = pattern.split(
            separator: UInt8(ascii: "."),
            omittingEmptySubsequences: false
        )
        guard patternParts.count == candidateParts.count else {
            return false
        }
        for index in patternParts.indices {
            if index == 0,
                patternParts[index].elementsEqual([UInt8(ascii: "*")])
            {
                continue
            }
            guard patternParts[index].elementsEqual(candidateParts[index]) else {
                return false
            }
        }
        return true
    }

    private static func exactMatch(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard
            !lhs.isEmpty,
            lhs != [UInt8(ascii: ".")],
            !rhs.isEmpty,
            rhs != [UInt8(ascii: ".")]
        else {
            return false
        }
        return lowercaseASCII(lhs) == lowercaseASCII(rhs)
    }

    private static func lowercaseASCII(_ value: [UInt8]) -> [UInt8] {
        value.map { byte in
            if (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) {
                return byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
            }
            return byte
        }
    }
}
