//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerLoggingProviders
import Testing

@testable import ContainerAPIService

struct ContainerLoggingStartErrorTests {
    @Test func mapsDeferredLocalCompressionFailureToDockerDiagnostic() {
        let reason = "compression cannot be enabled when max file count is 1"
        let mapped = ContainersService.mapLoggingStartError(
            ContainerLogResolutionError.invalidOption(
                driver: "local",
                name: "compress",
                reason: reason
            )
        )

        #expect(mapped.code == .invalidState)
        #expect(mapped.message == "failed to initialize logging driver: \(reason)")
    }

    @Test func preservesTheGenericStartValidationDiagnosticForOtherOptions() {
        let mapped = ContainersService.mapLoggingStartError(
            ContainerLogResolutionError.invalidOption(
                driver: "json-file",
                name: "compress",
                reason: "compress cannot be true when max-file is less than 2 or max-size is not set"
            )
        )

        #expect(
            mapped.message
                == "container logging configuration is not valid for start: invalid log option \"compress\" for driver \"json-file\": compress cannot be true when max-file is less than 2 or max-size is not set"
        )
    }

    @Test func mapsGELFTCPConnectionFailureToDockerDiagnostic() {
        let mapped = ContainerDockerLoggingBackend.map(
            GELFProviderError.connectionFailed(
                endpoint: GELFNetworkAddress(
                    host: "host.docker.internal",
                    port: "12201"
                ),
                reason: "connection refused"
            ),
            containerID: "gelf-container"
        )

        #expect(
            mapped
                == .server(
                    "failed to create task for container: failed to initialize logging driver: gelf: cannot connect to GELF endpoint: host.docker.internal:12201 connection refused"
                )
        )
    }

    @Test func mapsGELFTCPServiceBootstrapFailureToDockerDiagnostic() {
        let mapped = ContainerDockerLoggingBackend.map(
            GELFProviderError.connectionFailed(
                endpoint: GELFNetworkAddress(
                    host: "host.docker.internal",
                    port: "12201"
                ),
                reason: "Engine-Linux GELF TCP service readiness timed out"
            ),
            containerID: "gelf-container"
        )

        #expect(
            mapped
                == .server(
                    "failed to create task for container: failed to initialize logging driver: gelf: cannot connect to GELF endpoint: host.docker.internal:12201 Engine-Linux GELF TCP service readiness timed out"
                )
        )
    }

    @Test func mapsFluentdTLSTrustFailureToDockerDiagnostic() {
        let mapped = ContainerDockerLoggingBackend.map(
            FluentdProviderError.tlsTrustVerificationFailed,
            containerID: "fluentd-container"
        )

        #expect(
            mapped
                == .server(
                    "failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority"
                )
        )
    }

    @Test func mapsSyslogTLSTrustFailureToDockerDiagnostic() {
        let mapped = ContainerDockerLoggingBackend.map(
            SyslogProviderError.tlsTrustVerificationFailed,
            containerID: "syslog-container"
        )

        #expect(
            mapped
                == .server(
                    "failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority"
                )
        )
    }
}
