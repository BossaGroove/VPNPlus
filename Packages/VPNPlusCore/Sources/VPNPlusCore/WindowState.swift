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

/// How far the one-time macOS approval has got.
///
/// Setup is **deferred to the first Connect** (D59), so none of this is a
/// launch state: a first run shows the user their profiles, not a permission
/// dialogue.
public enum SetupState: Sendable, Equatable {
    /// Approved, or not yet needed.
    case ready
    /// The moment before the OS prompt: **our own words first** (D65, D152).
    /// The user pressed Connect, approval is missing, and nothing has been
    /// asked of macOS yet. `again` is D66's case — this Mac approved us once
    /// and the approval is gone — which is an experienced user whose setup
    /// broke, not a first run.
    case explaining(again: Bool)
    /// Asked for, outstanding, and we are watching for it — the window says
    /// what it is waiting on and *notices* when it lands (D61).
    case waitingForApproval
    /// Missing or declined. Everything that is not connecting still works,
    /// and the window says so rather than looking broken (D67–D69).
    case blocked(SetupFailure?)
}

/// Why setup did not complete, in a vocabulary the app can word (4.1). The
/// system's error codes are mapped to these where the request fails, and
/// nothing else about them travels.
public enum SetupFailure: Sendable, Equatable {
    /// The user said *Not now*, or dismissed the OS prompt.
    case declined
    /// The app is not in `/Applications`, which the mechanism requires (C3).
    case wrongLocation(path: String)
    /// A device-management policy forbids the component.
    case forbiddenByPolicy
    /// The bundle failed the system's checks: signature, entitlement,
    /// structure. Nothing the user did; a fresh download is the remedy.
    case damaged
    /// Installed, but macOS wants a restart before it runs.
    case needsRestart
    case unknown
}

/// What the main window is showing. **Derived**, never stored (D93):
///
/// ```
/// window state = f(tunnel state, profiles exist?, setup complete?)
/// ```
///
/// This is what lets the window and the status item agree by construction
/// rather than by two implementations trying to stay in sync — commitment 6,
/// and the highest-frequency commitment in the brief.
public enum WindowState: Sendable, Equatable {
    /// No profiles. What the app needs, where profiles come from, and import
    /// (D22). The same screen when the last profile is removed — not a
    /// different state, and it needs no different words.
    case empty
    /// A5's *One-time setup*: the explanation before the OS prompt, in the
    /// window's centre where Empty is, with the grid put away (D65).
    case setupExplain(again: Bool)
    case setup
    case blocked
    /// Profiles exist and nothing is running: the grid.
    case idle
    /// Something is running. The involved profile is promoted in place (D54)
    /// and the grid below stays live.
    case active
    case failed

    /// Order of precedence, and it is a design decision rather than an
    /// implementation detail:
    ///
    /// 1. **A live tunnel outranks everything.** A window that says "no
    ///    profiles yet" while carrying the user's traffic is a lie, and the
    ///    promoted region is the only place that can offer Disconnect.
    /// 2. **Then no profiles**, because setup is deferred to the first Connect
    ///    (D59) — an empty library has nothing to be blocked about, and A5's
    ///    empty screen deliberately says nothing about permissions.
    /// 3. **Then setup**, which can only arise once a profile exists and
    ///    somebody has pressed Connect.
    /// 4. **Then the tunnel**, which is the ordinary case.
    public static func derive(
        connection: Connection,
        hasProfiles: Bool,
        setup: SetupState
    ) -> WindowState {
        let live = connection.state != .disconnected

        if !hasProfiles, !live { return .empty }

        switch setup {
        case .blocked where !live: return .blocked
        case .waitingForApproval where !live: return .setup
        case .explaining(let again) where !live: return .setupExplain(again: again)
        default: break
        }

        switch connection.state {
        case .failed: return .failed
        case .disconnected: return .idle
        case .connecting, .connected, .disconnecting, .reconnecting: return .active
        }
    }
}
