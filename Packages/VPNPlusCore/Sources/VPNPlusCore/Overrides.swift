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

/// What the user changed about a profile. Kept **separate from the profile
/// text**, which is stored verbatim and never rewritten, and composed with it
/// when connecting or when the configuration surface is shown (D188).
///
/// Every field is optional in the strict sense: `nil` means "the user has not
/// spoken", which is what lets a value fall back to the profile and lets
/// replacing the profile file preserve what the user chose (D132).
public struct Overrides: Sendable, Equatable, Codable {
    /// A title the user gave this profile, replacing the configuration's own.
    public var title: String?
    /// A server chosen from the ones the configuration advertises (D130).
    public var selectedServer: String?
    /// A server the user typed, which the configuration did not offer.
    public var server: ServerEndpoint?
    public var username: String?
    /// Whether to keep the password. Honoured only where the configuration
    /// permits saving at all (D129).
    public var savePassword: Bool?
    /// A certificate the user supplied for this profile alone (D134).
    public var certificatePath: String?
    public var connectWhenAppOpens: Bool?
    /// Reconnect without being asked. Defaults on where unset (D37).
    public var reconnectAutomatically: Bool?

    public init(
        title: String? = nil,
        selectedServer: String? = nil,
        server: ServerEndpoint? = nil,
        username: String? = nil,
        savePassword: Bool? = nil,
        certificatePath: String? = nil,
        connectWhenAppOpens: Bool? = nil,
        reconnectAutomatically: Bool? = nil
    ) {
        self.title = title
        self.selectedServer = selectedServer
        self.server = server
        self.username = username
        self.savePassword = savePassword
        self.certificatePath = certificatePath
        self.connectWhenAppOpens = connectWhenAppOpens
        self.reconnectAutomatically = reconnectAutomatically
    }

    public var isEmpty: Bool { self == Overrides() }
}

/// An override the profile text no longer agrees with. Replacing a profile
/// preserves overrides and calls these out rather than discarding them
/// silently (D132).
public struct OverrideConflict: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The user chose a server the new configuration no longer advertises.
        case serverNoLongerOffered(String)
        /// The user set a username, and the new configuration fixes a different one.
        case usernameNowFixed(userValue: String, fixedValue: String)
        /// The user asked to save the password, and the new configuration forbids it.
        case passwordSavingNowForbidden
    }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }
}

extension Overrides {
    /// What this record and `descriptor` disagree about. Order is stable, so a
    /// message built from it does not shuffle between runs.
    public func conflicts(with descriptor: ProfileDescriptor) -> [OverrideConflict] {
        var found: [OverrideConflict] = []
        if let chosen = selectedServer,
           !descriptor.alternateServers.isEmpty,
           !descriptor.alternateServers.contains(where: { $0.host == chosen }) {
            found.append(OverrideConflict(kind: .serverNoLongerOffered(chosen)))
        }
        if let typed = username, let fixed = descriptor.fixedUsername, typed != fixed {
            found.append(OverrideConflict(kind: .usernameNowFixed(userValue: typed, fixedValue: fixed)))
        }
        if savePassword == true, !descriptor.allowsPasswordSave {
            found.append(OverrideConflict(kind: .passwordSavingNowForbidden))
        }
        return found
    }
}
