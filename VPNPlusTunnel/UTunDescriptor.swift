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

/// The utun interface behind this provider's tunnel, as a file descriptor.
///
/// openvpn3's tun builder ends in `tun_builder_establish() -> fd`: the engine
/// reads and writes raw IP packets on a descriptor it owns. A packet tunnel
/// provider is handed `packetFlow` instead, but the utun that backs it is a
/// control socket in this very process, and it answers `UTUN_OPT_IFNAME`.
/// Asking every descriptor finds it (D209). WireGuard's Apple client hands its
/// engine a descriptor the same way.
///
/// Only meaningful after `setTunnelNetworkSettings` has completed — the utun
/// is created by that call. The descriptor is non-blocking; frames carry a
/// 4-byte address family in network order before the IP packet.
enum UTunDescriptor {
    static func find() -> (fd: Int32, name: String)? {
        for fd in 0..<Int32(getdtablesize()) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(IFNAMSIZ)
            // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2 (<net/if_utun.h>,
            // which the Swift overlay does not expose).
            if getsockopt(fd, 2, 2, &name, &length) == 0 {
                return (fd, String(cString: name))
            }
        }
        return nil
    }
}
