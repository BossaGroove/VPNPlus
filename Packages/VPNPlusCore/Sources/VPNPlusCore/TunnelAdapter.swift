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
public enum CredentialRequirement: Sendable, Equatable {
    case none
    case usernamePassword(usernameLocked: String?)
    case privateKeyPassphrase
    case challenge(prompt: String, echo: Bool)
}

/// The result of inspecting a configuration, with no protocol detail in it.
public struct ProfileDescriptor: Sendable, Equatable {
    public let displayName: String
    public let endpoints: [String]
    public let credentials: [CredentialRequirement]
    public let alternateServers: [ServerChoice]
    /// Directives the engine does not support, waived at import and disclosed
    /// as a count with the list behind it (D187).
    public let waivedDirectives: [String]

    public init(
        displayName: String,
        endpoints: [String] = [],
        credentials: [CredentialRequirement] = [],
        alternateServers: [ServerChoice] = [],
        waivedDirectives: [String] = []
    ) {
        self.displayName = displayName
        self.endpoints = endpoints
        self.credentials = credentials
        self.alternateServers = alternateServers
        self.waivedDirectives = waivedDirectives
    }
}

public struct ServerChoice: Sendable, Equatable {
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
