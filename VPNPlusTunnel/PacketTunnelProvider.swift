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

/// M0's provider, carrying the M1.3 spike. It applies tunnel settings and idles — no engine.
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
        let ipv4 = NEIPv4Settings(addresses: ["10.99.99.2"], subnetMasks: ["255.255.255.0"])
        settings.mtu = 1400

        // M1.3 SPIKE ONLY — removed in M1.4. Must not ship.
        //
        // `socketProtect` takes the DEFAULT route with nothing behind it: for the
        // few seconds it runs, this Mac has no internet. The provider ends the
        // tunnel itself once both probes have reported.
        let spike = experiment == "socketProtect"
        let primary = spike ? SocketProtectProbe.primaryInterface() : nil
        if spike {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            log.notice("spike: primary interface before tunnel = \(primary?.name ?? "none", privacy: .public) index=\(primary?.index ?? 0, privacy: .public)")
        } else {
            // A narrow included route, never a default route: a kill test must not
            // be able to take the machine's networking with it.
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "10.99.99.0", subnetMask: "255.255.255.0")
            ]
        }
        // Assigned LAST: the settings properties copy on assignment, so a route
        // added to `ipv4` after this line never reaches the tunnel. Build 2 of
        // the spike measured exactly that — a tunnel with no routes at all.
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [self] error in
            if let error {
                log.error("setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("settings applied; included routes=\(settings.ipv4Settings?.includedRoutes?.count ?? -1, privacy: .public)")
            }
            completionHandler(error)
            if error == nil, spike {
                // Proof the default route took: the primary interface must now
                // be the tunnel, not en0. Without this line a no-route tunnel
                // would pass both probes and prove nothing.
                let now = SocketProtectProbe.primaryInterface()
                log.notice("spike: primary interface after settings = \(now?.name ?? "none", privacy: .public) index=\(now?.index ?? 0, privacy: .public)")
                runSocketProtectSpike(primary: primary)
            }
        }
    }

    // MARK: - M1.3 spike — removed in M1.4

    private func runSocketProtectSpike(primary: (name: String, index: UInt32)?) {
        watchPacketFlow()
        let probe = SocketProtectProbe()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            var results: [SocketProtectProbe.Result] = []
            if let primary {
                results.append(probe.probe(label: "bound", id: 0xA1A1, boundTo: primary.index))
            } else {
                log.error("spike: no primary interface; the bound probe cannot run")
            }
            results.append(probe.probe(label: "unbound", id: 0xB2B2, boundTo: nil))
            for r in results {
                log.notice("spike RESULT \(r.label, privacy: .public): source=\(r.source, privacy: .public) replied=\(r.replied, privacy: .public) \(r.error ?? "", privacy: .public)")
            }
            // Give the packet-flow reader a moment to log anything that fell
            // into the tunnel, then hand the network back.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                log.notice("spike: done, ending the tunnel")
                cancelTunnelWithError(nil)
            }
        }
    }

    /// Logs every DNS query that arrives in the tunnel instead of leaving the
    /// machine — the other half of the measurement.
    private func watchPacketFlow() {
        packetFlow.readPackets { [self] packets, protocols in
            for (packet, proto) in zip(packets, protocols) where proto.int32Value == AF_INET {
                if let id = SocketProtectProbe.dnsID(inIPv4Packet: packet) {
                    log.notice("spike: packetFlow received a DNS query id=0x\(String(id, radix: 16, uppercase: true), privacy: .public) — it went INTO the tunnel")
                }
            }
            watchPacketFlow()
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
