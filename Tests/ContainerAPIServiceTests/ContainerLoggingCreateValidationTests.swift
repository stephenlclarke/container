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

import ContainerEngineLogging
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIService

struct ContainerLoggingCreateValidationTests {
    @Test(arguments: ["unix", "unixgram"])
    func dockerCreateRejectsMissingUnixSyslogSocketBeforeAuthorityPersistence(
        scheme: String
    ) throws {
        let path = "/private/tmp/container-missing-syslog-\(UUID().uuidString).sock"
        let request = try JSONDecoder().decode(
            DockerContainerCreateRequest.self,
            from: Data(
                """
                {
                  "Image": "alpine:3.20",
                  "HostConfig": {
                    "LogConfig": {
                      "Type": "syslog",
                      "Config": {"syslog-address": "\(scheme)://\(path)"}
                    }
                  }
                }
                """.utf8
            )
        )

        let error = #expect(throws: DockerLoggingBackendError.self) {
            try ContainerDockerLoggingBackend.validateDockerSyslogUnixSocket(
                request,
                fileExists: { _ in false }
            )
        }
        #expect(
            error
                == .server(
                    "failed to create task for container: failed to initialize logging driver: stat \(path): no such file or directory"
                )
        )
    }

    @Test func legacyLoggingRemainsAcceptedAtCreateBoundary() throws {
        let expected = ContainerLogConfiguration(
            storage: .none,
            maxSizeInBytes: 4096,
            maxFileCount: 7
        )
        let plan = try ContainersService.prepareLoggingForCreate(
            configuration: expected,
            request: nil,
            defaults: LoggingConfig()
        )

        guard case .legacy(let actual) = plan else {
            Issue.record("legacy create produced a logging-v2 plan")
            return
        }
        #expect(actual == expected)
    }

    @Test func requestOmissionRejectsInjectedResolvedState() throws {
        let resolved = try ResolvedContainerLogConfiguration(
            leaseGeneration: 1,
            driver: "json-file",
            delivery: try LogDeliveryConfiguration(),
            readPolicy: LogReadPolicy(source: .direct),
            providerIdentity: BuiltinLogDriverDescriptors.coreProvider,
            providerGenerationAtResolution: 1,
            contractDigest: "sha256:contract"
        )
        let logging = try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: "json-file"),
            resolved: resolved
        )

        let error = #expect(throws: ContainerizationError.self) {
            _ = try ContainersService.prepareLoggingForCreate(
                configuration: logging,
                request: nil,
                defaults: LoggingConfig()
            )
        }
        #expect(error?.code == .invalidArgument)
        #expect(error?.message == "authority-resolved logging configuration requires a structured logging request")
    }

    @Test func structuredRequestIsAuthoritativeOverLegacyConfiguration() throws {
        let request = ContainerLogRequest(
            driver: "local",
            options: ["max-file": "7", "max-size": "8m"]
        )
        let plan = try ContainersService.prepareLoggingForCreate(
            configuration: ContainerLogConfiguration(
                storage: .none,
                maxSizeInBytes: 1,
                maxFileCount: 1
            ),
            request: request,
            defaults: LoggingConfig(driver: "json-file", options: ["max-file": "2"])
        )

        guard case .version2(let prepared) = plan else {
            Issue.record("structured request produced a legacy logging plan")
            return
        }
        #expect(prepared.requestedDriver == "local")
        #expect(prepared.descriptor.driver == "local")
        #expect(prepared.safeOptions == ["max-file": "7", "max-size": "8m"])
    }

    @Test func invalidStructuredRequestWinsBeforeLegacyFieldValidationAndRedactsValues() throws {
        let protectedValue = "DO_NOT_EXPOSE_THIS_VALUE"
        do {
            _ = try ContainersService.prepareLoggingForCreate(
                configuration: try injectedV2Configuration(),
                request: ContainerLogRequest(
                    driver: "json-file",
                    options: ["unknown-option": protectedValue]
                ),
                defaults: LoggingConfig()
            )
            Issue.record("invalid structured request was accepted")
        } catch {
            let mapped = ContainersService.mapLoggingCreateError(error)
            #expect(mapped.code == .invalidArgument)
            #expect(mapped.message.contains("unknown-option"))
            #expect(!mapped.message.contains(protectedValue))
        }
    }

    private func injectedV2Configuration() throws -> ContainerLogConfiguration {
        let descriptor = try #require(BuiltinLogDriverDescriptors.current.descriptor(named: "none"))
        return try ContainerLogConfiguration(
            requested: ContainerLogRequest(driver: "none"),
            resolved: ResolvedContainerLogConfiguration(
                leaseGeneration: 1,
                driver: descriptor.driver,
                delivery: try LogDeliveryConfiguration(),
                readPolicy: LogReadPolicy(source: .unavailable),
                providerIdentity: descriptor.providerIdentity,
                providerGenerationAtResolution: descriptor.providerGeneration,
                contractDigest: descriptor.optionContractDigest
            )
        )
    }
}
