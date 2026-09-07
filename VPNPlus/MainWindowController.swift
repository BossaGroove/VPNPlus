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
    private let profiles = ProfileListView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
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
        importer.handOverPending()
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
        connectButton.action = #selector(connectSelected)
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)

        importButton.title = String(localized: "Import Profile…")
        importButton.target = self
        importButton.action = #selector(importProfileFromPanel(_:))
        usernameField.placeholderString = String(localized: "Username")
        passwordField.placeholderString = String(localized: "Password")
        for field in [usernameField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        profiles.translatesAutoresizingMaskIntoConstraints = false
        profiles.heightAnchor.constraint(equalToConstant: 150).isActive = true
        profiles.widthAnchor.constraint(equalToConstant: 420).isActive = true
        profiles.onSelect = { [weak self] _ in self?.renderSelection() }
        profiles.onConnect = { [weak self] in self?.connect(to: $0) }
        profiles.onConfigure = { [weak self] in self?.configure($0) }
        profiles.onDelete = { [weak self] in self?.confirmDelete($0) }

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.preferredMaxLayoutWidth = 420

        let testPath = NSStackView(views: [importButton])
        testPath.orientation = .horizontal
        testPath.spacing = 8

        let buttons = NSStackView(views: [connectButton, disconnectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [
            statusLabel, detailLabel, profiles, emptyLabel, testPath,
            tunnelLabel, usernameField, passwordField, buttons,
        ])
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
        let stored = (try? store.profiles()) ?? []
        profiles.show(stored)
        profiles.isHidden = stored.isEmpty
        emptyLabel.isHidden = !stored.isEmpty
        emptyLabel.stringValue = String(localized: """
            No profiles yet. Import one with the button below, drop it on this \
            window, or double-click it in the Finder.
            """)
        renderSelection()
    }

    private func renderSelection() {
        guard let profile = profiles.selected else {
            usernameField.isHidden = true
            passwordField.isHidden = true
            connectButton.isEnabled = false
            return
        }
        connectButton.isEnabled = true

        // The sign-in fields follow what the profile asks for, which the model
        // decided (D128). Credentials themselves are still typed each time,
        // until M4 can store them.
        let settings = compose(profile)
        switch settings?.signIn {
        case .credentials(let username, _, _):
            usernameField.isHidden = false
            passwordField.isHidden = false
            switch username {
            case .fixed(let fixed):
                usernameField.stringValue = fixed
                usernameField.isEditable = false
                usernameField.placeholderString = nil
            case .editable(let value):
                usernameField.isEditable = true
                usernameField.stringValue = value.value
                usernameField.placeholderString = String(localized: "Username")
            }
            passwordField.placeholderString = String(localized: "Password")
        case .notNeeded:
            usernameField.isHidden = true
            passwordField.isHidden = true
        case nil:
            usernameField.isHidden = true
            passwordField.isHidden = true
        }
    }

    /// The profile and the user's overrides, composed — the only way this
    /// window learns what to show (D188).
    private func compose(_ profile: Profile) -> ProfileSettings? {
        guard let descriptor = descriptor(for: profile) else { return nil }
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        return ProfileSettings.compose(descriptor, with: overrides)
    }

    /// What the profile says about itself. Stored at import, because once the
    /// extension owns the configuration the app cannot read it again — and
    /// re-deriving it from a copy the app kept would be that second copy.
    private func descriptor(for profile: Profile) -> ProfileDescriptor? {
        if let stored = profile.descriptor { return stored }
        // A profile imported before descriptors were stored: derive it once
        // from the copy the app still holds, and keep it.
        guard let configuration = try? store.configuration(for: profile.id),
              let text = String(data: configuration, encoding: .utf8),
              let derived = ProfileImport.describe(text, setAside: profile.waivedDirectives)
        else { return nil }
        try? store.setDescriptor(derived, for: profile.id)
        return derived
    }

    private func configure(_ profile: Profile) {
        guard let descriptor = descriptor(for: profile) else { return }
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        let sheet = ProfileConfigurationSheet(
            profile: profile, descriptor: descriptor, overrides: overrides
        ) { [weak self] updated in
            guard let self else { return }
            try? store.setOverrides(updated, for: profile.id)
            // The title in the list follows the user's name for it.
            renderProfiles()
        }
        contentViewController?.presentAsSheet(sheet) ?? presentSheet(sheet)
    }

    private func presentSheet(_ controller: NSViewController) {
        let holder = NSViewController()
        holder.view = window?.contentView ?? NSView()
        holder.presentAsSheet(controller)
    }

    /// Deleting takes a private key with it, so it asks first.
    private func confirmDelete(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(profile.title)?")
        alert.informativeText = String(localized: """
            This removes the profile and anything saved with it, including its \
            certificate and key. You would need the original file to import it again.
            """)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try store.remove(profile.id)
            } catch {
                tunnelLabel.stringValue = String(localized: "Couldn't delete that profile")
            }
            renderProfiles()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    @objc private func connectSelected() {
        guard let profile = profiles.selected else {
            tunnelLabel.stringValue = String(localized: "Import a profile first")
            return
        }
        connect(to: profile)
    }

    /// Connecting reads the stored profile and the user's overrides. No file
    /// picker, and the configuration surface is never on the way here (2.13).
    private func connect(to profile: Profile) {
        // The configuration is sent only while the extension does not yet hold
        // it; after that the provider reads its own copy and the start options
        // carry no secret at all.
        var text: String?
        if !profile.configurationHandedOver {
            guard let configuration = try? store.configuration(for: profile.id),
                  let readable = String(data: configuration, encoding: .utf8)
            else {
                tunnelLabel.stringValue = String(localized: "Couldn't read that profile")
                return
            }
            text = readable
        }
        let settings = compose(profile)
        let username: String
        switch settings?.signIn {
        case .credentials(.fixed(let fixed), _, _): username = fixed
        default: username = usernameField.stringValue
        }
        Task {
            do {
                try await tunnel.prepare(profile: profile.id)
                try tunnel.connect(
                    profile: text,
                    username: username,
                    password: passwordField.stringValue,
                    server: overrideServer(for: profile, settings: settings))
            } catch {
                tunnelLabel.stringValue = "Tunnel: \(error.localizedDescription)"
            }
        }
    }

    /// Only what the user actually chose: where the composed value equals the
    /// profile's own, nothing is sent.
    private func overrideServer(for profile: Profile, settings: ProfileSettings?) -> ServerEndpoint {
        guard let settings else { return ServerEndpoint() }
        switch settings.server {
        case let .single(host, port, transport):
            var chosen = ServerEndpoint()
            if case .overridden = host.provenance {
                chosen = ServerEndpoint(host: host.value, port: chosen.port, transport: chosen.transport)
            }
            if case .overridden = port.provenance {
                chosen = ServerEndpoint(host: chosen.host, port: port.value, transport: chosen.transport)
            }
            if case .overridden = transport.provenance {
                chosen = ServerEndpoint(host: chosen.host, port: chosen.port, transport: transport.value)
            }
            return chosen
        case .choice:
            // A chosen server is always an override: the profile advertises
            // several and the user picked one.
            return settings.effectiveServer
        }
    }

    @objc private func disconnect() {
        tunnel.disconnect()
    }

    private func renderTunnel(_ status: NEVPNStatus) {
        tunnelLabel.stringValue = "Tunnel: \(status.plainLanguage)"
        if status == .connected {
            // The extension is certainly running now, so anything still
            // waiting to move can move.
            importer.handOverPending()
            renderProfiles()
        }
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
