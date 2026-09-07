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
    struct Found: CustomStringConvertible {
        let fd: Int32
        let name: String
        var description: String { "\(name) fd=\(fd)" }
    }

    /// Every utun control socket this process holds. There can be more than
    /// one: the extension process outlives a tunnel session, and a descriptor
    /// from an earlier session may still be open.
    static func all() -> [Found] {
        var found: [Found] = []
        for fd in 0..<Int32(getdtablesize()) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(IFNAMSIZ)
            // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2 (<net/if_utun.h>,
            // which the Swift overlay does not expose).
            if getsockopt(fd, 2, 2, &name, &length) == 0 {
                let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                found.append(Found(fd: fd, name: String(decoding: bytes, as: UTF8.self)))
            }
        }
        return found
    }

    /// The descriptor of the utun that carries `address` — the tunnel NE has
    /// just configured — and never a stale one from an earlier session. That
    /// mistake connected an engine to a dead interface once; hence the match.
    static func find(carrying address: String) -> Found? {
        let candidates = all()
        guard let name = interfaceName(withIPv4Address: address) else { return nil }
        return candidates.first { $0.name == name }
    }

    /// The interface currently holding `address`, from getifaddrs.
    static func interfaceName(withIPv4Address address: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ok = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil
            }
            if ok, String(cString: text) == address {
                return String(cString: entry.pointee.ifa_name)
            }
        }
        return nil
    }
}
