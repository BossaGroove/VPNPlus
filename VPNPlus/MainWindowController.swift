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

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let tunnelLabel = NSTextField(labelWithString: "Tunnel: not set up")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)

    // M2 ONLY — the test path. A profile chosen from disk is held in memory
    // for this run and never written anywhere; credentials are typed each
    // time. M3 (profiles) and M4 (credentials) replace all of this.
    private let chooseButton = NSButton(title: "Choose Profile…", target: nil, action: nil)
    private let profileLabel = NSTextField(labelWithString: "No profile chosen")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private var profileText: String?

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
        installer.onChange = { [weak self] in self?.render($0) }
        tunnel.onChange = { [weak self] in self?.renderTunnel($0) }
        render(installer.status)
        installer.activate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 480
        tunnelLabel.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(connect)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)

        chooseButton.target = self
        chooseButton.action = #selector(chooseProfile)
        profileLabel.textColor = .secondaryLabelColor
        usernameField.placeholderString = "Username (if the profile asks)"
        passwordField.placeholderString = "Password"
        for field in [usernameField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        let testPath = NSStackView(views: [chooseButton, profileLabel])
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

    @objc private func chooseProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ovpn") ?? .data, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an OpenVPN profile. It stays in memory for this run only."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            profileText = try String(contentsOf: url, encoding: .utf8)
            profileLabel.stringValue = url.lastPathComponent
        } catch {
            profileText = nil
            profileLabel.stringValue = "Could not read \(url.lastPathComponent)"
        }
    }

    @objc private func connect() {
        guard let profileText else {
            tunnelLabel.stringValue = "Tunnel: choose a profile first"
            return
        }
        Task {
            do {
                try await tunnel.prepare()
                try tunnel.connect(profile: profileText, username: usernameField.stringValue, password: passwordField.stringValue)
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
            statusLabel.stringValue = "Network component ready"
            detailLabel.stringValue = "Test path (M2): choose a profile, enter credentials if it needs them, Connect."
        case .failed(let message):
            statusLabel.stringValue = "Setup did not finish"
            detailLabel.stringValue = message
        }
    }
}
