// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 VPN Plus contributors
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

/// M0's provider. It applies a **scoped** set of tunnel settings and then
/// idles — no engine, no default route, no DNS.
///
/// That is deliberate. C4 needs to measure what macOS does with these settings
/// when the provider dies, and none of those measurements need openvpn3. Using
/// a narrow included route rather than a default route means the experiment
/// cannot take the machine's networking with it.
///
/// The completion-handler overrides are not a style choice: under Swift 6
/// strict concurrency the `async` forms cannot be overridden here, because
/// `[String: NSObject]?` is not Sendable and the superclass method is
/// nonisolated.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.99.99.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "10.99.99.0", subnetMask: "255.255.255.0")
        ]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400

        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        // Nothing of ours to undo: the OS applied the settings and the OS
        // removes them. B14 measured that this holds even when the provider is
        // killed outright, which is the whole argument for this mechanism.
        completionHandler()
    }
}
