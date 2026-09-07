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

/// The words for a phase, which live here and nowhere else.
///
/// The core carries a phase's identity and its deadline; the extension carries
/// neither of these sentences. Localized strings belong where the String
/// Catalog is, and that is the app — the same reasoning as D221.
///
/// A8's own labels, used as written. They are also the only place the
/// engine's vocabulary is allowed to end: nothing here says `GET_CONFIG`, and
/// nothing a user reads ever will (feature-spec 4.1).
extension TunnelPhase {
    var label: String {
        switch OpenVPNPhase(id: id) {
        case .findingServer: String(localized: "Finding the server")
        case .contactingServer: String(localized: "Contacting the server")
        case .signingIn: String(localized: "Signing in")
        case .waitingForSettings: String(localized: "Waiting for connection settings")
        case .settingUp: String(localized: "Setting up your connection")
        // A phase this build has no words for. The state above it is still
        // true and still useful, so it says that rather than an id.
        case nil: String(localized: "Connecting")
        }
    }
}

extension Connection {
    /// The state, in words, on its own — what the promoted region puts in the
    /// largest type on the screen, because it is the J1 answer.
    ///
    /// A phase is named **only once it is slow** (D71). A fast connection says
    /// nothing internal at all: of the five phases in a measured 5.95 s
    /// connection, exactly one ran long enough to be worth a word.
    func stateLine(at now: Date = Date()) -> String {
        switch self {
        case .disconnected: return String(localized: "Disconnected")
        case .connected: return String(localized: "Connected")
        case .disconnecting(let teardown):
            return teardown.isSwitch
                ? String(localized: "Switching")
                : String(localized: "Disconnecting")
        case .failed: return String(localized: "Couldn't connect")
        case .connecting(let attempt), .reconnecting(let attempt):
            let waiting =
                state == .reconnecting
                ? String(localized: "Reconnecting")
                : String(localized: "Connecting")
            let step = attempt.revealedPhase(at: now)?.label ?? waiting
            guard attempt.recovery > 0 else { return step }
            // Counted and shown, which is what makes the bound mean
            // something (D86).
            let of = Recovery.maxAttempts
            return String(localized: "\(step) — attempt \(attempt.recovery) of \(of)")
        }
    }

    /// The clock, whichever clock this state has — and it never has both
    /// (D73). A session reads as a duration; an attempt reads as seconds.
    func clock(at now: Date = Date()) -> String {
        switch self {
        case .connected(let session):
            let seconds = Int(session.duration(at: now).components.seconds)
            return String(
                format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        case .connecting(let attempt), .reconnecting(let attempt):
            return "\(Int(attempt.elapsed(at: now).components.seconds))s"
        default:
            return ""
        }
    }

    /// One line for a surface that has room for one — the menu bar's, and the
    /// window's until M5.4 gave it room for two.
    func summary(at now: Date = Date()) -> String {
        switch self {
        case .disconnected:
            return String(localized: "Disconnected")
        case .connecting(let attempt), .reconnecting(let attempt):
            // Named only once it is slow (D71) — a fast connection says
            // nothing internal at all.
            let waiting =
                state == .reconnecting
                ? String(localized: "Reconnecting")
                : String(localized: "Connecting")
            let step = attempt.revealedPhase(at: now)?.label ?? waiting
            let seconds = Int(attempt.elapsed(at: now).components.seconds)
            if attempt.recovery > 0 {
                // Counted, and shown, because that is what makes the bound
                // mean something (D86).
                let of = Recovery.maxAttempts
                return String(
                    localized: "\(step) — attempt \(attempt.recovery) of \(of), \(seconds)s")
            }
            return String(localized: "\(step) — \(seconds)s")
        case .connected(let session):
            let seconds = Int(session.duration(at: now).components.seconds)
            return String(localized: "Connected — \(Self.clock(seconds))")
        case .disconnecting(let teardown):
            return teardown.isSwitch
                ? String(localized: "Switching")
                : String(localized: "Disconnecting")
        case .failed:
            return String(localized: "Couldn't connect")
        }
    }

    /// A session duration reads as a clock; an attempt's seconds do not. They
    /// are two different numbers and they do not get one format (D73).
    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}
