// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 BossaGroove
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
// more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Security
import VPNPlusCore
import os

/// The Keychain, as a secret store. Deliberately the whole of the Keychain in
/// this project: every rule about *what* is stored and *when* lives in
/// `StoredProfileStore`, which is tested, so this file has nothing in it but
/// Keychain calls and can be read in one sitting (D190).
///
/// **M3 scope.** These items belong to the app, in the user's Keychain. A
/// system extension runs as root outside the user's session and gets no
/// keychain access of its own (B8), so M4 moves ownership behind the
/// privileged interface; until then the app hands the configuration to the
/// provider at connect time.
struct KeychainSecretStore: SecretStore {
    /// One service for every profile's configuration, with the account
    /// distinguishing them (`StoredProfileStore.account(for:)`).
    private let service = "com.bossagroove.VPNPlus.profiles"
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "storage")

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) throws -> Data? {
        var request = query(for: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            // The status, never the item: a log line about a private key is a
            // leak even when it only says the key exists.
            log.error("keychain read failed: \(status, privacy: .public)")
            throw Failure.keychain(status)
        }
    }

    func setSecret(_ data: Data, for account: String) throws {
        let existing = query(for: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(existing as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = existing
            item[kSecValueData as String] = data
            // Readable without an interactive login, which a VPN that connects
            // at startup needs, and never synchronised off this Mac.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            item[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            log.error("keychain write failed: \(status, privacy: .public)")
            throw Failure.keychain(status)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        // Already gone is the outcome asked for, so it is not a failure.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("keychain delete failed: \(status, privacy: .public)")
            throw Failure.keychain(status)
        }
    }
}

/// Preferences, as a metadata store. Only non-secrets reach here: the index of
/// profiles and each profile's overrides (D190, D191).
struct DefaultsMetadataStore: MetadataStore {
    // UserDefaults is thread-safe but not marked Sendable; holding it across
    // actors is what this store is for, and the class documents the guarantee.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(for key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func setData(_ data: Data?, for key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

extension StoredProfileStore {
    /// The store the app uses.
    static let live = StoredProfileStore(secrets: KeychainSecretStore(), metadata: DefaultsMetadataStore())
}
