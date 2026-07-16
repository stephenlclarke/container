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

import ContainerResource
import ContainerizationOS
import Foundation

/// Client API for opaque secret resources stored in the local keychain.
///
/// Secret values are read by the caller process rather than an XPC helper so
/// macOS keychain access controls continue to apply to the process that owns
/// the secret.
public struct ClientSecret {
    private static let keychainService = "com.apple.container.secret"

    /// Creates an immutable secret from opaque bytes.
    public static func create(name: String, contents: Data) throws -> SecretConfiguration {
        try validate(name: name)

        do {
            let keychain = KeychainQuery()
            guard try !keychain.genericPasswordExists(service: keychainService, account: name) else {
                throw SecretError.secretAlreadyExists(name)
            }
            try keychain.saveGenericPassword(service: keychainService, account: name, data: contents)
            return try inspect(name)
        } catch let error as SecretError {
            throw error
        } catch {
            throw storageError(error)
        }
    }

    /// Deletes a secret by name.
    public static func delete(name: String) throws {
        try validate(name: name)

        do {
            let keychain = KeychainQuery()
            guard try keychain.genericPasswordExists(service: keychainService, account: name) else {
                throw SecretError.secretNotFound(name)
            }
            try keychain.deleteGenericPassword(service: keychainService, account: name)
        } catch let error as SecretError {
            throw error
        } catch {
            throw storageError(error)
        }
    }

    /// Lists secret metadata without returning secret values.
    public static func list() throws -> [SecretConfiguration] {
        do {
            let keychain = KeychainQuery()
            return try keychain.listGenericPasswords(service: keychainService).map {
                SecretConfiguration(
                    name: $0.account,
                    creationDate: $0.createdDate,
                    modificationDate: $0.modifiedDate,
                    sizeInBytes: nil,
                )
            }
        } catch {
            throw storageError(error)
        }
    }

    /// Returns secret metadata without returning its value.
    public static func inspect(_ name: String) throws -> SecretConfiguration {
        try validate(name: name)

        do {
            let keychain = KeychainQuery()
            guard let secret = try keychain.getGenericPassword(service: keychainService, account: name) else {
                throw SecretError.secretNotFound(name)
            }
            return SecretConfiguration(
                name: name,
                creationDate: secret.createdDate,
                modificationDate: secret.modifiedDate,
                sizeInBytes: UInt64(secret.data.count),
            )
        } catch let error as SecretError {
            throw error
        } catch {
            throw storageError(error)
        }
    }

    /// Reads opaque bytes for a named secret.
    public static func read(name: String) throws -> Data {
        try validate(name: name)

        do {
            let keychain = KeychainQuery()
            guard let secret = try keychain.getGenericPassword(service: keychainService, account: name) else {
                throw SecretError.secretNotFound(name)
            }
            return secret.data
        } catch let error as SecretError {
            throw error
        } catch {
            throw storageError(error)
        }
    }

    private static func validate(name: String) throws {
        guard SecretStorage.isValidSecretName(name) else {
            throw SecretError.invalidSecretName(name)
        }
    }

    private static func storageError(_ error: Error) -> SecretError {
        SecretError.storageError(String(describing: error))
    }
}
