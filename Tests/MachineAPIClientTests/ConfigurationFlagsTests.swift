// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the container project authors.

import ArgumentParser
import ContainerAPIClient
import ContainerizationError
import MachineAPIClient
import Testing

struct ConfigurationFlagsTests {
    @Test
    func groupedFlagsRejectUnsupportedSchemeBeforeFetching() async throws {
        let management = try Flags.MachineManagement.parse([])
        let error = await #expect(throws: ContainerizationError.self) {
            try await MachineClient.machineConfigFromFlags(
                id: "test-machine", image: "unused.invalid/image",
                flags: .init(management: management, user: .init(), registry: .init(scheme: "ftp"), imageFetch: .init()),
                containerSystemConfig: .init(),
                progressUpdate: { _ in
                    Issue.record("Invalid registry scheme must be rejected before image fetch")
                })
        }
        #expect(error?.code == .invalidArgument)
    }

    @Test
    func legacyFlagsPreserveRegistryValidation() async throws {
        let management = try Flags.MachineManagement.parse([])
        let error = await #expect(throws: ContainerizationError.self) {
            try await MachineClient.machineConfigFromFlags(
                id: "test-machine", image: "unused.invalid/image", management: management,
                user: .init(), registry: .init(scheme: "ftp"), imageFetch: .init(),
                containerSystemConfig: .init(),
                progressUpdate: { _ in
                    Issue.record("Legacy adapter must preserve validation before image fetch")
                })
        }
        #expect(error?.code == .invalidArgument)
    }
}
