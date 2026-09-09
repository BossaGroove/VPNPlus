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
import VPNPlusCore

/// A5/A17's words for the one-time setup, in the owner's own phrasing from
/// the four artboards (SetupExplain, Setup, Blocked, and D66's re-approval).
///
/// **Explain before prompting** (D65, D152): the second paragraph says
/// exactly what macOS is about to ask, in order — the toggle, the password,
/// and then the VPN-configuration permission that arrives at the first
/// connect — so none of the three is a surprise. **Never a code** (4.1): a
/// failure is a sentence with a cause and a next action.
public struct SetupMessage: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The button that carries the flow forward, when there is one.
    public var action: String?
    /// The way out, when there is one (*Not now*).
    public var secondary: String?
}

public enum SetupCopy {
    /// The screen before the OS prompt.
    public static func explanation(again: Bool) -> SetupMessage {
        if again {
            // D66: an experienced user whose setup broke — no welcome.
            return SetupMessage(
                title: String(localized: "VPN Plus needs permission again"),
                body: String(localized: """
                    This usually happens after moving to a new Mac, reinstalling, or restoring \
                    from a backup. It's the same one-time approval as before.

                    You'll be asked to turn VPN Plus on in System Settings, and to enter your \
                    Mac's password.
                    """),
                action: String(localized: "Continue"),
                secondary: String(localized: "Not now"))
        }
        return SetupMessage(
            title: String(localized: "One-time setup"),
            body: String(localized: """
                macOS needs your permission before VPN Plus can create a VPN connection. This \
                happens once on this Mac.

                You'll be asked to turn VPN Plus on in System Settings, to enter your Mac's \
                password, and then to allow VPN Plus to add a VPN configuration.
                """),
            action: String(localized: "Continue"),
            secondary: String(localized: "Not now"))
    }

    /// Step 0, the WrongLocation artboard (D62, D151, D156). `canMove` is
    /// whether the app can do it itself; when it cannot, the button gives way
    /// to the instruction — D62's degrade, never a dead control (D55).
    public static func wrongLocation(path: String, canMove: Bool) -> SetupMessage {
        let body = String(localized: "VPN Plus is running from \(folderName(path)). macOS won't let it create a VPN connection from there.")
        if canMove {
            return SetupMessage(
                title: String(localized: "Move VPN Plus to your Applications folder"),
                body: body, action: String(localized: "Move to Applications"), secondary: nil)
        }
        return SetupMessage(
            title: String(localized: "Move VPN Plus to your Applications folder"),
            body: body + " " + String(localized: "Drag VPN Plus into your Applications folder, then open it from there."),
            action: nil, secondary: nil)
    }

    /// The one bold phrase in `waiting` — a promise (D153).
    public static var waitingEmphasis: String { String(localized: "this window will notice") }

    /// While the approval is outstanding (D61, D153).
    public static var waiting: SetupMessage {
        SetupMessage(
            title: String(localized: "Waiting for your approval"),
            body: String(localized: """
                System Settings should be open. Turn on VPN Plus there, then come back — this \
                window will notice.
                """),
            action: String(localized: "Open System Settings again"),
            secondary: nil)
    }

    /// Stalled until the user acts (D67–D69, D154). The reason, where there
    /// is one beyond *Not now*, replaces the first sentence; the second — what
    /// still works — stays, because it is the sentence that keeps a declined
    /// setup from feeling like a broken app.
    public static func blocked(_ reason: SetupFailure?) -> SetupMessage {
        let works = String(localized: "Everything else still works — you can add, rename and remove profiles.")
        switch reason {
        case nil, .declined?, .unknown?:
            return SetupMessage(
                title: String(localized: "Setup isn't finished"),
                body: String(localized: "VPN Plus doesn't have permission from macOS to create a VPN connection, so it can't connect yet.") + " " + works,
                action: String(localized: "Continue setup"),
                secondary: nil)
        case .wrongLocation(let path)?:
            return SetupMessage(
                title: String(localized: "Move VPN Plus to your Applications folder"),
                body: String(localized: "VPN Plus is running from \(folderName(path)). macOS won't let it create a VPN connection from there.") + " " + works,
                action: String(localized: "Continue setup"),
                secondary: nil)
        case .forbiddenByPolicy?:
            return SetupMessage(
                title: String(localized: "This Mac's settings don't allow it"),
                body: String(localized: "A management policy on this Mac blocks VPN Plus's network component, so it can't connect. Ask whoever manages this Mac.") + " " + works,
                action: nil,
                secondary: nil)
        case .damaged?:
            return SetupMessage(
                title: String(localized: "This copy of VPN Plus is damaged"),
                body: String(localized: "macOS refused its network component. Download VPN Plus again and replace this copy.") + " " + works,
                action: nil,
                secondary: nil)
        case .needsRestart?:
            return SetupMessage(
                title: String(localized: "Restart your Mac to finish setup"),
                body: String(localized: "macOS installed VPN Plus's network component but needs a restart before it can run.") + " " + works,
                action: nil,
                secondary: nil)
        }
    }

    /// *"your Downloads folder"*, *"the disk image"* — where it actually is
    /// (D156), never where it is not.
    static func folderName(_ path: String) -> String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        if folder.path.hasPrefix("/Volumes/") { return String(localized: "the disk image") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if folder.path.hasPrefix(home + "/") {
            let name = folder.lastPathComponent
            switch name {
            case "Downloads": return String(localized: "your Downloads folder")
            case "Desktop": return String(localized: "your Desktop")
            case "Documents": return String(localized: "your Documents folder")
            default: return String(localized: "the “\(name)” folder")
            }
        }
        return String(localized: "the “\(folder.lastPathComponent)” folder")
    }
}
