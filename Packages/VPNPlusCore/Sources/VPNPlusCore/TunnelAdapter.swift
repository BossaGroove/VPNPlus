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

/// What a profile needs from the user before it can connect. WireGuard
/// profiles are always `.none`, which is a first-class state and not
/// OpenVPN's `autologin` seen through a UI (D185).
public enum CredentialRequirement: Sendable, Equatable, Codable {
    case none
    case usernamePassword(usernameLocked: String?)
    case privateKeyPassphrase
    case challenge(prompt: String, echo: Bool)
}

/// Where a configuration says to connect.
public struct ServerEndpoint: Sendable, Equatable, Codable {
    public let host: String
    public let port: String
    /// The transport as the configuration names it, lowercased. Deliberately a
    /// string: the core does not enumerate one protocol's transports (D183).
    public let transport: String

    public init(host: String = "", port: String = "", transport: String = "") {
        self.host = host
        self.port = port
        self.transport = transport
    }

    public var isEmpty: Bool { host.isEmpty && port.isEmpty && transport.isEmpty }
}

/// The result of inspecting a configuration, with no protocol detail in it.
/// Everything a list or a settings surface needs about a profile, and
/// **nothing secret**: no key, no certificate, no password. That is what makes
/// it storable in preferences once the configuration text has moved to the
/// extension (D190, D191).
public struct ProfileDescriptor: Sendable, Equatable, Codable {
    public let displayName: String
    public let server: ServerEndpoint
    public let credentials: [CredentialRequirement]
    /// False when the configuration forbids saving the password. Our own
    /// default applies only where it is silent, never against it (D129).
    public let allowsPasswordSave: Bool
    public let alternateServers: [ServerChoice]
    /// Directives the engine does not support, waived at import and disclosed
    /// as a count with the list behind it (D187).
    public let waivedDirectives: [String]
    /// Whether the configuration carries a CA to check the server against.
    /// Absent for a profile that pins the server's fingerprint instead, so it
    /// is reported rather than assumed.
    ///
    /// **Optional because it is newer than the stored records.** A profile
    /// imported before this existed decodes with `nil`, and the surface says
    /// "not recorded" rather than making a claim about a server (A13a §6).
    public let caPresent: Bool?
    /// Whether the client identity comes from outside the file.
    public let externalPKI: Bool?

    public init(
        displayName: String,
        server: ServerEndpoint = ServerEndpoint(),
        credentials: [CredentialRequirement] = [],
        allowsPasswordSave: Bool = true,
        alternateServers: [ServerChoice] = [],
        waivedDirectives: [String] = [],
        caPresent: Bool? = nil,
        externalPKI: Bool? = nil
    ) {
        self.displayName = displayName
        self.server = server
        self.credentials = credentials
        self.allowsPasswordSave = allowsPasswordSave
        self.alternateServers = alternateServers
        self.waivedDirectives = waivedDirectives
        self.caPresent = caPresent
        self.externalPKI = externalPKI
    }

    /// True when nothing need be asked of the user before connecting.
    public var needsNothingFromTheUser: Bool {
        credentials.isEmpty || credentials == [.none]
    }

    /// What to call this profile in a list, given the file it came from.
    ///
    /// A configuration's declared name is used only when it is **a name**. An
    /// engine that has none to report falls back to the server address, and a
    /// list of profiles titled by IP address is exactly the failure this
    /// project exists to avoid — so the filename the user chose wins over it.
    public func preferredTitle(filename: String) -> String {
        let fallback = filename.isEmpty
            ? displayName
            : (filename as NSString).deletingPathExtension
        guard !displayName.isEmpty else { return fallback }
        // The engine reports the host as the name when it has nothing better.
        if displayName == server.host { return fallback }
        if !server.host.isEmpty, displayName.hasPrefix(server.host) { return fallback }
        return displayName
    }

    /// The username the configuration fixes, if it fixes one.
    public var fixedUsername: String? {
        for requirement in credentials {
            if case .usernamePassword(let locked) = requirement, let locked, !locked.isEmpty {
                return locked
            }
        }
        return nil
    }
}

public struct ServerChoice: Sendable, Equatable, Codable {
    public let host: String
    /// The issuer's label where they supplied one, else the host itself
    /// — openvpn3 only carries a real label via `setenv SERVER host/Label`.
    public let label: String

    public init(host: String, label: String) {
        self.host = host
        self.label = label
    }
}

/// Everything a protocol implementation owes the core. The core never asks
/// which protocol it is holding (D183); if it needs to, a capability is
/// missing from this protocol.
public protocol TunnelAdapter: Sendable {
    static var identifier: String { get }

    /// Ordered, each with its own deadline. May contain a single phase.
    static var phases: [TunnelPhase] { get }

    /// Parse a configuration without connecting to anything.
    static func inspect(_ configuration: Data) throws -> ProfileDescriptor
}
