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
import VPNPlusCore

/// Reads `NetworkFacts` from this Mac.
///
/// **Unprivileged, promptless, and with no network call**: a `PF_ROUTE` dump
/// for the default route, the same dump with `RTF_LLINFO` for the gateway's
/// ARP entry, `getifaddrs` for the interface and the mask, and
/// SystemConfiguration for the interface's kind. Measured on the owner's Mac
/// in B9 before any of it was shipped, and this is that spike promoted with
/// its two corrections kept:
///
/// - **`sdl_type` reports Wi-Fi as `IFT_ETHER`.** The BSD link-layer type
///   cannot tell Wi-Fi from Ethernet on modern macOS, and A7's diagnosis
///   branches on exactly that, so the kind comes from
///   `SCNetworkInterfaceGetInterfaceType` (D200).
/// - **macOS elides trailing zero bytes in a netmask `sockaddr`.** `sa_len`
///   can be 5, so parsing it as a whole `sockaddr_in` yields nothing and a
///   `/8` or `/16` reads as "no subnet" — which looked like an API that does
///   not work.
///
/// Both the app and the extension read these: the extension **before the
/// tunnel changes routing** (D201), which is the only moment the answer is
/// about the physical network, and the app when the sheet asks what is true
/// now.
enum NetworkFactsReader {
    static func read(at when: Date = Date()) -> NetworkFacts {
        let route = defaultRoute()
        let interface = route.interfaceIndex.flatMap(name(ofInterface:))
        let addresses = interface.map(addresses(of:)) ?? (mac: nil, mask: nil)
        return NetworkFacts(
            at: when,
            interfaceName: interface,
            interfaceKind: kind(of: interface, hasRoute: route.gateway != nil),
            gateway: route.gateway,
            gatewayHardwareAddress: route.gateway.flatMap(hardwareAddress(ofGateway:)),
            subnetMask: addresses.mask,
            hardwareAddress: addresses.mac,
            addressIsRandomised: addresses.mac.flatMap(isLocallyAdministered))
    }

    /// The locally-administered bit: set means macOS made this address up,
    /// which is what Private Wi-Fi Address does (D91, D203). One bit, no
    /// extra API, and nothing that could look like snooping.
    static func isLocallyAdministered(_ address: String) -> Bool? {
        guard let first = UInt8(address.prefix(2), radix: 16) else { return nil }
        return first & 0x02 != 0
    }

    /// A netmask as macOS actually stores it: `sa_len` counts only the bytes
    /// that are not zero, so the rest are zero by omission.
    static func mask(fromSockaddr bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        var octets: [UInt8] = [0, 0, 0, 0]
        for index in 0..<4 where 4 + index < bytes.count { octets[index] = bytes[4 + index] }
        return octets.map(String.init).joined(separator: ".")
    }

    // MARK: - The route table

    private struct Route {
        var gateway: String?
        var interfaceIndex: UInt16?
    }

