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
import Network
import VPNPlusCore

/// Who currently carries traffic off this Mac.
///
/// One primitive, two jobs, and they are the same question asked at two
/// moments:
///
/// - **Before connecting** (D204): if a tunnel already owns the default route,
///   it is not ours — a daemon-based VPN is invisible to `NEVPNStatus` and
///   plainly visible here. Connecting into that silently is the kind of
///   unexplained failure this project exists to remove.
/// - **After tearing down** (D205): `NEVPNStatus` reports Disconnected while
///   routes can persist for up to ~15 s more, so a reconnect verifies a clean
///   path rather than trusting the transition.
///
/// Read through Network.framework rather than the routing table. The provider
/// runs as root, and the interface anything running as root uses should be as
/// small as we can make it — `sysctl(PF_ROUTE)` would mean parsing kernel
/// structures, and shelling out to `netstat` would mean root spawning a shell.
/// This is neither.
enum DefaultRoute {
    enum Owner: Equatable, Sendable {
        /// A physical interface: Wi-Fi, Ethernet, a phone's hotspot.
        case physical(String)
        /// A tunnel, and not one of ours — this is only ever asked before we
        /// have built one, or after we have taken ours down.
        case tunnel(String)
        /// No path at all.
        case none

        var foreignTunnel: String? {
            if case .tunnel(let name) = self { return name }
            return nil
        }
    }

    /// Names that mean "a tunnel" on macOS. `utun` covers NetworkExtension
    /// providers and WireGuard; `ppp` and `ipsec` cover the older daemons that
    /// Tunnelblick and the built-in IPsec client still use.
    private static let tunnelPrefixes = ["utun", "ppp", "ipsec", "tun", "tap"]

    static func isTunnel(_ interface: String) -> Bool {
        tunnelPrefixes.contains { interface.hasPrefix($0) }
    }

    /// Reads it once, waiting at most `timeout` for the first path.
    ///
    /// Bounded because this is on the path to connecting: a question we cannot
    /// answer quickly must not become a reason the user cannot connect. An
    /// unanswered question reports `.none`, and the caller treats that as "we
    /// do not know" rather than as "nothing is there".
    static func owner(timeout: Duration = .milliseconds(500)) -> Owner {
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        // nonisolated(unsafe): written once inside the handler and read once
        // after the semaphore, which is the ordering that makes it sound.
        nonisolated(unsafe) var seen: NWPath?
        monitor.pathUpdateHandler = { path in
            guard seen == nil else { return }
            seen = path
            ready.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.bossagroove.VPNPlus.route"))
        defer { monitor.cancel() }
        _ = ready.wait(timeout: .now() + timeout.timeInterval)
        guard let path = seen, path.status == .satisfied else { return .none }

        // The interfaces come back in the order the system prefers them, so
        // the first is the one carrying traffic.
        guard let primary = path.availableInterfaces.first else { return .none }
        return isTunnel(primary.name) ? .tunnel(primary.name) : .physical(primary.name)
    }

    /// Waits until no tunnel owns the default route, or until it gives up.
    ///
    /// D205's other half. Returns what it saw last, so a caller can say
    /// *"something else still has the route"* rather than pretending the wait
    /// succeeded.
    static func waitForCleanPath(within limit: Duration) -> Owner {
        let deadline = Date().addingTimeInterval(limit.timeInterval)
        var last = owner()
        while last.foreignTunnel != nil, Date() < deadline {
            usleep(200_000)
            last = owner()
        }
        return last
    }
}
