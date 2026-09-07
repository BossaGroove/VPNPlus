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
import NetworkExtension
import os

/// Creates and drives the VPN configuration. The real connection model
/// (docs/ux/state-model.md) arrives with the engine in M2 and M5; this is the
/// minimum needed to start and stop the tunnel and observe its status.
@MainActor
final class TunnelController {
    static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "tunnel")

    private(set) var status: NEVPNStatus = .invalid {
        didSet { if status != oldValue { onChange?(status) } }
    }

    var onChange: ((NEVPNStatus) -> Void)?

    private var manager: NETunnelProviderManager?

    // Written once on the main actor in `init`, read once in `deinit`, which
    // Swift 6 runs nonisolated. There is no window for concurrent access, and
    // the alternative — dropping the deinit because this object happens to
    // live for the app's lifetime — would be true today and a leak later.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            // D75 — observe, never assume. This is also how a connect made
            // from System Settings reaches us.
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Loads the existing configuration or creates one. Saving is what raises
    /// the "would like to add VPN configurations" prompt — C4 counts it.
    func prepare() async throws {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existing.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.bossagroove.VPNPlus.tunnel"
        // Shown by System Settings; the first `remote` of the profile once one
        // is stored (M3). Until then, the app's name.
        proto.serverAddress = "VPN Plus"
        // Handles and switches only, never secrets (D191). Nothing yet.
        proto.providerConfiguration = [:]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "VPN Plus"
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        refreshStatus()
    }

    /// M2 ONLY — the profile text and credentials ride in the start options.
    /// M3 stores profiles and M4 puts credentials behind the XPC interface;
    /// until then nothing here persists, and a start from System Settings has
    /// nothing to connect with (D75 is knowingly broken in M2).
    func connect(profile: String, username: String, password: String) throws {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        var options: [String: NSObject] = ["profile": profile as NSString]
        if !username.isEmpty { options["username"] = username as NSString }
        if !password.isEmpty { options["password"] = password as NSString }
        try session.startVPNTunnel(options: options)
    }

    func disconnect() {
        (manager?.connection as? NETunnelProviderSession)?.stopVPNTunnel()
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
    }
}

extension NEVPNStatus {
    var plainLanguage: String {
        switch self {
        case .invalid: "Not set up"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reasserting: "Reconnecting"
        case .disconnecting: "Disconnecting"
        @unknown default: "Unknown"
        }
    }
}
