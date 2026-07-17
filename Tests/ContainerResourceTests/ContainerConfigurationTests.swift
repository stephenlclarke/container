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

import Foundation
import Testing

@testable import ContainerResource

// Shared fixture (reused by later tasks' tests). If an initializer is rejected,
// correct it against Sources/ContainerResource/Image/ImageDescription.swift and
// Sources/ContainerResource/Container/ProcessConfiguration.swift.
func makeTestConfiguration(
    id: String = "test-ctr",
    labels: [String: String] = [:],
    creationDate: Date? = nil
) -> ContainerConfiguration {
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
    var config = ContainerConfiguration(id: id, image: image, process: process)
    config.labels = labels
    if let creationDate { config.creationDate = creationDate }
    return config
}

struct ContainerConfigurationResourcesTests {
    @Test func roundTripsCpuOverhead() throws {
        var config = makeTestConfiguration()
        config.resources.cpuOverhead = 2
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.resources.cpuOverhead == 2)
    }

    @Test func decodesMissingCpuOverheadAsDefault() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var resources = try #require(obj["resources"] as? [String: Any])
        resources.removeValue(forKey: "cpuOverhead")
        obj["resources"] = resources
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.resources.cpuOverhead == 1)
    }
}

struct ContainerConfigurationPIDNamespaceTests {
    @Test func roundTripsHostPIDNamespace() throws {
        var config = makeTestConfiguration()
        config.hostPIDNamespace = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.hostPIDNamespace)
    }

    @Test func decodesMissingHostPIDNamespaceAsFalse() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "hostPIDNamespace")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(!decoded.hostPIDNamespace)
    }
}

struct ContainerConfigurationHostNetworkTests {
    @Test func roundTripsHostNetwork() throws {
        var config = makeTestConfiguration()
        config.hostNetwork = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.hostNetwork)
    }

    @Test func decodesMissingHostNetworkAsFalse() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "hostNetwork")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(!decoded.hostNetwork)
    }
}

struct ProcessConfigurationPrivilegeTests {
    @Test func roundTripsOOMScoreAdjustment() throws {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            oomScoreAdj: -250
        )

        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: JSONEncoder().encode(process))

        #expect(decoded.oomScoreAdj == -250)
    }

    @Test func decodesMissingOOMScoreAdjustmentAsNil() throws {
        let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        let data = try JSONEncoder().encode(process)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "oomScoreAdj")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: stripped)

        #expect(decoded.oomScoreAdj == nil)
    }

    @Test func roundTripsNamedSupplementalGroups() throws {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: [],
            supplementalGroups: [1000],
            supplementalGroupNames: ["staff", "docker"]
        )

        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: JSONEncoder().encode(process))

        #expect(decoded.supplementalGroups == [1000])
        #expect(decoded.supplementalGroupNames == ["staff", "docker"])
    }

    @Test func decodesMissingNamedSupplementalGroupsAsEmpty() throws {
        let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        let data = try JSONEncoder().encode(process)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "supplementalGroupNames")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: stripped)

        #expect(decoded.supplementalGroupNames.isEmpty)
    }

    @Test func roundTripsPrivilegedProcessConfiguration() throws {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "id"],
            environment: ["PATH=/usr/bin"],
            privileged: true
        )

        let data = try JSONEncoder().encode(process)
        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: data)

        #expect(decoded.privileged)
    }

    @Test func decodesMissingPrivilegedProcessConfigurationAsFalse() throws {
        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: [],
            environment: []
        )
        let data = try JSONEncoder().encode(process)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "privileged")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ProcessConfiguration.self, from: stripped)

        #expect(!decoded.privileged)
    }
}

struct ContainerConfigurationLoggingTests {
    @Test func roundTripsLoggingConfiguration() throws {
        var config = makeTestConfiguration()
        config.logging = ContainerLogConfiguration(
            storage: .none,
            maxSizeInBytes: 10 * 1024 * 1024,
            maxFileCount: 5
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.logging == config.logging)
        #expect(decoded.logging.storage == .none)
    }

    @Test func decodesMissingLoggingConfigurationAsDefault() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "logging")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(decoded.logging == .default)
    }
}

struct ContainerConfigurationHealthCheckTests {
    @Test func roundTripsHealthCheckConfiguration() throws {
        var config = makeTestConfiguration()
        config.healthCheck = ContainerHealthCheck(
            process: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "test -f /tmp/ready"],
                environment: ["CHECK=1"]
            ),
            intervalInNanoseconds: 5_000_000_000,
            timeoutInNanoseconds: 1_000_000_000,
            startPeriodInNanoseconds: 10_000_000_000,
            startIntervalInNanoseconds: 500_000_000,
            retries: 5
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        let healthCheck = try #require(decoded.healthCheck)

        #expect(healthCheck.process.executable == "/bin/sh")
        #expect(healthCheck.process.arguments == ["-c", "test -f /tmp/ready"])
        #expect(healthCheck.process.environment == ["CHECK=1"])
        #expect(healthCheck.intervalInNanoseconds == 5_000_000_000)
        #expect(healthCheck.timeoutInNanoseconds == 1_000_000_000)
        #expect(healthCheck.startPeriodInNanoseconds == 10_000_000_000)
        #expect(healthCheck.startIntervalInNanoseconds == 500_000_000)
        #expect(healthCheck.retries == 5)
    }

    @Test func decodesMissingHealthCheckAsNil() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "healthCheck")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(decoded.healthCheck == nil)
    }
}

struct ContainerConfigurationHostEntryTests {
    @Test func roundTripsHostEntries() throws {
        var config = makeTestConfiguration()
        config.hosts = [
            .init(ipAddress: "192.168.64.1", hostnames: ["host.docker.internal"]),
            .init(ipAddress: "10.0.0.15", hostnames: ["db", "db.internal"]),
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.hosts == config.hosts)
    }

    @Test func decodesMissingHostEntriesAsEmpty() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "hosts")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(decoded.hosts.isEmpty)
    }

    @Test func hostGatewayEntryIdentifiesRuntimeResolution() {
        let entry = ContainerConfiguration.HostEntry(
            ipAddress: ContainerConfiguration.HostEntry.hostGatewayAddress,
            hostnames: ["host.docker.internal"]
        )

        #expect(entry.requiresHostGateway)
    }
}

struct ContainerConfigurationHostnameTests {
    @Test func roundTripsHostname() throws {
        var config = makeTestConfiguration()
        config.hostname = "api-01"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.hostname == "api-01")
    }

    @Test func decodesMissingHostnameAsNil() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "hostname")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(decoded.hostname == nil)
    }
}

struct ContainerConfigurationDomainnameTests {
    @Test func roundTripsDomainname() throws {
        var config = makeTestConfiguration()
        config.domainname = "example.test"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)

        #expect(decoded.domainname == "example.test")
    }

    @Test func decodesMissingDomainnameAsNil() throws {
        let config = makeTestConfiguration()
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "domainname")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)

        #expect(decoded.domainname == nil)
    }
}

struct ContainerConfigurationCreationDateTests {
    @Test func roundTripsCreationDate() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let config = makeTestConfiguration(creationDate: when)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.creationDate == when)
    }

    @Test func decodesMissingCreationDateAsEpoch() throws {
        let config = makeTestConfiguration(creationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(config)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "creationDate")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: stripped)
        #expect(decoded.creationDate == Date(timeIntervalSince1970: 0))
    }
}
