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
import os

/// The app's side of the privileged interface.
///
/// The app pins the *extension's* identity too (D194): a malicious listener
/// registering the same Mach service would otherwise be handed passwords, and
/// "we are talking to root" is not the same as "we are talking to our root".
struct PrivilegedClient {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "privileged")

    enum Failure: Error, LocalizedError {
        case unavailable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "VPN Plus couldn't reach its network component.")
            case .refused(let reason):
                reason
            }
        }
    }

    /// Resumes a continuation exactly once, whichever of the two paths gets
    /// there first. An XPC call can end by reply **or** by the connection
    /// failing, and both are wired up — so without this, one of them either
    /// crashes on a double resume or, worse, never resumes and the caller
    /// waits for ever.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?

        init(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = continuation
        }

        func finish(_ error: (any Error)?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            if let error {
                pending.resume(throwing: error)
            } else {
                pending.resume()
            }
        }
    }

    /// One call, one connection, and a guarantee that it returns.
    private func perform(
        pinning requirement: String,
        _ call: @escaping (any PrivilegedInterface, @escaping ((any Error)?) -> Void) -> Void
    ) async throws {
        let connection = NSXPCConnection(machServiceName: PrivilegedChannel.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedInterface.self)
        // This does not report failure: a requirement that is malformed, or
        // that the other side does not satisfy, surfaces later as the
        // *connection* failing — which M4.2 measured, and which the error
        // handler below turns into a thrown error rather than a hang (D217).
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                // The connection failed — refused by the requirement, or
                // nothing listening. Either way the caller hears about it.
                Self.log.error("privileged call failed: \(error.localizedDescription, privacy: .public)")
                once.finish(Failure.refused(error.localizedDescription))
            }
            guard let proxy = proxy as? any PrivilegedInterface else {
                once.finish(Failure.unavailable)
                return
            }
            call(proxy) { error in
                once.finish(error.map { Failure.refused($0.localizedDescription) })
            }
        }
    }

    /// Hands one secret to the extension. Returns when it has been stored, so
    /// a caller can tell the user the truth about whether it was.
    func setSecret(
        _ value: Data,
        kind: SecretKind,
        for profile: UUID,
        pinning requirement: String = PrivilegedChannel.extensionRequirement
    ) async throws {
        try await setSecretRaw(value, kind: kind.rawValue, for: profile, pinning: requirement)
    }

    private func setSecretRaw(
        _ value: Data,
        kind: Int,
        for profile: UUID,
        pinning requirement: String = PrivilegedChannel.extensionRequirement
    ) async throws {
        try await perform(pinning: requirement) { proxy, finish in
            proxy.setSecret(profile: profile, kind: kind, value: value, reply: finish)
        }
    }

    /// Stores the sign-in details, so a later connection — including one
    /// started from System Settings with the app not running — can authenticate
    /// without asking anyone (D75).
    func setCredentials(username: String, password: String, for profile: UUID) async throws {
        guard let encoded = StoredCredentials(username: username, password: password).encoded else {
            throw Failure.unavailable
        }
        try await setSecret(encoded, kind: .password, for: profile)
        // A session token stands in for the password it was issued against.
        // New details mean the old token may belong to a different account, or
        // to a password the user has just changed because it stopped working.
        //
        // Not fatal if it fails: the extension tries the token first, and a
        // refused token falls back to the password it has just been given, so
        // the worst case is one slower connection.
        do {
            try await deleteSecret(kind: .sessionToken, for: profile)
        } catch {
            Self.log.notice("could not clear the old session token: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Makes the extension forget the sign-in details for one profile, and
    /// the session token that stands in for them.
    ///
    /// Deliberately **not** `deleteSecrets`: that takes the configuration with
    /// it, and a user who unticks "remember my password" has not asked to find
    /// the original file again.
    func forgetCredentials(for profile: UUID) async throws {
        try await deleteSecret(kind: .password, for: profile)
        // A token outliving the password it stands in for would keep signing
        // the user in after they asked us to stop.
        try await deleteSecret(kind: .sessionToken, for: profile)
    }

    func deleteSecret(kind: SecretKind, for profile: UUID) async throws {
        try await perform(pinning: PrivilegedChannel.extensionRequirement) { proxy, finish in
            proxy.deleteSecret(profile: profile, kind: kind.rawValue, reply: finish)
        }
    }

    /// Everything, for a profile that is being deleted.
    func deleteSecrets(for profile: UUID) async throws {
        try await perform(pinning: PrivilegedChannel.extensionRequirement) { proxy, finish in
            proxy.deleteSecrets(profile: profile, reply: finish)
        }
    }
}
