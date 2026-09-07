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
import SystemConfiguration
import os

/// M1.3 SPIKE ONLY — removed in M1.4. Must not ship.
///
/// Answers C4's question 2 without an OpenVPN server. With the tunnel holding
/// the default route and nothing behind it, a UDP socket opened inside this
/// provider either leaves through the physical interface or falls into our own
/// `packetFlow`. Two probes, one DNS query each to 192.0.2.53:
///
/// - **bound**: `IP_BOUND_IF` to the interface that held the default route
///   before the tunnel took it — candidate 1 for `socket_protect`.
/// - **unbound**: nothing special — candidate 2, "the provider's own traffic
///   is excluded anyway".
///
/// A reply is the pass for a probe. `connect()` before sending also makes the
/// kernel choose the source address up front, so the log shows which way each
/// socket was routed before a byte left.
final class SocketProtectProbe: Sendable {
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "spike")

    struct Result: Sendable {
        let label: String
        let source: String
        let replied: Bool
        let error: String?
    }

    /// The interface currently holding the default route, from the same store
    /// openvpn3's `MacGatewayInfo` reads. Call it before the tunnel is up.
    static func primaryInterface() -> (name: String, index: UInt32)? {
        guard let store = SCDynamicStoreCreate(nil, "VPNPlus.spike" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
              let name = dict["PrimaryInterface"] as? String
        else { return nil }
        let index = if_nametoindex(name)
        return index == 0 ? nil : (name, index)
    }

    /// One DNS query for example.com to 192.0.2.53:53, two seconds for a reply.
    func probe(label: String, id: UInt16, boundTo ifIndex: UInt32?) -> Result {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return fail(label, "socket errno=\(errno)") }
        defer { close(fd) }

        if var index = ifIndex {
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
            else { return fail(label, "IP_BOUND_IF errno=\(errno)") }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(53).bigEndian
        dst.sin_addr.s_addr = inet_addr("192.0.2.53")
        let connected = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return fail(label, "connect errno=\(errno)") }

        var src = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &src) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let source = String(cString: inet_ntoa(src.sin_addr))

        let query = Self.dnsQuery(id: id)
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == query.count else {
            return Result(label: label, source: source, replied: false, error: "send errno=\(errno)")
        }
        var reply = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &reply, reply.count, 0)
        let replied = n >= 12 && reply[0] == UInt8(id >> 8) && reply[1] == UInt8(id & 0xff)
        return Result(label: label, source: source, replied: replied,
                      error: n < 0 ? "recv errno=\(errno)" : nil)
    }

    private func fail(_ label: String, _ error: String) -> Result {
        Result(label: label, source: "-", replied: false, error: error)
    }

    /// A minimal DNS query: header, one question (example.com, A, IN).
    static func dnsQuery(id: UInt16) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["example", "com"] {
            q.append(UInt8(label.utf8.count))
            q.append(contentsOf: Array(label.utf8))
        }
        q.append(contentsOf: [0, 0, 1, 0, 1])
        return q
    }

    /// If `packet` is an IPv4 UDP datagram to port 53, its DNS id.
    static func dnsID(inIPv4Packet packet: Data) -> UInt16? {
        let b = [UInt8](packet)
        guard b.count >= 20, b[0] >> 4 == 4, b[9] == 17 else { return nil }
        let ihl = Int(b[0] & 0x0f) * 4
        guard b.count >= ihl + 10 else { return nil }
        let dstPort = UInt16(b[ihl + 2]) << 8 | UInt16(b[ihl + 3])
        guard dstPort == 53 else { return nil }
        return UInt16(b[ihl + 8]) << 8 | UInt16(b[ihl + 9])
    }
}
