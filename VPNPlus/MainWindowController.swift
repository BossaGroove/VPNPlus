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

/// **S2 — one window for everything routine** (commitment 1).
///
/// Two zones, and the whole design is in how they relate: a **promoted
/// region** holding the profile that is involved, and a **grid of the others**
/// below it. The involved profile is *lifted out* of the grid rather than
/// shown twice (D114), which is why a grid card has exactly one design and
/// never carries connection state.
///
/// Six window states, **derived** from the tunnel plus two facts (D93) — so
/// this class chooses layouts, and decides nothing:
///
/// | State | What is on screen |
/// |---|---|
/// | Empty | What the app needs and where profiles come from. No grid, no region |
/// | Setup | What is being waited on, and a way back to System Settings |
/// | Blocked | Why it cannot connect, stated **once** (D116), with everything else still working |
/// | Idle | The grid |
/// | Active | The involved profile promoted; the grid stays live below |
/// | Failed | The message, in the promoted region, with Try Again |
///
/// Commitment 1 is kept by what is *absent*: no tabs, no sidebar, no detail
/// page, and **never navigating to connect** (D54).
@MainActor
final class MainWindowController: NSWindowController {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "window")

    /// A12: sized so the common worst case — a Failed message in the longest
    /// language — fits without scrolling (D115). The minimum is the smallest
    /// *usable* size rather than the smallest that fits the worst state
    /// (D165), and the grid scrolls to make up the difference.
    private static let defaultSize = NSSize(width: 760, height: 640)
    private static let minimumSize = NSSize(width: 620, height: 440)

    private let installer = ExtensionInstaller(identifier: "com.bossagroove.VPNPlus.tunnel")
    private let tunnel = TunnelController()
    private let store: any ProfileStore = StoredProfileStore.live
    private lazy var importer = ProfileImporter(store: store)

    private let content = NSViewController()
    private let promoted = PromotedRegionView()
    private let grid = CardGridView(frame: .zero)
    private let gridScroll = NSScrollView()
    private let empty = GuidanceView()
    private var tick: Timer?

    /// The profile the promoted region is about. **What the user asked for,
    /// from the moment they ask** (A13): during a switch that is the
    /// destination, not the profile being torn down, so one lift happens
    /// rather than two and the identity never changes mid-operation.
    private var involved: Profile.ID? {
        if case .disconnecting(let teardown) = tunnel.connection, let next = teardown.switchingTo {
            return next
        }
        return tunnel.connection.profile
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        // A real content view controller, so a sheet is dismissed by something
        // that still exists (D223).
        content.view = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        window.contentViewController = content

        window.title = "VPN Plus"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = Self.minimumSize
        // Resizable *and* zoomable, against A1's finding that OpenVPN Connect
        // disables zoom and fixes itself at about 400 × 685.
        window.collectionBehavior = [.fullScreenPrimary]

        buildToolbar()
        buildLayout()
        acceptDrops()

        importer.onChange = { [weak self] in self?.render() }
        installer.onChange = { [weak self] _ in self?.render() }
        tunnel.onChange = { [weak self] _ in self?.render() }
        tunnel.onConnection = { [weak self] _ in self?.render() }

        promoted.onCancel = { [weak self] in self?.tunnel.disconnect() }
        promoted.onDisconnect = { [weak self] in self?.tunnel.disconnect() }
        promoted.onRetry = { [weak self] in self?.retry() }

        grid.onSelect = { _ in }
        grid.onConnect = { [weak self] in self?.connect(to: $0) }
        grid.onConfigure = { [weak self] in self?.configure($0) }
        grid.onDelete = { [weak self] in self?.confirmDelete($0) }
        grid.onReveal = { [weak self] in self?.reveal($0) }
        grid.onRename = { [weak self] in self?.rename($0, to: $1) }
        grid.onMove = { [weak self] in self?.move($0, by: $1) }

        render()
        importer.handOverPending()
        installer.activate()
        Task { await tunnel.load() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Chrome

    /// **One control** (D117): import. Settings is ⌘, in the application menu
    /// (D52), and nothing else has earned the space.
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// **The whole window takes a dropped profile, in every state** (A5).
    private func acceptDrops() {
        guard let root = content.view as NSView? else { return }
        let target = DropView(frame: root.bounds)
        target.autoresizingMask = [.width, .height]
        target.onDrop = { [weak self] url in self?.importProfile(at: url) }
        root.addSubview(target, positioned: .below, relativeTo: nil)
    }

    private func buildLayout() {
        let root = content.view

        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.autohidesScrollers = true
        gridScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(promoted)
        root.addSubview(gridScroll)
        root.addSubview(empty)

        NSLayoutConstraint.activate([
            promoted.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.xxl),
            promoted.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.xl),
            promoted.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.xl),

            gridScroll.topAnchor.constraint(equalTo: promoted.bottomAnchor, constant: Space.xxl),
            gridScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.xl),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.xl),
            gridScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Space.xl),

            // The empty screen is the content, centred, with no grid and no
            // region behind it.
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.xxl),
            empty.trailingAnchor.constraint(
                lessThanOrEqualTo: root.trailingAnchor, constant: -Space.xxl),
        ])
        // A scroll view manages its document view with an autoresizing mask
        // by default, which fought a width constraint and got it broken
        // (measured, 23:42:29). Pinned to the clip view instead, so the grid
        // takes the visible width and reports its own height.
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: gridScroll.contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: gridScroll.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: gridScroll.contentView.topAnchor),
        ])
    }

    // MARK: - The six states (D93)

    private var setup: SetupState {
        switch installer.status {
        // Setup is deferred to the first Connect (D59), so "nothing asked for
        // yet" is not a state the user is shown. *When* it is asked for is
        // M7's; what it looks like is here.
        case .idle, .active: .ready
        case .requesting, .needsApproval: .waitingForApproval
        case .failed: .blocked
        }
    }

    private func render() {
        let stored = (try? store.profiles()) ?? []
        var titles: [Profile.ID: String] = [:]
        for profile in stored { titles[profile.id] = title(of: profile) }

        let state = WindowState.derive(
            connection: tunnel.connection, hasProfiles: !stored.isEmpty, setup: setup)

        empty.isHidden = state != .empty
        gridScroll.isHidden = state == .empty
        promoted.isHidden = false

        switch state {
        case .empty:
            promoted.isHidden = true
            empty.show(
                title: String(localized: "No profiles yet"),
                body: String(
                    localized: """
                        VPN Plus needs a .ovpn configuration file to connect. These usually come from \
                        your employer, a VPN provider, or your own server.
                        """),
                action: (
                    String(localized: "Import a profile…"),
                    { [weak self] in
                        self?.importer.chooseFile(over: self?.window)
                    }
                ),
                hint: String(localized: "or drag a .ovpn file anywhere in this window"))

        case .setup:
            promoted.show(
                guidance: (
                    String(localized: "Waiting for your approval"),
                    String(
                        localized: """
                            System Settings should be open. Turn on VPN Plus there, then come back — this \
                            window will notice.
                            """),
                    (
                        String(localized: "Open System Settings again"),
                        {
                            // The pane the approval lives on. A0 C2 found the OS's own
                            // prompt merely dismissible, leaving "little chance that
                            // the user will be able to find the correct place" — so
                            // the window takes them there rather than describing it.
                            if let url = URL(
                                string:
                                    "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )
                ))

        case .blocked:
            promoted.show(
                guidance: (
                    String(localized: "Setup isn't finished"),
                    String(
                        localized: """
                            VPN Plus doesn't have permission from macOS to create a VPN connection, so it \
                            can't connect yet. Everything else still works — you can add, rename and \
                            remove profiles.
                            """),
                    (
                        String(localized: "Continue setup"),
                        { [weak self] in self?.installer.activate() }
                    )
                ))

        case .idle:
            promoted.isHidden = true

        case .active, .failed:
            let name = involved.flatMap { titles[$0] } ?? String(localized: "this VPN")
            promoted.show(tunnel.connection, name: name)
        }

        // **Lift-out** (D114): the grid shows the others, never a second copy
        // of what is promoted.
        let others = promoted.isHidden ? stored : stored.filter { $0.id != involved }
        grid.show(others, titles: titles)

        keepTheClocksHonest()
    }

    /// A ticking number that stopped is how A1 found OpenVPN Connect claiming
    /// a connection it did not have.
    private func keepTheClocksHonest() {
        tick?.invalidate()
        let state = tunnel.connection.state
        guard state.isTransient || state == .connected else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let involved = self.involved else { return }
                let name =
                    ((try? self.store.profiles()) ?? [])
                    .first { $0.id == involved }
                    .map { self.title(of: $0) } ?? String(localized: "this VPN")
                self.promoted.show(self.tunnel.connection, name: name)
            }
        }
    }

    /// The user's name for a profile, else the configuration's, else the
    /// file's. Composed here because the rule belongs to the overrides record
    /// and not to a view (D230).
    private func title(of profile: Profile) -> String {
        compose(profile)?.title.value ?? profile.title
    }

    /// File > Import Profile…, and the button (2.1).
    @objc func importProfileFromPanel(_ sender: Any?) {
        importer.chooseFile(over: window)
    }

    /// A profile double-clicked in the Finder or dropped on the app icon (2.1).
    func importProfile(at url: URL) {
        importer.importProfile(at: url, over: window)
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
            render()
        }
        content.presentAsSheet(sheet)
    }

    /// A rename is an override, not a rewrite: an employer who reissues the
    /// profile should not take the user's name for it away (D132, 2.6).
    private func rename(_ profile: Profile, to title: String) {
        var overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        overrides.title = title
        try? store.setOverrides(overrides, for: profile.id)
        render()
    }

    /// It is their file (A13). The app's own copy is gone once the extension
    /// holds the configuration, so this reveals what they imported *from*.
    private func reveal(_ profile: Profile) {
        let url = URL(fileURLWithPath: profile.origin.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            notify(
                String(
                    localized:
                        "VPN Plus can't find that profile's original file any more. The profile still works — it is the file that has moved."
                ))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reordering, from the keyboard and from VoiceOver. Dragging is invisible
    /// to VoiceOver (A18 finding 5), so it cannot be the only way — and the
    /// order is the user's, which is why nothing else ever changes it (D119).
    private func move(_ profile: Profile, by offset: Int) {
        var order = ((try? store.profiles()) ?? []).map(\.id)
        guard let from = order.firstIndex(of: profile.id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        try? store.setOrder(order)
        render()
    }

    /// Deleting takes a private key with it, so it asks first.
    private func confirmDelete(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(profile.title)?")
        alert.informativeText = String(
            localized: """
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
                notify(String(localized: "VPN Plus couldn't delete that profile."))
            }
            // The extension holds this profile's configuration and password, so
            // deleting here is only half of it. A dangling secret is a secret
            // nobody is managing.
            Task {
                do {
                    try await PrivilegedClient().deleteSecrets(for: profile.id)
                } catch {
                    Self.log.error(
                        "the extension may still hold secrets for a deleted profile: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            render()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

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
                Self.log.notice(
                    "could not save the sign-in details: \(error.localizedDescription, privacy: .public)"
                )
                // The promise M4.4 made: the user finds out that nothing was
                // saved, instead of discovering it at the next connection.
                notify(
                    String(
                        localized:
                            "VPN Plus couldn't save your password. This connection will still work; the next one will ask for it again."
                    ))
            }
            render()
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
            Self.log.notice(
                "could not remove the saved sign-in details: \(error.localizedDescription, privacy: .public)"
            )
            notify(
                String(
                    localized:
                        "VPN Plus couldn't forget your saved password. It may still be able to connect on its own."
                ))
        }
        render()
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
    private func rememberUsername(
        _ username: String, for profile: Profile, settings: ProfileSettings?
    ) {
        guard case .credentials(.editable, _, _) = settings?.signIn, !username.isEmpty else {
            return
        }
        var overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        guard overrides.username != username else { return }
        overrides.username = username
        try? store.setOverrides(overrides, for: profile.id)
    }

    /// Only what the user actually chose: where the composed value equals the
    /// profile's own, nothing is sent.
    private func overrideServer(for profile: Profile, settings: ProfileSettings?) -> ServerEndpoint
    {
        guard let settings else { return ServerEndpoint() }
        switch settings.server {
        case let .single(host, port, transport):
            var chosen = ServerEndpoint()
            if case .overridden = host.provenance {
                chosen = ServerEndpoint(
                    host: host.value, port: chosen.port, transport: chosen.transport)
            }
            if case .overridden = port.provenance {
                chosen = ServerEndpoint(
                    host: chosen.host, port: port.value, transport: chosen.transport)
            }
            if case .overridden = transport.provenance {
                chosen = ServerEndpoint(
                    host: chosen.host, port: chosen.port, transport: transport.value)
            }
            return chosen
        case .choice:
            // A chosen server is always an override: the profile advertises
            // several and the user picked one.
            return settings.effectiveServer
        }
    }

    // MARK: - Connecting

    /// One click, and the configuration surface is never on the way here
    /// (2.13, D58).
    ///
    /// `typed` arrives from the sign-in sheet when the app did not already
    /// have what it needed. Everything else — which profile, whether to save,
    /// which server — is decided from the stored model.
    private func connect(
        to profile: Profile,
        typed: (username: String, password: String, remember: Bool)? = nil
    ) {
        // The configuration crosses only while the extension does not yet hold
        // it; after that the provider reads its own copy and the start options
        // carry no secret at all.
        var text: String?
        if !profile.configurationHandedOver {
            guard let configuration = try? store.configuration(for: profile.id),
                let readable = String(data: configuration, encoding: .utf8)
            else {
                promoted.show(
                    .failed(
                        FailureRecord(
                            profile: profile.id, at: Date(), reason: .configurationMissing)),
                    name: title(of: profile))
                return
            }
            text = readable
        }

        let settings = compose(profile)
        if let typed {
            // Their choice about saving is theirs to keep, so it goes in the
            // overrides record rather than living for one connection.
            if case .credentials(_, .offered(let on), _) = settings?.signIn, on != typed.remember {
                var overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
                overrides.savePassword = typed.remember
                try? store.setOverrides(overrides, for: profile.id)
            }
            rememberUsername(typed.username, for: profile, settings: compose(profile))
        }

        let username: String
        switch settings?.signIn {
        case .credentials(.fixed(let fixed), _, _): username = fixed
        default:
            username = typed?.username ?? (try? store.overrides(for: profile.id))?.username ?? ""
        }

        let decision = credentials(
            typedUsername: username,
            typedPassword: typed?.password ?? "",
            profile: profile,
            settings: compose(profile))

        if case .missing(let forgetting) = decision {
            if forgetting { Task { await forget(profile) } }
            // **A prompt, not a failure** (A10): nothing has gone wrong, the
            // app simply does not have what it needs yet.
            askToSignIn(for: profile, settings: compose(profile))
            return
        }

        Task {
            // Stored before connecting, not after: an interrupted connection
            // must not cost the user their password (D219).
            await apply(decision, to: profile)
            do {
                try await tunnel.prepare(profile: profile.id)
                try tunnel.connect(
                    profile: text,
                    username: decision.sessionUsername,
                    password: decision.sessionPassword,
                    server: overrideServer(for: profile, settings: compose(profile)))
            } catch {
                Self.log.error(
                    "could not start the tunnel: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// "Sign in to *X*" — one of S2's six sheets (A20), and reached only on
    /// the way to connecting.
    private func askToSignIn(for profile: Profile, settings: ProfileSettings?) {
        let sheet = SignInSheet(
            name: title(of: profile), settings: settings, saved: profile.credentialsSaved
        ) { [weak self] username, password, remember in
            guard let self, !password.isEmpty else { return }
            connect(to: profile, typed: (username, password, remember))
        }
        content.presentAsSheet(sheet)
    }

    /// A consequence of something the user just did, that they have to know
    /// about and can do nothing about right now.
    ///
    /// Deliberately not a strip in the window: A12's promoted region is for
    /// the *connection*, and a second place for text would compete with it.
    /// M6 may reassign these once A10's full set exists.
    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }

    /// Try Again, from the Failed region. The same click as Connect — a
    /// failure is not a different way in (D56).
    private func retry() {
        guard let involved,
            let profile = ((try? store.profiles()) ?? []).first(where: { $0.id == involved })
        else { return }
        connect(to: profile)
    }

}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.importProfile, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .importProfile]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == .importProfile else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = String(localized: "Import Profile")
        item.toolTip = String(localized: "Import a .ovpn profile")
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(importProfileFromPanel(_:))
        return item
    }
}

extension NSToolbarItem.Identifier {
    static let importProfile = NSToolbarItem.Identifier("importProfile")
}
