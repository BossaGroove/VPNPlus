// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 VPN Plus contributors
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

/// Every state a tunnel can be observed in. Six values, and no protocol
/// appears in any of them — see feature-spec 3.1.
public enum TunnelState: String, Sendable, CaseIterable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case reconnecting
    case failed

    /// A terminal state needs the user before anything else happens.
    public var isTerminal: Bool { self == .failed }

    /// Transient states are expected to leave on their own, under a deadline.
    public var isTransient: Bool {
        self == .connecting || self == .disconnecting || self == .reconnecting
    }
}
