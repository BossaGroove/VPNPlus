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

/// The engine, as Swift sees it: a thin owner of the C handle from
/// VPNPlusEngine.h. No openvpn3 type appears here or anywhere past this file
/// (D179).
///
/// Threading: `run()` blocks the calling thread for the life of the connection
/// and every callback fires on that thread. Callers hop to wherever they need.
final class Engine: @unchecked Sendable {
    struct Event: Sendable {
        let name: String
        let info: String
        let isError: Bool
        let isFatal: Bool
    }

    struct Address: Sendable {
        let address: String
        let prefixLength: Int
        let gateway: String
        let isIPv6: Bool
    }

    struct Route: Sendable {
        let address: String
        let prefixLength: Int
        let isIPv6: Bool
    }

    /// What the server pushed, ready to become NEPacketTunnelNetworkSettings.
    struct Settings: Sendable {
        let remoteAddress: String
        let remoteIsIPv6: Bool
        let sessionName: String
        let mtu: Int
        let addresses: [Address]
        let includedRoutes: [Route]
        let excludedRoutes: [Route]
        let rerouteIPv4: Bool
        let rerouteIPv6: Bool
        let blockIPv6: Bool
        let dnsServers: [String]
        let searchDomains: [String]
    }

    struct ConnectionInfo: Sendable {
        let user, serverHost, serverPort, serverProto, serverIP: String
        let vpnIPv4, vpnIPv6, gateway4, gateway6, clientIP, tunName: String
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    var onLog: (@Sendable (String) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)?
    /// Apply the settings and return a tunnel descriptor, or nil to fail.
    var onEstablish: (@Sendable (Settings) -> Int32?)?
    var onTeardown: (@Sendable (Bool) -> Void)?

    private var handle: OpaquePointer?

    init(clientVersion: String) {
        var callbacks = vpnplus_engine_callbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.log = { context, text in
            guard let context, let text else { return }
            Engine.from(context).onLog?(String(cString: text))
        }
        callbacks.event = { context, name, info, error, fatal in
            guard let context else { return }
            Engine.from(context).onEvent?(Event(
                name: name.map { String(cString: $0) } ?? "",
                info: info.map { String(cString: $0) } ?? "",
                isError: error, isFatal: fatal))
        }
        callbacks.establish = { context, settings in
            guard let context, let settings else { return -1 }
            let engine = Engine.from(context)
            return engine.onEstablish?(Engine.settings(from: settings.pointee)) ?? -1
        }
        callbacks.teardown = { context, disconnect in
            guard let context else { return }
            Engine.from(context).onTeardown?(disconnect)
        }
        handle = vpnplus_engine_create(&callbacks, clientVersion)
    }

    deinit {
        // Destroying the engine is what closes the descriptor it owns; a
        // leaked Engine is a leaked utun. The provider logs this.
        if let handle { vpnplus_engine_destroy(handle) }
    }

    private static func from(_ context: UnsafeMutableRawPointer) -> Engine {
        Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
    }

    /// Evaluates the profile and stores the credentials. Throws with the
    /// engine's own reason.
    func prepare(profile: String, username: String?, password: String?) throws {
        guard let handle else { throw Failure(message: "The engine could not be created.") }
        var message = [CChar](repeating: 0, count: 1024)
        let ok = vpnplus_engine_prepare(handle, profile, username, password, &message, message.count)
        if !ok { throw Failure(message: Self.string(message)) }
    }

    /// Connects and returns when the connection has ended.
    func run() -> Result<Void, Failure> {
        guard let handle else { return .failure(Failure(message: "The engine could not be created.")) }
        var message = [CChar](repeating: 0, count: 1024)
        let ok = vpnplus_engine_run(handle, &message, message.count)
        return ok ? .success(()) : .failure(Failure(message: Self.string(message)))
    }

    func stop() { if let handle { vpnplus_engine_stop(handle) } }
    func pause(reason: String) { if let handle { vpnplus_engine_pause(handle, reason) } }
    func resume() { if let handle { vpnplus_engine_resume(handle) } }
    func reconnect(after seconds: Int) { if let handle { vpnplus_engine_reconnect(handle, Int32(seconds)) } }

    var connectionInfo: ConnectionInfo? {
        guard let handle else { return nil }
        var raw = vpnplus_connection_info()
        guard vpnplus_engine_connection_info(handle, &raw) else { return nil }
        func s<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { buf in
                String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return ConnectionInfo(
            user: s(raw.user), serverHost: s(raw.server_host), serverPort: s(raw.server_port),
            serverProto: s(raw.server_proto), serverIP: s(raw.server_ip),
            vpnIPv4: s(raw.vpn_ip4), vpnIPv6: s(raw.vpn_ip6), gateway4: s(raw.gateway4),
            gateway6: s(raw.gateway6), clientIP: s(raw.client_ip), tunName: s(raw.tun_name))
    }

    /// Bytes and packets the transport has carried this session.
    var transportCounters: (bytesIn: Int64, bytesOut: Int64) {
        guard let handle else { return (0, 0) }
        var stats = vpnplus_transport_stats()
        vpnplus_engine_transport_stats(handle, &stats)
        return (stats.bytes_in, stats.bytes_out)
    }

    /// Milliseconds since the last packet arrived, or nil before the first.
    var millisecondsSinceLastPacket: Int? {
        guard let handle else { return nil }
        var stats = vpnplus_transport_stats()
        vpnplus_engine_transport_stats(handle, &stats)
        // The engine counts in binary milliseconds (1/1024 s).
        return stats.last_packet_received < 0 ? nil : Int(stats.last_packet_received) * 1000 / 1024
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func settings(from c: vpnplus_tun_settings) -> Settings {
        func str(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        func strings(_ p: UnsafePointer<UnsafePointer<CChar>?>?, _ n: Int) -> [String] {
            guard let p, n > 0 else { return [] }
            return (0..<n).map { str(p[$0]) }
        }
        func routes(_ p: UnsafePointer<vpnplus_route>?, _ n: Int) -> [Route] {
            guard let p, n > 0 else { return [] }
            return (0..<n).map { Route(address: str(p[$0].address), prefixLength: Int(p[$0].prefix_length), isIPv6: p[$0].ipv6) }
        }
        var addresses: [Address] = []
        if let p = c.addresses {
            for i in 0..<Int(c.address_count) {
                addresses.append(Address(address: str(p[i].address), prefixLength: Int(p[i].prefix_length),
                                         gateway: str(p[i].gateway), isIPv6: p[i].ipv6))
            }
        }
        return Settings(
            remoteAddress: str(c.remote_address), remoteIsIPv6: c.remote_ipv6,
            sessionName: str(c.session_name), mtu: Int(c.mtu), addresses: addresses,
            includedRoutes: routes(c.included_routes, Int(c.included_route_count)),
            excludedRoutes: routes(c.excluded_routes, Int(c.excluded_route_count)),
            rerouteIPv4: c.reroute_ipv4, rerouteIPv6: c.reroute_ipv6, blockIPv6: c.block_ipv6,
            dnsServers: strings(c.dns_servers, Int(c.dns_server_count)),
            searchDomains: strings(c.search_domains, Int(c.search_domain_count)))
    }
}
