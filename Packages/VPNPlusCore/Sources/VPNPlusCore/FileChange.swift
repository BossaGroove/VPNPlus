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

/// One thing a reissued profile file says differently from the file it
/// replaces (A13a's **Replace profile file…**, the ReplaceFile artboard).
///
/// In the descriptor's own terms, so a change is reported for the facts the
/// app knows and nothing is claimed about the rest of the file: certificates,
/// keys and options are not compared, and the report says so. Values are raw —
/// the app puts them into words, in the user's language.
public enum FileChange: Sendable, Equatable {
    case name(from: String, to: String)
    case host(from: String, to: String)
    case port(from: String, to: String)
    case transport(from: String, to: String)
    case servers(from: [ServerChoice], to: [ServerChoice])
    case signIn(from: [CredentialRequirement], to: [CredentialRequirement])
    case passwordSaving(from: Bool, to: Bool)
    case certificateAuthority(from: Bool, to: Bool)

    /// The row a user can override, when this change is to one of those.
    public var setting: Overrides.Setting? {
        switch self {
        case .name: .title
        case .host: .host
        case .port: .port
        case .transport: .transport
        default: nil
        }
    }

    /// The file's old and new value, for the rows that carry plain strings.
    var values: (from: String, to: String)? {
        switch self {
        case .name(let from, let to), .host(let from, let to),
            .port(let from, let to), .transport(let from, let to):
            (from, to)
        default:
            nil
        }
    }
}

extension ProfileDescriptor {
    /// What this descriptor says differently from `old`, in a stable order.
    ///
    /// A certificate authority is compared only when both records say
    /// whether one is present: a record from before that was tracked is not
    /// a file that changed.
    public func changes(since old: ProfileDescriptor) -> [FileChange] {
        var found: [FileChange] = []
        if displayName != old.displayName {
            found.append(.name(from: old.displayName, to: displayName))
        }
        if server.host != old.server.host {
            found.append(.host(from: old.server.host, to: server.host))
        }
        if server.port != old.server.port {
            found.append(.port(from: old.server.port, to: server.port))
        }
        if server.transport != old.server.transport {
            found.append(.transport(from: old.server.transport, to: server.transport))
        }
        if alternateServers != old.alternateServers {
            found.append(.servers(from: old.alternateServers, to: alternateServers))
        }
        if credentials != old.credentials {
            found.append(.signIn(from: old.credentials, to: credentials))
        }
        if allowsPasswordSave != old.allowsPasswordSave {
            found.append(.passwordSaving(from: old.allowsPasswordSave, to: allowsPasswordSave))
        }
        if let was = old.caPresent, let now = caPresent, was != now {
            found.append(.certificateAuthority(from: was, to: now))
        }
        return found
    }
}

extension Overrides {
    /// The user's value for a row, when they have one.
    func value(of setting: Setting) -> String? {
        switch setting {
        case .title: title
        case .host: server?.host
        case .port: server?.port
        case .transport: server?.transport
        case .selectedServer: selectedServer
        case .username: username
        case .certificate: certificatePath
        }
    }

    /// The record with the parts of it that were never the user's brought up
    /// to date with a reissued file.
    ///
    /// A server override stores the **whole** endpoint, so overriding the
    /// port alone also stores the file's host — as a snapshot, not a choice.
    /// When the file then moves its host, that snapshot would pin the old one
    /// and the sheet would call it an override the user never made. So a
    /// component equal to the *old* file's value follows the new file; a
    /// component the user changed stays exactly as it was. Not D132's
    /// "resolving on the user's behalf": nothing the user chose is touched.
    public func following(_ descriptor: ProfileDescriptor, from old: ProfileDescriptor) -> Overrides {
        guard let mine = server else { return self }
        var copy = self
        copy.server = ServerEndpoint(
            host: mine.host == old.server.host ? descriptor.server.host : mine.host,
            port: mine.port == old.server.port ? descriptor.server.port : mine.port,
            transport: mine.transport == old.server.transport
                ? descriptor.server.transport : mine.transport)
        if copy.server == descriptor.server { copy.server = nil }
        return copy
    }

    /// Everything the new file contradicts: the three refusals
    /// `conflicts(with:)` already finds, and — when the old descriptor is
    /// known — every row the user overrode whose value **in the file** has
    /// itself changed. That last case is the one where "kept" is not
    /// obviously right: the employer moved the port and the user had moved it
    /// too, and only the user can say which they meant (D132).
    ///
    /// An override the file has caught up with is not a contradiction; the
    /// row simply reads "from the profile" from now on.
    public func conflicts(
        with descriptor: ProfileDescriptor, replacing old: ProfileDescriptor?
    ) -> [OverrideConflict] {
        var found = conflicts(with: descriptor)
        guard let old else { return found }
        for change in descriptor.changes(since: old) {
            guard let setting = change.setting, let file = change.values,
                overrides(setting, comparedTo: descriptor), let mine = value(of: setting)
            else { continue }
            found.append(
                OverrideConflict(
                    kind: .changedUnderneath(
                        setting, fileWas: file.from, fileNow: file.to, mine: mine)))
        }
        return found
    }
}