    private static func defaultRoute() -> Route {
        var route = Route()
        let dump = routeDump(flags: 0, kind: NET_RT_DUMP)
        dump.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= raw.count {
                let header = raw.baseAddress!.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self).pointee
                guard header.rtm_msglen > 0 else { break }
                if header.rtm_flags & RTF_GATEWAY != 0, header.rtm_addrs & (1 << RTAX_DST) != 0 {
                    let parts = sockaddrs(
                        raw.baseAddress!.advanced(by: offset + MemoryLayout<rt_msghdr>.size),
                        header.rtm_addrs)
                    if let destination = parts[Int32(RTAX_DST)], ipv4(destination) == "0.0.0.0",
                        let gateway = parts[Int32(RTAX_GATEWAY)]
                    {
                        route.gateway = ipv4(gateway)
                        route.interfaceIndex = header.rtm_index
                    }
                }
                offset += Int(header.rtm_msglen)
            }
        }
        return route
    }

    /// The gateway's own hardware address, from the ARP cache — the thing
    /// that identifies the router rather than the address space (D89).
    private static func hardwareAddress(ofGateway gateway: String) -> String? {
        var found: String?
        let dump = routeDump(flags: RTF_LLINFO, kind: NET_RT_FLAGS)
        dump.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr2>.size <= raw.count {
                let header = raw.baseAddress!.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr2.self).pointee
                guard header.rtm_msglen > 0 else { break }
                let parts = sockaddrs(
                    raw.baseAddress!.advanced(by: offset + MemoryLayout<rt_msghdr2>.size),
                    header.rtm_addrs)
                if let destination = parts[Int32(RTAX_DST)], ipv4(destination) == gateway,
                    let link = parts[Int32(RTAX_GATEWAY)]
                {
                    found = mac(link)
                }
                offset += Int(header.rtm_msglen)
            }
        }
        return found
    }

    private static func routeDump(flags: Int32, kind: Int32) -> [UInt8] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, kind, flags]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [] }
        return Array(buffer[0..<length])
    }

    /// The addresses a route message carries, by `RTAX_*` slot. Each is
    /// padded to a four-byte boundary, and a zero length means four bytes.
    private static func sockaddrs(_ start: UnsafeRawPointer, _ present: Int32) -> [Int32: Data] {
        var found: [Int32: Data] = [:]
        var cursor = start
        for slot in Int32(0)..<Int32(RTAX_MAX) {
            guard present & (1 << slot) != 0 else { continue }
            let address = cursor.assumingMemoryBound(to: sockaddr.self)
            let length = Int(address.pointee.sa_len)
            found[slot] = Data(bytes: cursor, count: max(length, 0))
            cursor = cursor.advanced(by: length > 0 ? (length + 3) & ~3 : 4)
        }
        return found
    }

    // MARK: - Interfaces

    private static func name(ofInterface index: UInt16) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if if_nametoindex(current.pointee.ifa_name) == UInt32(index) {
                return String(cString: current.pointee.ifa_name)
            }
            cursor = current.pointee.ifa_next
        }
        return nil
    }

    private static func addresses(of interface: String) -> (mac: String?, mask: String?) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (nil, nil) }
        defer { freeifaddrs(list) }
        var hardware: String?
        var netmask: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                let address = current.pointee.ifa_addr
            else { continue }
            if address.pointee.sa_family == UInt8(AF_LINK) {
                hardware = mac(Data(bytes: address, count: Int(address.pointee.sa_len)))
            } else if address.pointee.sa_family == UInt8(AF_INET),
                let mask = current.pointee.ifa_netmask
            {
                let bytes = Data(bytes: mask, count: max(Int(mask.pointee.sa_len), 8))
                netmask = Self.mask(fromSockaddr: Array(bytes))
            }
        }
        return (hardware, netmask)
    }

    /// D200: from SystemConfiguration, never from `sdl_type`.
    private static func kind(of interface: String?, hasRoute: Bool) -> NetworkFacts.InterfaceKind {
        guard let interface, hasRoute else { return .none }
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return .other }
        for candidate in all
        where (SCNetworkInterfaceGetBSDName(candidate) as String?) == interface {
            let type = SCNetworkInterfaceGetInterfaceType(candidate) as String?
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { return .wiFi }
            if type == kSCNetworkInterfaceTypeEthernet as String { return .ethernet }
            return .other
        }
        return .other
    }

    // MARK: - Bytes

    private static func ipv4(_ bytes: Data) -> String? {
        guard bytes.count >= 8 else { return nil }
        return bytes.withUnsafeBytes { raw -> String? in
            var address = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: text)
        }
    }

    private static func mac(_ bytes: Data) -> String? {
        guard bytes.count >= MemoryLayout<sockaddr_dl>.size - 12 else { return nil }
        return bytes.withUnsafeBytes { raw -> String? in
            let link = raw.baseAddress!.assumingMemoryBound(to: sockaddr_dl.self).pointee
            guard link.sdl_alen == 6 else { return nil }
            let start = raw.baseAddress!.advanced(by: 8 + Int(link.sdl_nlen))
                .assumingMemoryBound(to: UInt8.self)
            return (0..<6).map { String(format: "%02x", start[$0]) }.joined(separator: ":")
        }
    }
}
