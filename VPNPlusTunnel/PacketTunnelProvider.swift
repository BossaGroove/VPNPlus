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

import NetworkExtension
import os

/// M0's provider. It applies tunnel settings and idles — no engine.
///
/// That is deliberate. C4 needs to measure what macOS does when the provider
/// dies, what user it runs as, and whether `matchDomains` still captures every
/// query. None of those need openvpn3, and leaving it out keeps C4 one
/// milestone away instead of behind the dependency build.
///
/// The completion-handler overrides are not a style choice: under Swift 6
/// strict concurrency the `async` forms cannot be overridden here, because
/// `[String: NSObject]?` is not Sendable and the superclass method is
/// nonisolated.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "provider")

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // C4 / B8 — the whole credential design assumes this process is root.
        // Recorded rather than assumed; read it with:
        //   log show --predicate 'subsystem == "com.bossagroove.VPNPlus"'
        log.notice("provider start uid=\(getuid(), privacy: .public) euid=\(geteuid(), privacy: .public)")

        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let experiment = (config?["experiment"] as? String) ?? "scoped"
        log.notice("experiment=\(experiment, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // A narrow included route, never a default route: a kill test must not
        // be able to take the machine's networking with it.
        let ipv4 = NEIPv4Settings(addresses: ["10.99.99.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.99.99.0", subnetMask: "255.255.255.0")
        ]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        // M0 ONLY — C4 harness, removed with the engine in M1. Must not ship.
        if experiment == "scopedWithDNS" {
            // D197 — matchDomains [""] is the documented way to capture every
            // query, and is reported to have behaved inconsistently since
            // Ventura. C4 measures it rather than trusting it.
            let dns = NEDNSSettings(servers: ["10.99.99.53"])
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }

        setTunnelNetworkSettings(settings) { [log] error in
            if let error {
                log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("settings applied")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // Nothing of ours to undo: the OS applied the settings and the OS
        // removes them. B14 measured that this holds even when the provider is
        // killed outright, which is the whole argument for this mechanism.
        log.notice("provider stop reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }
}
