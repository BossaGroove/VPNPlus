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

/// What the provider says about itself, and the whole of it.
///
/// `NEVPNStatus` has six values that are not A8's six, and it carries nothing
/// about *which step* an attempt is on — so this is what crosses instead, as
/// the reply to a provider message. Flat and versioned on purpose: it is a
/// wire format between two independently-updated binaries, not the model. The
/// app builds a `Connection` from it.
///
/// **Nothing here is a secret**, and that is a rule rather than an
/// observation: it crosses a boundary and may be logged at either end. No
/// username, no server address, no configuration text. A profile id, a state,
/// a phase id, some times, and a failure code.
struct TunnelReport: Codable, Sendable, Equatable {
    /// Bumped when the shape changes, so an app talking to an older extension
    /// (or the reverse, mid-update) can tell rather than guess.
    static let currentVersion = 1
    var version = TunnelReport.currentVersion

    var state: TunnelState
    var profile: UUID?
    /// The phase's id, which the app turns into words. Nil before the engine
    /// reports one, and nil for every state that is not an attempt.
    var phase: String?
    var phaseSince: Date?
    /// When the attempt or the session began — which one is decided by
    /// `state`, and never both (D73).
    var since: Date?
    /// 0 for an attempt somebody asked for; 1… for automatic recovery (D86).
    var recovery = 0
    var failure: FailureRecord?
    /// The name of the interface that already owned the default route when
    /// this attempt started, if one did (D204). Another VPN's tunnel is
    /// invisible to `NEVPNStatus` and plain in the routing table.
    var foreignTunnel: String?

    /// The model, rebuilt on the app's side. The phase's deadline comes from
    /// the phase list rather than crossing the wire: a deadline is policy, and
    /// policy belongs to whichever build is enforcing it.
    var connection: Connection {
        let phase = phase.flatMap(OpenVPNPhase.init(id:))?.asPhase
        switch state {
        case .disconnected:
            return .disconnected
        case .connected:
            guard let profile, let since else { return .disconnected }
            return .connected(Session(profile: profile, since: since))
        case .connecting, .reconnecting:
            guard let profile, let since else { return .disconnected }
            let attempt = Attempt(
                profile: profile, startedAt: since, recovery: recovery,
                phase: phase, phaseEnteredAt: phaseSince)
            return state == .reconnecting ? .reconnecting(attempt) : .connecting(attempt)
        case .disconnecting:
            return .disconnecting(Teardown(profile: profile, startedAt: since ?? Date()))
        case .failed:
            guard let failure else { return .disconnected }
            return .failed(failure)
        }
    }

    init(connection: Connection, foreignTunnel: String? = nil) {
        state = connection.state
        profile = connection.profile
        self.foreignTunnel = foreignTunnel
        switch connection {
        case .disconnected:
            break
        case .connecting(let attempt), .reconnecting(let attempt):
            phase = attempt.phase?.id
            phaseSince = attempt.phaseEnteredAt
            since = attempt.startedAt
            recovery = attempt.recovery
        case .connected(let session):
            since = session.since
        case .disconnecting(let teardown):
            since = teardown.startedAt
        case .failed(let record):
            failure = record
            since = record.at
        }
    }
}

/// How the app finds out that the report changed.
///
/// `NEVPNStatusDidChange` fires on the six `NEVPNStatus` values and nothing
/// else, so a phase change is invisible to it. `sendProviderMessage` is the
/// only supported channel and the **app** initiates it — so something has to
/// tell the app there is a reason to ask, and a Darwin notification is the one
/// mechanism that crosses from a root system extension to a user-session app
/// without a shared container or an entitlement.
enum TunnelReportChannel {
    /// Posted by the provider whenever its report changes. Carries no payload:
    /// a notification is a doorbell, and the answer comes back over XPC where
    /// it can be typed.
    static let notification = "com.bossagroove.VPNPlus.report"

    /// How often the app asks anyway, while an attempt is running.
    ///
    /// Belt and braces: if the doorbell is ever not heard, the interface must
    /// still not sit there showing a step that finished ten seconds ago.
    static let pollWhileAttempting: TimeInterval = 2
}
