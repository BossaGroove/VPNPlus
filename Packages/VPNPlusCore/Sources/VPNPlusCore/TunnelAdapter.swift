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
public struct ProfileDescriptor: Sendable, Equatable {
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

    public init(
        displayName: String,
        server: ServerEndpoint = ServerEndpoint(),
        credentials: [CredentialRequirement] = [],
        allowsPasswordSave: Bool = true,
        alternateServers: [ServerChoice] = [],
        waivedDirectives: [String] = []
    ) {
        self.displayName = displayName
        self.server = server
        self.credentials = credentials
        self.allowsPasswordSave = allowsPasswordSave
        self.alternateServers = alternateServers
        self.waivedDirectives = waivedDirectives
    }

    /// True when nothing need be asked of the user before connecting.
    public var needsNothingFromTheUser: Bool {
        credentials.isEmpty || credentials == [.none]
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
