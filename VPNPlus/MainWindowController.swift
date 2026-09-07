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

import AppKit
import NetworkExtension
import VPNPlusCore

/// M0's only screen. It says what the extension is doing and gives C4 a way to
/// start and stop a tunnel. The real main window is designed in
/// docs/ux/screen-main.md and built with the engine.
@MainActor
final class MainWindowController: NSWindowController {
    private let installer = ExtensionInstaller(identifier: "com.bossagroove.VPNPlus.tunnel")
    private let tunnel = TunnelController()
    private let store: any ProfileStore = StoredProfileStore.live
    private lazy var importer = ProfileImporter(store: store)

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let tunnelLabel = NSTextField(labelWithString: "Tunnel: not set up")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)

    // M3 ONLY — a provisional surface. Import is real and stores profiles; the
    // list, the picker and the configuration sheet the design calls for arrive
    // with M3.5 and M5. Credentials are still typed each time, until M4.
    private let importButton = NSButton(title: "", target: nil, action: nil)
    private let profileLabel = NSTextField(labelWithString: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VPN Plus"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 620, height: 440)
        super.init(window: window)

        buildLayout()
        acceptDrops()
        importer.onChange = { [weak self] in self?.renderProfiles() }
        installer.onChange = { [weak self] in self?.render($0) }
        tunnel.onChange = { [weak self] in self?.renderTunnel($0) }
        render(installer.status)
        renderProfiles()
        installer.activate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The window accepts a dropped profile (2.1).
    private func acceptDrops() {
        guard let content = window?.contentView else { return }
        let target = DropView(frame: content.bounds)
        target.autoresizingMask = [.width, .height]
        target.onDrop = { [weak self] url in self?.importProfile(at: url) }
        content.addSubview(target, positioned: .below, relativeTo: nil)
    }

    private func buildLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 480
        tunnelLabel.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(connect)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)

        importButton.title = String(localized: "Import Profile…")
        importButton.target = self
        importButton.action = #selector(importProfileFromPanel(_:))
        profileLabel.textColor = .secondaryLabelColor
        usernameField.placeholderString = "Username (if the profile asks)"
        passwordField.placeholderString = "Password"
        for field in [usernameField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        let testPath = NSStackView(views: [importButton, profileLabel])
        testPath.orientation = .horizontal
        testPath.spacing = 8

        let buttons = NSStackView(views: [connectButton, disconnectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [statusLabel, detailLabel, tunnelLabel, testPath, usernameField, passwordField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    /// File > Import Profile…, and the button (2.1).
    @objc func importProfileFromPanel(_ sender: Any?) {
        importer.chooseFile(over: window)
    }

    /// A profile double-clicked in the Finder or dropped on the app icon (2.1).
    func importProfile(at url: URL) {
        importer.importProfile(at: url, over: window)
    }

    private func renderProfiles() {
        let profiles = (try? store.profiles()) ?? []
        guard let first = profiles.first else {
            profileLabel.stringValue = String(localized: "No profiles yet — import one, or drop it on this window")
            return
        }
        let waived = first.waivedDirectives.count
        // A count, never a buried list (D187). The list is one click behind it,
        // in the import sheet now and in the profile's own surface at M5.
        profileLabel.stringValue = profiles.count == 1
            ? (waived == 0
                ? first.title
                : String(localized: "\(first.title) — \(waived) settings not used"))
            : String(localized: "\(profiles.count) profiles, starting with \(first.title)")
    }

    @objc private func connect() {
        // M3.5 turns this into a selection; for now the first stored profile is
        // the one that connects, which is already better than a file picker
        // per run.
        guard let profile = (try? store.profiles())?.first,
              let configuration = try? store.configuration(for: profile.id),
              let text = String(data: configuration, encoding: .utf8)
        else {
            tunnelLabel.stringValue = String(localized: "Import a profile first")
            return
        }
        Task {
            do {
                try await tunnel.prepare()
                try tunnel.connect(profile: text, username: usernameField.stringValue, password: passwordField.stringValue)
            } catch {
                tunnelLabel.stringValue = "Tunnel: \(error.localizedDescription)"
            }
        }
    }

    @objc private func disconnect() {
        tunnel.disconnect()
    }

    private func renderTunnel(_ status: NEVPNStatus) {
        tunnelLabel.stringValue = "Tunnel: \(status.plainLanguage)"
    }

    private func render(_ status: ExtensionInstaller.Status) {
        switch status {
        case .idle:
            statusLabel.stringValue = "Starting up"
            detailLabel.stringValue = ""
        case .requesting:
            statusLabel.stringValue = "Setting up the network component"
            detailLabel.stringValue = "This happens once."
        case .needsApproval:
            statusLabel.stringValue = "Waiting for your approval"
            detailLabel.stringValue = """
                macOS is asking you to allow VPN Plus in System Settings.                 This window will notice when you have.
                """
        case .active:
            statusLabel.stringValue = String(localized: "Network component ready")
            detailLabel.stringValue = String(localized: "Import a profile, then Connect. Credentials are typed each time until they can be saved.")
        case .failed(let message):
            statusLabel.stringValue = "Setup did not finish"
            detailLabel.stringValue = message
        }
    }
}
