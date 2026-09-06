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

import Foundation
import NetworkExtension
import os

/// Creates and drives the VPN configuration. M0 needs this only so C4 has a
/// tunnel to run experiments against — the real connection model is
/// docs/ux/state-model.md and arrives with the engine.
@MainActor
final class TunnelController {
    static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "tunnel")

    /// Selects what the provider does. Carried in `providerConfiguration`,
    /// which holds **handles and switches, never secrets** (D191).
    enum Experiment: String, CaseIterable {
        /// Scoped route, no DNS. Safe to kill: it cannot take the machine's
        /// networking with it.
        case scoped
        /// Adds DNS with `matchDomains = [""]` to measure whether that still
        /// captures every query on this macOS version (D197).
        case scopedWithDNS
    }

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
    func prepare(experiment: Experiment) async throws {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existing.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.bossagroove.VPNPlus.tunnel"
        proto.serverAddress = "M0 scaffold"
        proto.providerConfiguration = ["experiment": experiment.rawValue]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "VPN Plus"
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        refreshStatus()
    }

    func connect() throws {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try session.startVPNTunnel()
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
