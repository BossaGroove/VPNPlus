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

/// A step inside `.connecting`, supplied by the protocol adapter rather than
/// assumed by the core: OpenVPN reports five, WireGuard one (D183, D184).
public struct TunnelPhase: Sendable, Equatable, Identifiable {
    public let id: String
    public let deadline: Duration

    public init(id: String, deadline: Duration) {
        self.id = id
        self.deadline = deadline
    }
}

/// Deadlines live in one place and are tunable without touching logic
/// (feature-spec 3.6). The engine's own retry behaviour is never the
/// user-facing timeout (D177) — these are.
///
/// **These values are measured, not guessed.** A8's table proposed
/// `auth` 30 s and `setup` 15 s before anything had been timed; feature-spec
/// 3.15 then measured ~20 connections against a production server — 0.13 s to
/// reach it, a **4.0 s TLS handshake**, 1.6 s for the configuration, 0.10 s to
/// apply it, 5.7–6.5 s in total. The values below are sized against that, so
/// where they disagree with A8 it is the older number that is out of date.
public enum Deadlines {
    public static let resolve = Duration.seconds(10)
    public static let contact = Duration.seconds(15)
    public static let auth = Duration.seconds(20)
    public static let config = Duration.seconds(20)
    public static let setup = Duration.seconds(10)

    /// The whole attempt, whatever phase it is in.
    public static let attempt = Duration.seconds(60)

    /// How long a phase runs before it is named to the user (D71).
    public static let phaseReveal = Duration.seconds(2)

    /// Then force the teardown and restore anyway (D39). A tunnel that will
    /// not come down is not a reason to leave the system half-configured —
    /// which is the state that makes the owner disconnect defensively every
    /// night.
    public static let disconnect = Duration.seconds(10)
}
