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

/// Where a value came from, which every row of the configuration surface shows
/// (D126). The three states are exhaustive by design: a field is always in
/// exactly one of them.
public enum Provenance: Sendable, Equatable {
    /// The configuration supplies it and the user has not touched it.
    case fromProfile
    /// The user changed it. Carries what the configuration says, so the surface
    /// can offer to revert.
    case overridden(profileValue: String)
    /// The configuration does not supply it.
    case notInProfile
}

/// A value together with where it came from.
public struct ResolvedValue: Sendable, Equatable {
    public let value: String
    public let provenance: Provenance

    public init(value: String, provenance: Provenance) {
        self.value = value
        self.provenance = provenance
    }

    /// Resolves one field: what the user set, else what the configuration says.
    public init(profile: String, override: String?) {
        if let override, override != profile {
            self.value = override
            self.provenance = .overridden(profileValue: profile)
        } else if profile.isEmpty {
            self.value = ""
            self.provenance = .notInProfile
        } else {
            self.value = profile
            self.provenance = .fromProfile
        }
    }
}

/// How the user names their username, which the configuration decides (2.14).
public enum UsernameField: Sendable, Equatable {
    /// The configuration fixes it. Shown read-only, never as an empty field.
    case fixed(String)
    case editable(ResolvedValue)
}

/// Whether keeping the password may be offered at all (2.15, D129).
public enum PasswordSaving: Sendable, Equatable {
    /// The configuration permits it or is silent. Our default applies here.
    case offered(on: Bool)
    /// The configuration forbids it, so the option is **not shown** rather
    /// than shown and disabled.
    case forbiddenByProfile
}

/// The shape of the sign-in section, which comes from the configuration rather
/// than from a fixed form (D128).
public enum SignIn: Sendable, Equatable {
    /// Nothing to ask: the configuration signs in by itself.
    case notNeeded
    case credentials(
        username: UsernameField,
        passwordSaving: PasswordSaving,
        challenge: (prompt: String, echo: Bool)?
    )

    public static func == (lhs: SignIn, rhs: SignIn) -> Bool {
        switch (lhs, rhs) {
        case (.notNeeded, .notNeeded):
            return true
        case let (.credentials(lu, lp, lc), .credentials(ru, rp, rc)):
            return lu == ru && lp == rp && lc?.prompt == rc?.prompt && lc?.echo == rc?.echo
        default:
            return false
        }
    }
}

/// Which server to use. A configuration that advertises several makes this a
/// choice rather than a value (D130, 2.16).
public enum ServerSelection: Sendable, Equatable {
    case single(host: ResolvedValue, port: ResolvedValue, transport: ResolvedValue)
    case choice(offered: [ServerChoice], selected: String)
}

/// A profile as the user sees it: the configuration and their overrides,
/// composed. Nothing here is stored — it is derived, every time, from the
/// verbatim text and the separate overrides record (D188).
public struct ProfileSettings: Sendable, Equatable {
    public let title: ResolvedValue
    public let server: ServerSelection
    public let signIn: SignIn
    public let keyPassphraseNeeded: Bool
    /// A certificate supplied for this profile alone (D134); nil when none.
    public let certificatePath: ResolvedValue?
    public let connectWhenAppOpens: Bool
    public let reconnectAutomatically: Bool
    /// Disclosed as a count, with the list one click behind it (D187).
    public let waivedDirectives: [String]

    /// `filename` is the file the profile came from, and it is not optional
    /// decoration: **an engine with no name to report gives the server's
    /// address** (D215), so composing the title from the descriptor alone
    /// calls the profile `192.0.2.10`. `preferredTitle` is the rule that
    /// fixes it, and it needs the filename to apply.
    ///
    /// It has **no default on purpose.** It had one, and omitting it produced a
    /// plausible wrong answer instead of an error — which is how the same
    /// defect shipped twice: the card called the profile `192.0.2.10` at
    /// M5.4, and the settings sheet still did at M5.6.
    public static func compose(
        _ descriptor: ProfileDescriptor,
        with overrides: Overrides,
        filename: String
    ) -> ProfileSettings {
        let server: ServerSelection
        if descriptor.alternateServers.isEmpty {
            let typed = overrides.server
            server = .single(
                host: ResolvedValue(profile: descriptor.server.host, override: typed?.host),
                port: ResolvedValue(profile: descriptor.server.port, override: typed?.port),
                transport: ResolvedValue(
                    profile: descriptor.server.transport, override: typed?.transport))
        } else {
            // A chosen server that the configuration no longer offers falls
            // back to the first, so the surface can never show a dead choice.
            let chosen = overrides.selectedServer
            let valid = chosen.flatMap { candidate in
                descriptor.alternateServers.first { $0.host == candidate }?.host
            }
            server = .choice(
                offered: descriptor.alternateServers,
                selected: valid ?? descriptor.alternateServers[0].host)
        }

        let signIn: SignIn
        if descriptor.needsNothingFromTheUser {
            signIn = .notNeeded
        } else {
            let username: UsernameField
            if let fixed = descriptor.fixedUsername {
                username = .fixed(fixed)
            } else {
                username = .editable(ResolvedValue(profile: "", override: overrides.username))
            }
            let saving: PasswordSaving =
                descriptor.allowsPasswordSave
                ? .offered(on: overrides.savePassword ?? true)
                : .forbiddenByProfile
            var challenge: (prompt: String, echo: Bool)?
            for requirement in descriptor.credentials {
                if case .challenge(let prompt, let echo) = requirement {
                    challenge = (prompt, echo)
                }
            }
            signIn = .credentials(username: username, passwordSaving: saving, challenge: challenge)
        }

        return ProfileSettings(
            title: ResolvedValue(
                profile: descriptor.preferredTitle(filename: filename), override: overrides.title),
            server: server,
            signIn: signIn,
            keyPassphraseNeeded: descriptor.credentials.contains(.privateKeyPassphrase),
            certificatePath: overrides.certificatePath.map {
                ResolvedValue(value: $0, provenance: .overridden(profileValue: ""))
            },
            connectWhenAppOpens: overrides.connectWhenAppOpens ?? false,
            reconnectAutomatically: overrides.reconnectAutomatically ?? true,
            waivedDirectives: descriptor.waivedDirectives)
    }

    /// The server this profile would actually connect to, once composed.
    public var effectiveServer: ServerEndpoint {
        switch server {
        case let .single(host, port, transport):
            return ServerEndpoint(host: host.value, port: port.value, transport: transport.value)
        case let .choice(offered, selected):
            let chosen = offered.first { $0.host == selected }
            return ServerEndpoint(host: chosen?.host ?? selected, port: "", transport: "")
        }
    }
}
