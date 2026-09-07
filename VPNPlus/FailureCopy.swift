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

/// The words for a failure, in one place.
///
/// **Provisional, and M6 owns the finished version.** A10 wrote 21 messages
/// against A9's 79 captured modes; what can be said today is limited by what
/// M4 and M5 can actually distinguish, which is five codes. When M6 maps the
/// engine's events properly, this file grows to A10's set and the four-part
/// message (D81) with it.
///
/// What is *not* provisional, and holds already:
///
/// - **No code, no engine identifier, ever** (feature-spec 4.1, D105).
/// - **No "Error".** The title says what did not happen.
/// - **The profile is named**, because the user may have several.
/// - **Nothing is invented** (D85). Where the cause is unknown the message
///   says so and offers what is real — the step, and the time it took.
enum FailureCopy {
    static func title(_ record: FailureRecord, name: String) -> String {
        switch record.reason {
        case .authenticationFailed: String(localized: "Couldn't sign in to \(name)")
        default: String(localized: "Couldn't connect to \(name)")
        }
    }

    /// The same title without the profile's name, for a surface that has
    /// already said it on its own line — the menu (D149). Not built by
    /// deleting words from the long one: a sentence with a hole in it is how
    /// translations break.
    static func shortTitle(_ record: FailureRecord) -> String {
        switch record.reason {
        case .authenticationFailed: String(localized: "Couldn't sign in")
        default: String(localized: "Couldn't connect")
        }
    }

    static func body(_ record: FailureRecord, name: String) -> String {
        switch record.reason {
        case .authenticationFailed:
            // A10 M1, both remedies named (D99).
            return String(
                localized: """
                    The server didn't accept your username or password. If they're definitely right, \
                    the account may be disabled or locked — worth asking whoever runs this VPN.
                    """)
        case .credentialsUnavailable:
            // A10 M21, written at M4.5 for the case where a prompt had no
            // window to appear in.
            return String(
                localized: """
                    It needs your password, and VPN Plus wasn't running to ask for it. Connect once from \
                    VPN Plus and let it remember your password — after that, starting \(name) from \
                    System Settings or the menu bar will work on its own.
                    """)
        case .configurationMissing:
            return String(
                localized: """
                    VPN Plus doesn't have that profile's settings any more. Import the profile again.
                    """)
        case .timedOut:
            // The step is the message. M6 names it in words and adds the
            // attempt count and the seconds (A10 M2).
            if let step = record.phase.flatMap(OpenVPNPhase.init(id:))?.asPhase.label {
                return String(
                    localized: "It stopped while \(step.lowercased()), and didn't finish in time.")
            }
            return String(localized: "It didn't finish in time.")
        case .unknown:
            return String(
                localized: """
                    VPN Plus doesn't have a specific reason for it. Trying again is worth a go.
                    """)
        }
    }
}
