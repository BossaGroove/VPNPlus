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
}
