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

import AppKit
import VPNPlusCore

/// The words for a replaced profile file, in one place (the ReplaceFile
/// artboard). The model says what changed and what the user overrode; this
/// says it in the user's language, and never in the engine's.
@MainActor
enum ReplaceCopy {
    static func summary(name: String, keptAnything: Bool, setAside: Int) -> String {
        var text =
            keptAnything
            ? String(localized: "\(name) was updated from the new file. Your settings were kept.")
            : String(localized: "\(name) was updated from the new file.")
        if setAside > 0 {
            text += " "
            text += String(localized: "VPN Plus doesn't use \(setAside) of its settings.")
        }
        return text
    }

    /// One before → after row. Values are the file's, put into words.
    static func row(_ change: FileChange) -> ReplaceReportSheet.Change {
        switch change {
        case .name(let from, let to):
            return .init(label: String(localized: "Name"), before: from, after: to)
        case .host(let from, let to):
            return .init(label: String(localized: "Host"), before: from, after: to)
        case .port(let from, let to):
            return .init(label: String(localized: "Port"), before: from, after: to)
        case .transport(let from, let to):
            return .init(
                label: String(localized: "Protocol"), before: transport(from), after: transport(to))
        case .servers(let from, let to):
            return .init(label: String(localized: "Servers"), before: servers(from), after: servers(to))
        case .signIn(let from, let to):
            return .init(label: String(localized: "Sign-in"), before: signIn(from), after: signIn(to))
        case .passwordSaving(let from, let to):
            return .init(
                label: String(localized: "Saving the password"),
                before: allowed(from), after: allowed(to))
        case .certificateAuthority(let from, let to):
            return .init(
                label: String(localized: "Certificate authority"),
                before: included(from), after: included(to))
        }
    }

    /// What the user had set, and still has (D132). Only what is actually
    /// set: a list that names defaults would claim the user chose them.
    static func kept(
        _ overrides: Overrides, credentialsSaved: Bool, against descriptor: ProfileDescriptor
    ) -> [String] {
        var lines: [String] = []
        if let title = overrides.title, overrides.overrides(.title, comparedTo: descriptor) {
            lines.append(String(localized: "Your name for it, “\(title)”"))
        }
        if let server = overrides.server {
            if overrides.overrides(.host, comparedTo: descriptor) {
                lines.append(String(localized: "Host \(server.host)"))
            }
            if overrides.overrides(.port, comparedTo: descriptor) {
                lines.append(String(localized: "Port \(server.port)"))
            }
            if overrides.overrides(.transport, comparedTo: descriptor) {
                lines.append(String(localized: "Protocol \(transport(server.transport))"))
            }
        }
        if let chosen = overrides.selectedServer {
            lines.append(String(localized: "Your server choice, \(chosen)"))
        }
        if let username = overrides.username, !username.isEmpty {
            lines.append(
                credentialsSaved
                    ? String(localized: "Username \(username) and your saved password")
                    : String(localized: "Username \(username)"))
        } else if credentialsSaved {
            lines.append(String(localized: "Your saved password"))
        }
        if overrides.certificatePath != nil {
            lines.append(String(localized: "Your certificate"))
        }
        if let connect = overrides.connectWhenAppOpens {
            lines.append(
                connect
                    ? String(localized: "Connect when VPN Plus opens")
                    : String(localized: "Connect when VPN Plus opens: off"))
        }
        if let reconnect = overrides.reconnectAutomatically {
            lines.append(
                reconnect
                    ? String(localized: "Reconnect automatically")
                    : String(localized: "Reconnect automatically: off"))
        }
        return lines
    }

    /// The sentence in the grey box. The user's own value is in bold, as the
    /// artboard has it, so the two values in one sentence stay apart.
    static func question(_ conflict: OverrideConflict) -> NSAttributedString {
        switch conflict.kind {
        case .changedUnderneath(let setting, _, let fileNow, let mine):
            let shown = setting == .transport ? transport(mine) : mine
            let now = setting == .transport ? transport(fileNow) : fileNow
            return MessageSheet.prose(
                String(
                    localized:
                        "Your \(rowName(setting)) override (\(shown)) no longer matches the file, which now says \(now)."
                ),
                bold: [shown], font: Type.detail)
        case .serverNoLongerOffered(let host):
            return MessageSheet.prose(
                String(localized: "The new file no longer offers \(host), which you had chosen."),
                bold: [host], font: Type.detail)
        case .usernameNowFixed(let userValue, let fixedValue):
            return MessageSheet.prose(
                String(
                    localized: "The new file fixes the username to \(fixedValue); yours was \(userValue)."),
                bold: [userValue], font: Type.detail)
        case .passwordSavingNowForbidden:
            return MessageSheet.prose(
                String(localized: "The new file does not allow saving the password."),
                font: Type.detail)
        }
    }

    /// The row "Use the file's" reverts, when the conflict is a choice at all.
    /// Password saving is not: the file forbids it, and D180 says the file
    /// wins — so that box states, and offers nothing.
    static func setting(of conflict: OverrideConflict) -> Overrides.Setting? {
        switch conflict.kind {
        case .changedUnderneath(let setting, _, _, _): setting
        case .serverNoLongerOffered: .selectedServer
        case .usernameNowFixed: .username
        case .passwordSavingNowForbidden: nil
        }
    }

    // MARK: - Vocabulary

    private static func rowName(_ setting: Overrides.Setting) -> String {
        switch setting {
        case .title: String(localized: "name")
        case .host: String(localized: "host")
        case .port: String(localized: "port")
        case .transport: String(localized: "protocol")
        case .selectedServer: String(localized: "server")
        case .username: String(localized: "username")
        case .certificate: String(localized: "certificate")
        }
    }

    private static func transport(_ value: String) -> String {
        value.isEmpty ? String(localized: "Not set") : value.uppercased()
    }

    private static func servers(_ choices: [ServerChoice]) -> String {
        choices.isEmpty
            ? String(localized: "None") : choices.map(\.label).joined(separator: ", ")
    }

    private static func signIn(_ credentials: [CredentialRequirement]) -> String {
        let parts = credentials.compactMap { requirement -> String? in
            switch requirement {
            case .none: nil
            case .usernamePassword(let locked):
                if let locked, !locked.isEmpty {
                    String(localized: "username \(locked) and password")
                } else {
                    String(localized: "username and password")
                }
            case .privateKeyPassphrase: String(localized: "key passphrase")
            case .challenge: String(localized: "a code")
            }
        }
        return parts.isEmpty
            ? String(localized: "Nothing")
            : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }

    private static func allowed(_ value: Bool) -> String {
        value ? String(localized: "Allowed") : String(localized: "Not allowed")
    }

    private static func included(_ value: Bool) -> String {
        value ? String(localized: "Included") : String(localized: "Not included")
    }
}
