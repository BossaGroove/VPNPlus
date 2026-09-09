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
import os

/// The root side of the privileged interface: a Mach service the app can
/// reach, and the only code in this project that runs as root on input from
/// somewhere else.
///
/// It is written to be read by someone looking for holes. Three properties do
/// the work:
///
/// - **Identity is pinned, not assumed** (D194). The app runs as the user and
///   can be attacked, so a connection is refused unless it comes from our
///   bundle identifier signed by our team. `setCodeSigningRequirement` rejects
///   at connect, before any of our code sees a message.
/// - **Every input is validated before use.** A size cap per kind, a known
///   kind, a well-formed id. A caller learns only that it was wrong.
/// - **Nothing comes back out.** No method returns a secret, so a confused
///   deputy has nothing to steal (D193).
final class PrivilegedService: NSObject {
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "privileged")
    private let listener: NSXPCListener
    private let secrets = ExtensionSecretStore()

    override init() {
        listener = NSXPCListener(machServiceName: PrivilegedChannel.machServiceName)
        super.init()
        listener.delegate = self
    }

    /// Starts listening. Called from the extension's entry point rather than
    /// from a provider, because a password must be storable **before** there is
    /// any tunnel — which is the whole point of D75.
    func start() {
        listener.resume()
        log.notice("privileged service listening on \(PrivilegedChannel.machServiceName, privacy: .public)")
    }
}

extension PrivilegedService: NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Pinned identity first: if this throws or the requirement does not
        // match, nothing of ours ever sees a message from this caller.
        // As on the client: no failure is reported here. An unsatisfied
        // requirement rejects the caller when it tries to talk, before any of
        // our code sees a message — measured at M4.2.
        connection.setCodeSigningRequirement(PrivilegedChannel.appRequirement)

        connection.exportedInterface = NSXPCInterface(with: PrivilegedInterface.self)
        connection.exportedObject = self
        connection.resume()
        log.notice("accepted a connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }
}

extension PrivilegedService: PrivilegedInterface {
    func setSecret(profile: UUID, kind: Int, value: Data, reply: @escaping ((any Error)?) -> Void) {
        guard let kind = SecretKind(rawValue: kind), kind.settableByApp else {
            log.error("rejected a secret: kind \(kind, privacy: .public) is not one the app may store")
            reply(PrivilegedFailure.malformedRequest.asError)
            return
        }
        guard !value.isEmpty else {
            reply(PrivilegedFailure.malformedRequest.asError)
            return
        }
        guard value.count <= kind.sizeLimit else {
            log.error("rejected a secret: \(value.count, privacy: .public) bytes exceeds the limit for this kind")
            reply(PrivilegedFailure.tooLarge.asError)
            return
        }

        do {
            try secrets.set(value, for: kind.account(for: profile))
            // The profile id is logged; the value never is, and its length is
            // not either — a length is a small leak and buys nothing.
            log.notice("stored a secret for \(profile.uuidString, privacy: .public)")
            reply(nil)
        } catch {
            log.error("could not store a secret: \(error.localizedDescription, privacy: .public)")
            reply(PrivilegedFailure.storageFailed.asError)
        }
    }

    func deleteSecret(profile: UUID, kind: Int, reply: @escaping ((any Error)?) -> Void) {
        guard let kind = SecretKind(rawValue: kind) else {
            log.error("rejected a deletion: unknown kind \(kind, privacy: .public)")
            reply(PrivilegedFailure.malformedRequest.asError)
            return
        }
        do {
            try secrets.remove(for: kind.account(for: profile))
            log.notice("removed one secret for \(profile.uuidString, privacy: .public)")
            reply(nil)
        } catch {
            log.error("could not remove a secret: \(error.localizedDescription, privacy: .public)")
            reply(PrivilegedFailure.storageFailed.asError)
        }
    }

    func deleteSecrets(profile: UUID, reply: @escaping ((any Error)?) -> Void) {
        do {
            for kind in SecretKind.allCases {
                try secrets.remove(for: kind.account(for: profile))
            }
            // D122: the record goes with the credentials and the last-good
            // record. A diagnostics log outliving the profile it is about is
            // exactly the privacy surface flow-failure.md refused.
            DiagnosticsStore().remove(for: profile)
            log.notice("removed every secret and the record for \(profile.uuidString, privacy: .public)")
            reply(nil)
        } catch {
            log.error("could not remove secrets: \(error.localizedDescription, privacy: .public)")
            reply(PrivilegedFailure.storageFailed.asError)
        }
    }

    /// What is on disk for this profile — every attempt that has finished.
    /// The attempt in flight lives in the provider object and reaches the app
    /// by the tunnel session; this is the answer when nothing is running,
    /// which is when somebody is usually reading (D141).
    func diagnostics(profile: UUID, reply: @escaping (Data?, (any Error)?) -> Void) {
        let record = DiagnosticsStore().load(for: profile)
        guard let data = try? JSONEncoder().encode(record) else {
            log.error("could not encode the record for \(profile.uuidString, privacy: .public)")
            reply(nil, PrivilegedFailure.storageFailed.asError)
            return
        }
        log.notice(
            "handing over \(record.attempts.count, privacy: .public) recorded attempts for \(profile.uuidString, privacy: .public)"
        )
        reply(data, nil)
    }
}

/// The System keychain, as the extension's store. M4.1 measured that this
/// works from a root process outside any user session, with no prompt, and
/// that an item survives into a different provider process (D216).
///
/// Nothing here names a keychain, unlocks one, or manages one: `SecItem*`
/// only, which is also the part of the API that is not deprecated.
struct ExtensionSecretStore {
    private let service = "com.bossagroove.VPNPlus.tunnel"

    enum Failure: Error {
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
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Failure.keychain(status)
        }
    }

    func set(_ value: Data, for account: String) throws {
        let existing = query(for: account)
        var status = SecItemUpdate(existing as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = existing
            item[kSecValueData as String] = value
            // No kSecAttrAccessible: that belongs to the data-protection
            // keychain, which M4.1 proved is absent here. Setting it would be
            // cargo cult.
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func remove(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        // Already absent is the state the caller asked for.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }
}
