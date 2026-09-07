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

/// The provider without its engine yet: it applies tunnel settings and idles.
/// M2 puts openvpn3 behind it.
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
        // B8 — the whole credential design assumes this process is root.
        // Recorded rather than assumed (C4 confirmed uid=0).
        log.notice("provider start uid=\(getuid(), privacy: .public) euid=\(geteuid(), privacy: .public)")
        // M1's proof that the engine is linked into this process.
        log.notice("engine openvpn3 \(String(cString: vpnplus_engine_version()), privacy: .public) (\(String(cString: vpnplus_engine_platform()), privacy: .public))")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1400

        // A narrow included route, never a default route, while there is no
        // engine behind the tunnel: nothing here may take the machine's
        // networking with it.
        let ipv4 = NEIPv4Settings(addresses: ["10.99.99.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.99.99.0", subnetMask: "255.255.255.0")
        ]
        // D207 — assigned last: the settings properties copy on assignment.
        settings.ipv4Settings = ipv4

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
        // removes them. B14 and C4 measured that this holds even when the
        // provider is killed outright, which is the argument for this mechanism.
        log.notice("provider stop reason=\(reason.rawValue, privacy: .public)")
        completionHandler()
    }
}
