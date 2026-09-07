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

/// The five steps an OpenVPN connection goes through, and the engine event
/// that **begins** each one.
///
/// It lives here rather than in the core because these are one protocol's
/// steps and the core never names a protocol (D183) — and it lives outside the
/// provider because the app needs the same ids to put words to them. The words
/// themselves are the app's: it has the String Catalog, and a phase id is not
/// a sentence.
///
/// ## The mapping is measured, and A8's was one row out
///
/// A8 assigned `WAIT` **and** `CONNECTING` to "Contacting the server" and left
/// "Signing in" with no event at all. openvpn3's source says otherwise:
/// `ClientEvent::Connecting` is posted from the transport's receive path,
/// *"only on first packet received"* — so it does not mean "we are contacting
/// the server", it means **the server has answered**.
///
/// Three of the owner's connections, measured end to end, agree:
///
/// | Event | At | What is actually happening |
/// |---|---|---|
/// | `RESOLVE` | +0.01 s | — |
/// | `WAIT` | +0.01 s | reaching the server |
/// | `CONNECTING` | +0.14 s | **the TLS handshake and the sign-in, 4.1 s of it** |
/// | `GET_CONFIG` | +4.2 s | the first `PUSH_REQUEST` has gone out |
/// | `ASSIGN_IP` | +5.7 s | applying what the server sent |
///
/// So all five of A8's phases are observable after all; only the assignment
/// needed correcting. `ADD_ROUTES` never arrives, because a tun-builder client
/// never configures routes itself — the OS does (B1, B14).
enum OpenVPNPhase: String, CaseIterable, Sendable {
    case findingServer = "resolve"
    case contactingServer = "contact"
    /// Begins when the server first answers, and covers the TLS handshake.
    /// The measured 4.1 s lives here, and feature-spec 3.15 already knew it
    /// would: *"the handshake dominates and offers nothing to count, so its
    /// wording carries that wait alone"*.
    case signingIn = "auth"
    /// The owner's most frequent failure (J6). A normal phase with a normal
    /// deadline — no special case, which is the point of D72.
    case waitingForSettings = "config"
    case settingUp = "setup"

    var deadline: Duration {
        switch self {
        case .findingServer: Deadlines.resolve
        case .contactingServer: Deadlines.contact
        case .signingIn: Deadlines.auth
        case .waitingForSettings: Deadlines.config
        case .settingUp: Deadlines.setup
        }
    }

    /// As the core sees it: an id and a deadline, and no protocol (D183/D184).
    var asPhase: TunnelPhase { TunnelPhase(id: rawValue, deadline: deadline) }

    /// The phase an engine event begins, or nil for an event that is not a
    /// phase boundary. Events we do not map are still logged; **an unmapped
    /// event never changes the phase**, because a phase we cannot place is
    /// worse than the one we already have.
    static func beginning(with event: String) -> OpenVPNPhase? {
        switch event {
        case "RESOLVE": .findingServer
        case "WAIT", "WAIT_PROXY": .contactingServer
        case "CONNECTING": .signingIn
        case "GET_CONFIG": .waitingForSettings
        case "ASSIGN_IP", "ADD_ROUTES": .settingUp
        default: nil
        }
    }

    /// Rebuilt from an id that crossed to the app or came out of a stored
    /// failure record.
    init?(id: String) {
        guard let phase = Self(rawValue: id) else { return nil }
        self = phase
    }
}
