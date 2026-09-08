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

/// The entire privileged interface (B9). Three methods, every one idempotent,
/// **not one of them returning a secret** (D193).
///
/// Read this list as a closed set. The test for anything proposed later: if it
/// would let a caller make the root process act on something the *caller*
/// names — a path, a command, an address — it does not belong here. That is
/// why there is no `readSecret`, nothing taking a file path, and no generic
/// message.
///
/// Shared by both targets so the app and the extension cannot drift.
@objc protocol PrivilegedInterface {
    /// Stores one secret for one profile, replacing any it already holds.
    /// Idempotent by construction: the same call twice leaves the same state.
    func setSecret(profile: UUID, kind: Int, value: Data, reply: @escaping ((any Error)?) -> Void)

    /// Removes every secret held for one profile. Succeeds when there were
    /// none, because the caller asked for a state, not an action.
    func deleteSecrets(profile: UUID, reply: @escaping ((any Error)?) -> Void)

    /// Removes **one** kind of secret for one profile.
    ///
    /// The third method, and it earns its place: without it "forget my
    /// password" can only be said as "forget everything", which takes the
    /// configuration with it and makes the user find the original file again.
    /// It passes the test above — the caller names a kind from a closed set,
    /// never a path, a command or an address — and like the other two it asks
    /// for a state rather than an action.
    func deleteSecret(profile: UUID, kind: Int, reply: @escaping ((any Error)?) -> Void)
}

/// What a stored secret is. Deliberately a small closed set: an interface that
/// accepts an arbitrary label accepts an arbitrary amount of storage.
enum SecretKind: Int, CaseIterable {
    /// The merged profile text. A secret because it routinely contains a
    /// private key (D190).
    case configuration = 1
    /// The user's sign-in details: the password **and the username**.
    ///
    /// The username travels with the password rather than in
    /// `providerConfiguration`, which any local administrator can read. It is
    /// not a secret in the way a password is, but it is the user's, and there
    /// is no reason to publish it to get it where it is needed.
    case password = 2
    /// The session token the server issued, which stands in for the password
    /// on the next connection.
    ///
    /// A separate item from the password rather than a replacement for it
    /// (D220): the two have different lifetimes, the server can revoke this
    /// one at any time, and the user asked us to remember the other one.
    case sessionToken = 3
    /// A client certificate the user supplied for this profile alone (D134),
    /// as PEM.
    ///
    /// It goes to the extension rather than travelling in `startTunnel`
    /// options, because a connection started from System Settings carries no
    /// options — and a certificate that is only present when the app started
    /// the connection would work in one place and fail in the other.
    case certificate = 4
    /// Its private key, as PEM. Separate from the certificate because a
    /// private key is a secret in a way a certificate is not, and because a
    /// user may replace one without the other.
    case privateKey = 5

    /// The largest value this kind may carry. A cap is not paranoia: the
    /// caller runs as the user and can be attacked (D194), and root should
    /// never be asked to hold something the size of a disk image.
    var sizeLimit: Int {
        switch self {
        case .configuration: 1 << 20  // 1 MiB; openvpn3's own profile cap is smaller
        case .password: 4 << 10       // 4 KiB, which is generous for a password
        case .sessionToken: 4 << 10   // the protocol's own cap is 256 characters
        case .certificate: 128 << 10  // a chain, generously; not a disk image
        case .privateKey: 128 << 10
        }
    }

    /// Whether the app may store this kind at all.
    ///
    /// A session token is learned from the server by the extension and by
    /// nobody else, so an app that offers one is either confused or not our
    /// app. Refusing it costs nothing and narrows the surface (D194).
    var settableByApp: Bool {
        switch self {
        case .configuration, .password, .certificate, .privateKey: true
        case .sessionToken: false
        }
    }

    /// The keychain account this kind uses for a profile. A UUID and a word:
    /// keychain metadata is readable without authorisation (D216), so an
    /// account name must say nothing about the user, the server or the profile.
    func account(for profile: UUID) -> String {
        switch self {
        case .configuration: "\(profile.uuidString).profile"
        case .password: "\(profile.uuidString).password"
        case .sessionToken: "\(profile.uuidString).session"
        case .certificate: "\(profile.uuidString).certificate"
        case .privateKey: "\(profile.uuidString).key"
        }
    }
}

/// The sign-in details for one profile, as they are stored and read back.
/// Small, fixed shape, JSON: nothing here is a graph an attacker could walk.
struct StoredCredentials: Codable, Equatable {
    var username: String
    var password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }

    init?(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// The session token one profile is holding: what the server issued last time,
/// ready to be offered instead of the password.
///
/// The username is here because the server may name its own
/// (`auth-token-user`), and using ours instead would fail an authentication
/// that would otherwise have worked.
struct StoredSessionToken: Codable, Equatable {
    var username: String
    var token: String

    init(username: String, token: String) {
        self.username = username
        self.token = token
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }

    init?(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}

/// Why a privileged call was refused. Carries no detail an attacker could
/// mine: the caller learns that it was wrong, not what would have been right.
enum PrivilegedFailure: Int, Error {
    case malformedRequest = 1
    case tooLarge = 2
    case storageFailed = 3

    static let domain = "com.bossagroove.VPNPlus.privileged"

    var asError: NSError {
        NSError(domain: Self.domain, code: rawValue, userInfo: [
            NSLocalizedDescriptionKey: description,
        ])
    }

    var description: String {
        switch self {
        case .malformedRequest: "The request was not understood."
        case .tooLarge: "The value was too large."
        case .storageFailed: "The secret could not be stored."
        }
    }
}

/// The Mach service the extension listens on, and the code-signing identities
/// each side pins. Both are frozen by D174, which is what makes pinning them
/// a stable check rather than a maintenance burden.
enum PrivilegedChannel {
    /// Must match `NEMachServiceName` in the extension's Info.plist.
    static let machServiceName = "DR9YZ5L9PX.com.bossagroove.VPNPlus.tunnel"

    private static let team = "DR9YZ5L9PX"

    /// What the extension demands of anything that connects to it: our app,
    /// signed by us. Being signed by the same team is not enough on its own —
    /// the bundle identifier is pinned too (D194).
    static let appRequirement =
        "identifier \"com.bossagroove.VPNPlus\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""

    /// What the app demands of the service it is talking to, so a malicious
    /// listener cannot impersonate the extension and collect passwords.
    static let extensionRequirement =
        "identifier \"com.bossagroove.VPNPlus.tunnel\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}
