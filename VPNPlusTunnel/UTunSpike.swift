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
import os

/// M2.1 SPIKE ONLY — removed before M2.2 lands. Must not ship as is.
///
/// openvpn3's tun builder ends in `tun_builder_establish() -> fd`: the engine
/// wants a descriptor it can read and write raw IP packets on. A packet tunnel
/// provider is handed `packetFlow` instead — but the utun that backs it is a
/// control socket in this very process. WireGuard's Apple client finds it by
/// asking every descriptor for its utun name. This spike does the same, then
/// proves both directions by answering pings on the descriptor directly.
enum UTunSpike {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "spike")

    /// The utun control socket among this process's descriptors, if any.
    static func findDescriptor() -> (fd: Int32, name: String)? {
        for fd in 0..<Int32(getdtablesize()) {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(IFNAMSIZ)
            // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2 (<net/if_utun.h>, not
            // in the Swift overlay).
            if getsockopt(fd, 2, 2, &name, &length) == 0 {
                return (fd, String(cString: name))
            }
        }
        return nil
    }

    /// Reads packets from the descriptor and answers IPv4 echo requests.
    /// Each utun frame is a 4-byte address family in network order, then the
    /// IP packet.
    static func answerPings(on fd: Int32) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var seen = 0
            // NE leaves the descriptor non-blocking (the first read returned
            // EAGAIN), which is what an asio-based engine wants anyway. Wait
            // with poll(), then read.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                let ready = poll(&pfd, 1, 5000)
                if ready == 0 { continue }
                guard ready > 0 else {
                    log.error("spike: poll errno=\(errno, privacy: .public)")
                    return
                }
                let n = read(fd, &buffer, buffer.count)
                if n < 0, errno == EAGAIN { continue }
                guard n > 4 else {
                    log.error("spike: read returned \(n, privacy: .public) errno=\(errno, privacy: .public)")
                    return
                }
                let family = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
                var packet = Array(buffer[4..<n])
                seen += 1
                if seen <= 3 || seen % 50 == 0 {
                    log.notice("spike: read frame #\(seen, privacy: .public) family=\(family, privacy: .public) bytes=\(packet.count, privacy: .public)")
                }
                guard family == UInt32(AF_INET), packet.count >= 28, packet[0] >> 4 == 4, packet[9] == 1 else { continue }
                let ihl = Int(packet[0] & 0x0f) * 4
                guard packet.count >= ihl + 8, packet[ihl] == 8 else { continue }
                // Echo request → echo reply: swap addresses, change the type,
                // fix the ICMP checksum. The IP checksum is unchanged by a swap.
                for i in 0..<4 { packet.swapAt(12 + i, 16 + i) }
                packet[ihl] = 0
                packet[ihl + 2] = 0; packet[ihl + 3] = 0
                let sum = checksum(packet[ihl...])
                packet[ihl + 2] = UInt8(sum >> 8); packet[ihl + 3] = UInt8(sum & 0xff)
                let frame = buffer[0..<4] + packet
                let written = frame.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                let id = UInt16(packet[ihl + 4]) << 8 | UInt16(packet[ihl + 5])
                let seq = UInt16(packet[ihl + 6]) << 8 | UInt16(packet[ihl + 7])
                log.notice("spike: echo reply id=\(id, privacy: .public) seq=\(seq, privacy: .public) wrote=\(written, privacy: .public)")
            }
        }
    }

    private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        var it = bytes.makeIterator()
        while let hi = it.next() {
            let lo = it.next() ?? 0
            sum += UInt32(hi) << 8 | UInt32(lo)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
