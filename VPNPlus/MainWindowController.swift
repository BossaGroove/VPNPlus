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
import os

/// M0's only screen. It says what the extension is doing and gives C4 a way to
/// start and stop a tunnel. The real main window is designed in
/// docs/ux/screen-main.md and built with the engine.
@MainActor
final class MainWindowController: NSWindowController {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "window")

    /// The window's own view controller, which is what presents every sheet.
    private let content = NSViewController()

    private let installer = ExtensionInstaller(identifier: "com.bossagroove.VPNPlus.tunnel")
    private let tunnel = TunnelController()
    private let store: any ProfileStore = StoredProfileStore.live
    private lazy var importer = ProfileImporter(store: store)

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let tunnelLabel = NSTextField(labelWithString: "Tunnel: not set up")
    /// Where a failure or a notice appears. The designed surface is M5's and
    /// the curated copy M6's; this shows the messages M4 can already write
    /// rather than leaving them in the log where nobody looks.
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// Keeps the clocks honest while something is happening.
    private var tick: Timer?
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        // A real content view controller, and it is not decoration: a sheet is
        // dismissed by whoever presented it, so presenting from a temporary
        // one leaves a sheet nobody can close — which blocks the whole window
        // and refuses even Quit. This one is owned by the window and outlives
        // every sheet it presents.
        //
        // Assigned before the frame is settled, because it resizes the window.
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        window.contentViewController = content

        window.title = "VPN Plus"
        window.center()
        // After center(), so a remembered position wins over the default.
        window.setFrameAutosaveName("MainWindow")
        // Tall enough for the rows *plus* a three-line failure message. At 440
        // the content already just fitted, so a message pushed Connect off the
        // bottom — a message that costs you the button it is telling you about.
        window.minSize = NSSize(width: 620, height: 560)

        buildLayout()
        acceptDrops()
        importer.onChange = { [weak self] in self?.renderProfiles() }
        installer.onChange = { [weak self] in self?.render($0) }
        tunnel.onChange = { [weak self] in self?.renderTunnel($0) }
        tunnel.onConnection = { [weak self] in self?.renderConnection($0) }
        render(installer.status)
        renderProfiles()
        importer.handOverPending()
        installer.activate()
        // Nothing is created and nothing is saved: this only asks the system
        // what it already has, so the window can report on a connection it
        // was not there for.
        Task { await tunnel.load() }
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
        messageLabel.preferredMaxLayoutWidth = 480
        messageLabel.isHidden = true

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
            tunnelLabel, messageLabel, usernameField, passwordField, buttons,
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
            // Not a layout nicety: without it, content that outgrows the
            // window simply disappears below the edge with nothing to say so.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
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
        // decided (D128).
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
            // An empty field over a saved password means "use the one you
            // have", so it must not look like an empty field.
            passwordField.stringValue = ""
            passwordField.placeholderString = profile.credentialsSaved
                ? String(localized: "Saved")
                : String(localized: "Password")
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
        content.presentAsSheet(sheet)
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
            // The extension holds this profile's configuration and password, so
            // deleting here is only half of it. A dangling secret is a secret
            // nobody is managing.
            Task {
                do {
                    try await PrivilegedClient().deleteSecrets(for: profile.id)
                } catch {
                    Self.log.error("the extension may still hold secrets for a deleted profile: \(error.localizedDescription, privacy: .public)")
                }
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
        rememberUsername(username, for: profile, settings: settings)
        let decision = credentials(
            typedUsername: username,
            typedPassword: passwordField.stringValue,
            profile: profile,
            settings: settings)

        if case .missing(let forgetting) = decision {
            // Withdrawing permission to keep a password has to take effect
            // whether or not the user went on to connect: the choice
            // describes the present state, not the last connection (D219).
            if forgetting { Task { await forget(profile) } }
            // A prompt, not a failure (A10): nothing is wrong, the app simply
            // does not have what it needs yet.
            show(message: String(localized: "Type your password to connect to \(profile.title)."))
            return
        }

        clearMessage()
        Task {
            // Stored before connecting, not after: a connection that is
            // interrupted must not cost the user their password, and the
            // extension needs it on the very next attempt whatever happens to
            // this one (D219).
            await apply(decision, to: profile)
            do {
                try await tunnel.prepare(profile: profile.id)
                try tunnel.connect(
                    profile: text,
                    username: decision.sessionUsername,
                    password: decision.sessionPassword,
                    server: overrideServer(for: profile, settings: settings))
            } catch {
                tunnelLabel.stringValue = "Tunnel: \(error.localizedDescription)"
            }
        }
    }

    /// What to do with the sign-in details before connecting: what the
    /// extension should be holding afterwards, and what this one connection
    /// has to carry itself.
    private enum Credentials {
        /// Store these with the extension, and carry nothing.
        case store(username: String, password: String)
        /// The extension is already holding what it needs.
        case useWhatIsStored
        /// Carry these for this session only, and make sure the extension is
        /// holding none.
        case sessionOnly(username: String, password: String)
        /// The profile signs in by itself.
        case notNeeded
        /// Something is needed and nothing is available. `forgetting` is true
        /// when the user has just withdrawn permission to keep what is
        /// stored — which must happen even though this connection cannot.
        case missing(forgetting: Bool)

        var sessionUsername: String {
            switch self {
            case .sessionOnly(let username, _): username
            // Not even the username is sent when the extension holds it:
            // one copy, one owner (D218).
            default: ""
            }
        }

        var sessionPassword: String {
            switch self {
            case .sessionOnly(_, let password): password
            default: ""
            }
        }
    }

    /// Decides, from the profile's own rules and the user's choice, where this
    /// profile's sign-in details should live.
    ///
    /// A profile that forbids saving is honoured against our own default,
    /// never the other way round (D129). And an **empty password field over a
    /// saved password means "use the one you have"**, not "forget it": the app
    /// cannot read the stored secret, so without knowing that one exists those
    /// two are the same keystroke — and taking the second reading would delete
    /// a password every time someone pressed Connect twice.
    private func credentials(
        typedUsername: String,
        typedPassword: String,
        profile: Profile,
        settings: ProfileSettings?
    ) -> Credentials {
        guard case .credentials(_, let saving, _) = settings?.signIn else { return .notNeeded }
        let maySave: Bool
        switch saving {
        case .offered(let on): maySave = on
        case .forbiddenByProfile: maySave = false
        }
        if !typedPassword.isEmpty {
            return maySave
                ? .store(username: typedUsername, password: typedPassword)
                : .sessionOnly(username: typedUsername, password: typedPassword)
        }
        if maySave, profile.credentialsSaved { return .useWhatIsStored }
        return .missing(forgetting: !maySave && profile.credentialsSaved)
    }

    /// Carries the decision out, and says so when it could not be.
    private func apply(_ decision: Credentials, to profile: Profile) async {
        switch decision {
        case .store(let username, let password):
            do {
                try await PrivilegedClient().setCredentials(
                    username: username, password: password, for: profile.id)
                try? store.setCredentialsSaved(true, for: profile.id)
            } catch {
                Self.log.notice("could not save the sign-in details: \(error.localizedDescription, privacy: .public)")
                // The promise M4.4 made: the user finds out that nothing was
                // saved, instead of discovering it at the next connection.
                show(message: String(localized: "VPN Plus couldn't save your password. This connection will still work; the next one will ask for it again."))
            }
            renderProfiles()
        case .sessionOnly:
            // Unconditional, and not only when the flag says something is
            // stored: a password saved before that flag existed must still go
            // when the user says not to keep it.
            await forget(profile)
        case .notNeeded:
            // A profile that signs in by itself was never offered the choice,
            // so unless something really is stored there is nothing to forget
            // and no reason to ask root on every connection.
            if profile.credentialsSaved { await forget(profile) }
        case .useWhatIsStored, .missing:
            break
        }
    }

    /// Makes the extension forget this profile's sign-in details — and only
    /// those. Taking the configuration with them would make the user find the
    /// original file again.
    private func forget(_ profile: Profile) async {
        do {
            try await PrivilegedClient().forgetCredentials(for: profile.id)
            try? store.setCredentialsSaved(false, for: profile.id)
        } catch {
            Self.log.notice("could not remove the saved sign-in details: \(error.localizedDescription, privacy: .public)")
            show(message: String(localized: "VPN Plus couldn't forget your saved password. It may still be able to connect on its own."))
        }
        renderProfiles()
    }

    /// Keeps a typed username with the user's other choices, so the field is
    /// filled in next time.
    ///
    /// It has to be kept *somewhere*: the username travels to the extension
    /// with the password, and the app cannot read that back — so a second
    /// connection with an empty field would otherwise store an empty username
    /// over a good one. It belongs in the overrides record, which is where the
    /// user's own choices already live (2.14), and it is not a secret: it is
    /// the user's, which is why it goes in *their* preferences and never into
    /// the system-wide VPN configuration (D191).
    private func rememberUsername(_ username: String, for profile: Profile, settings: ProfileSettings?) {
        guard case .credentials(.editable, _, _) = settings?.signIn, !username.isEmpty else { return }
        var overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        guard overrides.username != username else { return }
        overrides.username = username
        try? store.setOverrides(overrides, for: profile.id)
    }

    private func show(message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
    }

    private func clearMessage() {
        show(message: "")
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

    /// The model, in words. A8's states and phases, from the one place that
    /// knows them — and the clock ticks because a number that stopped is how
    /// A1 found OpenVPN Connect lying about a connection.
    private func renderConnection(_ connection: Connection) {
        tunnelLabel.stringValue = connection.summary()
        tick?.invalidate()
        guard connection.state.isTransient || connection.state == .connected else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tunnelLabel.stringValue = self.tunnel.connection.summary()
            }
        }
    }

    private func renderTunnel(_ status: NEVPNStatus) {
        // The system's own view, kept only until M5.4 renders the model
        // properly. Where the two can differ, the model is the one shown.
        if case .disconnected = tunnel.connection, status == .invalid {
            tunnelLabel.stringValue = String(localized: "Not set up")
        }
        switch status {
        case .connected:
            clearMessage()
            // The extension is certainly running now, so anything still
            // waiting to move can move.
            importer.handOverPending()
            renderProfiles()
        case .connecting:
            clearMessage()
        case .disconnected where tunnel.stoppedByUser:
            // Asked for, so there is nothing to explain.
            clearMessage()
        case .disconnected:
            Task { await showLastFailure() }
        default:
            break
        }
    }

    /// Asks NetworkExtension why the last attempt ended, and says it in words.
    ///
    /// This is what lets a connection started from **System Settings**, with
    /// this app not running at the time, explain itself when the app is next
    /// opened — the surface B8's open item 2 said did not exist.
    private func showLastFailure() async {
        guard let failure = await tunnel.lastFailure() else { return }
        Self.log.notice("last disconnect: \(failure.detail, privacy: .public) at \(failure.at?.description ?? "an unrecorded time", privacy: .public)")

        // A reason found at launch may be from any time at all, and a week-old
        // failure presented as news is worse than saying nothing. Anything
        // recent is shown; so is anything whose time did not survive the trip,
        // because silence would be the worse guess. M5 records its own
        // attempts and will not have to reason about this.
        if let at = failure.at, Date().timeIntervalSince(at) > 15 * 60 { return }

        let name = configuredProfileTitle()
        switch failure.kind {
        case .credentialsUnavailable:
            // A10 M21. The remedy, not the mechanism: what to do, and what it
            // buys them next time.
            show(message: String(localized: """
                Couldn't connect to \(name). It needs your password, and VPN Plus wasn't running to ask for it. \
                Connect once from VPN Plus and let it remember your password — after that, starting \(name) from \
                System Settings or the menu bar will work on its own.
                """))
        case .configurationMissing:
            show(message: String(localized: """
                Couldn't connect to \(name). VPN Plus doesn't have that profile's settings any more. \
                Import the profile again.
                """))
        case .authenticationFailed:
            // A10 M1's territory; M6 writes the version with both remedies.
            show(message: String(localized: """
                Couldn't sign in to \(name). The server didn't accept your username or password.
                """))
        case .timedOut:
            // M6 names the step it ran out of on, which is most of the value
            // of the message; until the phase reaches the app (M5.2) this says
            // only what it knows, and invents nothing (D85).
            show(message: String(localized: "Couldn't connect to \(name). It didn't finish in time."))
        case .unknown:
            show(message: String(localized: "Couldn't connect to \(name), and VPN Plus doesn't have a specific reason for it. Trying again is worth a go."))
        case nil:
            // Not ours: the system's own, or a reason M6 has yet to map.
            break
        }
    }

    /// The name of the profile the system configuration points at, which is
    /// the one that just failed — not whatever happens to be selected.
    private func configuredProfileTitle() -> String {
        guard let identifier = tunnel.configuredProfile,
              let profile = ((try? store.profiles()) ?? []).first(where: { $0.id == identifier })
        else { return String(localized: "this VPN") }
        return profile.title
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
            detailLabel.stringValue = String(localized: "Import a profile, then Connect. Your password is remembered unless you say otherwise.")
        case .failed(let message):
            statusLabel.stringValue = "Setup did not finish"
            detailLabel.stringValue = message
        }
    }
}
