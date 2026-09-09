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
    /// 760 × 560, from the artboards. Every one of the 21 is drawn at this
    /// size, and the 640 this used to be was a guess at the Failed message's
    /// height rather than a measurement of it.
    private static let defaultSize = NSSize(width: 760, height: 560)
    /// **Derived from the German Failed state, not the English one** (D157,
    /// A18's amendment to D115). Measured 2026-09-09 with the real German:
    /// at 620 pt wide the region is 332 pt tall and the window's own floor
    /// is 460; at 640 × 640 the whole state fits with a full row of cards
    /// below it. M5.4's provisional 620 × 440 had never been re-derived.
    private static let minimumSize = NSSize(width: 640, height: 640)

    /// Where the app is, read once (D62): a bundle does not move while it runs.
    private let location: InstallLocation = Rehearsal.isActive ? .correct : InstallLocation.current
    /// A5's setup sequence, holding the connect intent across it (D60).
    private let setup = SetupFlow(
        installer: ExtensionInstaller(
            identifier: "com.bossagroove.VPNPlus.tunnel", rehearsing: Rehearsal.isActive))
    /// **Injected, not owned.** The status item reads the same one, which is
    /// what makes commitment 6 structural rather than a promise (D93).
    private let tunnel: TunnelController
    private let catalogue: ProfileCatalogue
    private var store: any ProfileStore { catalogue.store }
    private lazy var importer = ProfileImporter(store: store)

    private let content = NSViewController()
    private let promoted = PromotedRegionView()
    private let grid = CardGridView(frame: .zero)
    private let gridScroll = NSScrollView()
    private let empty = GuidanceView()
    /// Held, because the gap above the grid belongs to the promoted region
    /// and there is no region to leave a gap under in Idle. **Starts at the
    /// Idle value**: the window opens with no region showing, and the gutter
    /// is what a slide-in adds and a slide-out removes. Created at the
    /// slide-in value, the grid sat a gutter too low from launch until the
    /// first slide-out corrected it (owner's screenshots, 2026-09-09).
    private lazy var gridTop = gridScroll.topAnchor.constraint(
        equalTo: promoted.bottomAnchor, constant: 0)
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

    init(tunnel: TunnelController, catalogue: ProfileCatalogue) {
        self.tunnel = tunnel
        self.catalogue = catalogue
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
        window.setAccessibilityIdentifier(AccessibilityID.mainWindow)
        window.center()
        // Bumped whenever the designed size changes, because a frame saved
        // from the previous one is not a size the user chose. M5.8 is the
        // second bump: 760 × 560 comes from the artboards, and a restored
        // 716 pt window was quietly costing the grid its third column.
        // A rehearsal starts at the default size every time and leaves the
        // owner's saved frame alone (M8.4).
        if !Rehearsal.isActive { window.setFrameAutosaveName("MainWindow.M5.8") }
        window.minSize = Self.minimumSize
        // Resizable *and* zoomable, against A1's finding that OpenVPN Connect
        // disables zoom and fixes itself at about 400 × 685.
        window.collectionBehavior = [.fullScreenPrimary]

        #if DEBUG
            keepOnTheBuiltInDisplayWhileDeveloping()
        #endif

        buildToolbar()
        buildLayout()
        acceptDrops()
        for (view, identifier) in [(promoted, AccessibilityID.promotedRegion), (empty, AccessibilityID.guidance)]
            as [(NSView, String)]
        {
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            view.setAccessibilityIdentifier(identifier)
        }

        importer.onChange = { [weak self] in self?.render() }
        setup.onChange = { [weak self] in self?.render() }
        setup.onReady = { [weak self] in self?.connect(to: $0) }
        tunnel.observe { [weak self] _, _ in self?.render() }

        promoted.onCancel = { [weak self] in self?.tunnel.disconnect() }
        promoted.onDisconnect = { [weak self] in self?.tunnel.disconnect() }
        promoted.onShowDetails = { [weak self] in self?.showDiagnostics(nil) }
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
        // Launch asks macOS what is installed and nothing else (D59): an
        // approved extension is brought up silently, an unapproved one waits
        // for the first Connect and our explanation (D65).
        setup.probe()
        Task { await tunnel.load() }

        #if DEBUG
            installDebugTriggers()
        #endif
    }

    #if DEBUG
        /// **Development only: the app opens and closes its own settings
        /// sheet.**
        ///
        ///   notifyutil -p com.bossagroove.VPNPlus.debug.openSettingsSheet
        ///
        /// The sheet is two clicks into a card's `…` menu, and neither click is
        /// one this session can make. Same reason the status menu has a
        /// trigger: a surface nobody can open is a surface nobody can look at,
        /// and looking at it is how its defects were found.
        ///
        /// It **toggles**, and that is the part worth keeping: a trigger that
        /// only opens leaves a modal sheet sitting on somebody's screen until
        /// they come back and dismiss it themselves.
        private func installDebugTriggers() {
            var token: Int32 = NOTIFY_TOKEN_INVALID
            // **Development only: the three M5.10 sheets**, each a toggle, so
            // they can be captured beside their artboards (D250).
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.openRemoveConfirm
            //   notifyutil -p com.bossagroove.VPNPlus.debug.openImportError
            //   notifyutil -p com.bossagroove.VPNPlus.debug.openReplaceReport
            func toggleSheet(
                _ name: String, _ present: @escaping @MainActor (MainWindowController) -> Void
            ) {
                var token: Int32 = NOTIFY_TOKEN_INVALID
                notify_register_dispatch(
                    "com.bossagroove.VPNPlus.debug.\(name)", &token, DispatchQueue.main
                ) { _ in
                    MainActor.assumeIsolated { [weak self] in
                        guard let self else { return }
                        if let shown = window?.attachedSheet {
                            window?.endSheet(shown)
                            return
                        }
                        present(self)
                    }
                }
            }
            toggleSheet("openRemoveConfirm") { controller in
                guard let profile = controller.catalogue.profiles.last else { return }
                controller.confirmDelete(profile)
            }
            toggleSheet("openImportError") { controller in
                let filename = controller.catalogue.profiles.last?.origin.filename ?? "work.ovpn"
                controller.importer.debugPresentMissingFile(filename: filename, over: controller.window)
            }
            toggleSheet("openReplaceReport") { controller in
                guard let profile = controller.catalogue.profiles.last else { return }
                controller.importer.debugPresentReport(for: profile, over: controller.window)
            }
            toggleSheet("openDiagnostics") { controller in
                controller.showDiagnostics(nil)
            }

            // **Development only: Settings, on demand.**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.openSettings
            var settingsToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.openSettings", &settingsToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.debugToggleSettings() }
            }

            // **Development only: an update check, without a click.**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.checkForUpdates
            var updateToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.checkForUpdates", &updateToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.debugCheckForUpdates() }
            }

            // **Development only: the move, without a click.**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.moveToApplications
            //
            // Runs *Move to Applications* on a copy launched from elsewhere.
            var moveToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.moveToApplications", &moveToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in self?.moveToApplications() }
            }

            // **Development only: D76's notification, on demand.**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.postNotice
            var noticeToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.postNotice", &noticeToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.debugPostNotice() }
            }

            // **Development only: fold or unfold the open configuration sheet's
            // transparency section**, as a click on its heading would.
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.toggleContents
            var foldToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.toggleContents", &foldToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let sheet = self?.window?.attachedSheet?.contentViewController
                        as? ProfileConfigurationSheet
                    else { return }
                    sheet.debugToggleContents()
                }
            }

            // **Development only: the record, in the words the sheet will use.**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.dumpDiagnostics
            //
            // M6.5 builds the Diagnostics sheet; until it exists this is how
            // the record gets *looked at* rather than reasoned about, which is
            // the lesson of the window that shipped empty (D234).
            var recordToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.dumpDiagnostics", &recordToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in self?.dumpDiagnostics() }
            }

            // **Development only: a switch's slide timing**, without a tunnel.
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.probeSwitchSlide
            //
            // Out, then in 70 ms later — what a real switch does — then the
            // grid's gap is logged half a second on. It must be the gutter.
            var switchToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.probeSwitchSlide", &switchToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        revealRegion(true)
                        try? await Task.sleep(for: .milliseconds(400))
                        revealRegion(false)
                        try? await Task.sleep(for: .milliseconds(70))
                        revealRegion(true)
                        try? await Task.sleep(for: .milliseconds(500))
                        let gap = promoted.frame.minY - gridScroll.frame.maxY
                        Self.log.notice(
                            "switch probe: gridTop=\(self.gridTop.constant, privacy: .public) gap=\(gap, privacy: .public) region alpha=\(self.promoted.alphaValue, privacy: .public)"
                        )
                        revealRegion(false)
                        try? await Task.sleep(for: .milliseconds(400))
                        render()
                    }
                }
            }

            // **Development only: step the promoted region through every
            // state**, without a server and without touching the tunnel.
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.cyclePromoted
            //
            // M5.8's acceptance test is every state put beside its artboard,
            // and four of the six cannot be reached on demand: Failed needs a
            // server to refuse us, Blocked and Setup need the permission
            // revoked, Switching needs two connectable profiles. Reading the
            // code instead of looking is what let M5 ship as a paraphrase of
            // the design (D250).
            var cycleToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.cyclePromoted", &cycleToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in self?.cyclePromoted() }
            }

            // **Development only: what would a click on each Connect hit?**
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.probeConnect
            //
            // The owner found single clicks on Connect doing nothing while a
            // double-click connected — an invisible label over the button. A
            // hit test at the button's centre answers that without a mouse,
            // which this session does not have.
            var probeToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.probeConnect", &probeToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    for line in grid.debugConnectHits {
                        Self.log.notice("debug: connect hit → \(line, privacy: .public)")
                    }
                }
            }

            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.openSettingsSheet", &token, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    if let open = window?.attachedSheet {
                        Self.log.notice("debug: closing the sheet")
                        window?.endSheet(open)
                        return
                    }
                    guard let profile = catalogue.profiles.last else { return }
                    Self.log.notice(
                        "debug: opening the settings sheet for \(profile.id.uuidString, privacy: .public)"
                    )
                    configure(profile)
                }
            }
        }

        private var debugStep = 0
        /// The synthetic failure the cycle is showing, so the Diagnostics sheet
        /// opened from it carries the same sentence and comparison.
        private var debugFailure: (record: FailureRecord, comparison: NetworkComparison)?

        private func cyclePromoted() {
            let profiles = catalogue.profiles
            let id = profiles.first?.id ?? UUID()
            let other = profiles.dropFirst().first?.id ?? UUID()
            let name = profiles.first.map { title(of: $0) } ?? "Configure SG"
            let otherName = profiles.dropFirst().first.map { title(of: $0) } ?? "Configure NA"
            let now = Date()
            let states: [(String, () -> Void)] = [
                ("idle", { self.debugFailure = nil; self.render() }),
                (
                    "connecting",
                    {
                        self.promoted.show(
                            .connecting(
                                Attempt(
                                    profile: id, startedAt: now.addingTimeInterval(-12),
                                    phase: OpenVPNPhase.waitingForSettings.asPhase,
                                    phaseEnteredAt: now.addingTimeInterval(-4))),
                            name: name)
                    }
                ),
                (
                    "connected",
                    {
                        self.promoted.show(
                            .connected(
                                Session(profile: id, since: now.addingTimeInterval(-5_025))),
                            name: name)
                    }
                ),
                (
                    "switching",
                    {
                        self.promoted.show(
                            .disconnecting(
                                Teardown(profile: id, startedAt: now, switchingTo: other)),
                            name: otherName, switchingFrom: name)
                    }
                ),
                (
                    "failed",
                    {
                        // A10 M2 with both blocks: the owner's own failure, on
                        // a Mac that moved from Wi-Fi to Ethernet since it last
                        // worked (A7's worked example).
                        self.promoted.comparison = NetworkComparison(
                            lastGood: NetworkFacts(
                                at: now.addingTimeInterval(-7200), interfaceName: "en0",
                                interfaceKind: .wiFi, gateway: "192.0.2.1",
                                gatewayHardwareAddress: "00:00:5e:00:53:01",
                                subnetMask: "255.255.255.0", addressIsRandomised: false),
                            now: NetworkFacts(
                                at: now, interfaceName: "en5", interfaceKind: .ethernet,
                                gateway: "192.0.2.1", gatewayHardwareAddress: "00:00:5e:00:53:01",
                                subnetMask: "255.255.255.0", addressIsRandomised: false))
                        let record = FailureRecord(
                            profile: id, at: now, reason: .settingsNeverSent,
                            phase: OpenVPNPhase.waitingForSettings.rawValue,
                            elapsed: .seconds(27), waited: .seconds(20), attempts: 7)
                        self.debugFailure = (record, self.promoted.comparison!)
                        self.promoted.show(.failed(record), name: name)
                        // The card as a real failure marks it (D292): the
                        // triangle, with Connect live.
                        self.grid.show(profiles, titles: self.catalogue.titles(), presence: [id: .failed])
                    }
                ),
                ("misplaced", { self.render(forcing: .wrongLocation) }),
                ("explain", { self.render(forcing: .setupExplain(again: false)) }),
                ("reapprove", { self.render(forcing: .setupExplain(again: true)) }),
                ("blocked", { self.render(forcing: .blocked) }),
                ("setup", { self.render(forcing: .setup) }),
            ]
            let (label, apply) = states[debugStep % states.count]
            debugStep += 1
            Self.log.notice("debug: promoted region → \(label, privacy: .public)")
            apply()
        }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    #if DEBUG
        /// **Development only.** Puts the window on the built-in display.
        ///
        /// Not a behaviour anybody wants shipped — a window belongs where the user
        /// left it — but during development the app is relaunched every few
        /// minutes, and it landing on whichever display was last used interrupts
        /// whatever the owner is doing on the other one. Compiled out of Release
        /// entirely.
        private func keepOnTheBuiltInDisplayWhileDeveloping() {
            guard let window,
                let builtIn = NSScreen.screens.first(where: {
                    guard
                        let number = $0.deviceDescription[
                            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                    else { return false }
                    return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
                })
            else { return }
            var frame = window.frame
            frame.origin = NSPoint(
                x: builtIn.visibleFrame.midX - frame.width / 2,
                y: builtIn.visibleFrame.midY - frame.height / 2)
            window.setFrame(frame, display: false)
        }
    #endif

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

        gridScroll.contentView = TopAlignedClipView()
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.autohidesScrollers = true
        gridScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(promoted)
        root.addSubview(gridScroll)
        root.addSubview(empty)

        NSLayoutConstraint.activate([
            promoted.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.gutter),
            promoted.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.gutter),
            promoted.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.gutter),

            gridTop,
            gridScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.gutter),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.gutter),
            gridScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Space.gutter),

            // The empty screen is the content, centred, with no grid and no
            // region behind it.
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: Space.xxl),
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


    /// `forcing` is **DEBUG-only in practice** and exists for one reason: the
    /// Setup and Blocked states cannot be reached on demand — they need the
    /// permission revoked — and their copy lives here, so a debug path that
    /// duplicated it would be describing a different screen (D250).
    /// The card's "Connected 2 hours ago" and D96's failure record, written
    /// once per session and once per failure — the store rejects nothing, so
    /// the guard against rewriting on every report is here.
    ///
    /// M5.3 wrote these from the old `renderConnection`; M5.4's rewrite of the
    /// window replaced that method and dropped both calls, and every profile
    /// connected since read "Never" (owner, 2026-09-09). Returns whether the
    /// store changed, so the caller re-reads it before building the cards.
    private func remember(_ connection: Connection, in stored: [Profile]) -> Bool {
        switch connection {
        case .connected(let session):
            guard let profile = stored.first(where: { $0.id == session.profile }),
                profile.lastConnected != session.since
            else { return false }
            try? store.setLastConnected(session.since, for: session.profile)
            // **Where it worked, replacing wherever it worked before** (D46,
            // D82). Written on a connection rather than at failure time,
            // because by then the answer describes the tunnel (D201).
            if let facts = tunnel.facts {
                try? store.setLastGood(facts, for: session.profile)
            }
            return true
        case .failed(let record):
            guard let profile = stored.first(where: { $0.id == record.profile }),
                profile.lastFailure != record
            else { return false }
            try? store.setLastFailure(record, for: record.profile)
            return true
        default:
            return false
        }
    }

    private func render(forcing forced: WindowState? = nil) {
        #if DEBUG
            rendersDuringSlide += 1
        #endif
        var stored = (try? store.profiles()) ?? []
        if remember(tunnel.connection, in: stored) { stored = (try? store.profiles()) ?? stored }
        var titles: [Profile.ID: String] = [:]
        for profile in stored { titles[profile.id] = title(of: profile) }

        let state =
            forced
            ?? WindowState.derive(
                connection: tunnel.connection, hasProfiles: !stored.isEmpty, setup: setup.state,
                misplaced: !location.isCorrect)

        // The explanation and the wrong-location screen take the Empty
        // screen's place: centred prose, the grid put away, nothing else
        // competing for the moment (D65, D62).
        // The state, by name, for the UI tests to wait on (M8.4): a word no
        // translation touches, on the region that shows it.
        promoted.setAccessibilityValue(Self.name(of: state, connection: tunnel.connection))

        let fullWindow: Bool =
            switch state {
            case .empty, .wrongLocation, .setupExplain: true
            default: false
            }
        empty.isHidden = !fullWindow
        gridScroll.isHidden = fullWindow
        promoted.isHidden = false

        switch state {
        case .empty:
            promoted.isHidden = true
            promoted.showNothing()
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

        case .wrongLocation:
            promoted.isHidden = true
            promoted.showNothing()
            let path = if case .elsewhere(let url) = location { url.path } else { Bundle.main.bundleURL.path }
            let message = SetupCopy.wrongLocation(path: path, canMove: InstallLocation.canMove)
            empty.show(
                title: message.title, body: message.body,
                action: message.action.map { ($0, { [weak self] in self?.moveToApplications() }) })

        case .setupExplain(let again):
            promoted.isHidden = true
            promoted.showNothing()
            let message = SetupCopy.explanation(again: again)
            empty.show(
                title: message.title, body: message.body,
                action: message.action.map { ($0, { [weak self] in self?.setup.continueSetup() }) },
                secondary: message.secondary.map { ($0, { [weak self] in self?.setup.notNow() }) })

        case .setup:
            let message = SetupCopy.waiting
            promoted.show(
                guidance: (
                    message.title, message.body,
                    message.action.map { ($0, { [weak self] in self?.setup.openSystemSettings() }) }
                ),
                blocked: false, emphasis: SetupCopy.waitingEmphasis)

        case .blocked:
            let reason: SetupFailure? = if case .blocked(let failure) = setup.state { failure } else { nil }
            let message = SetupCopy.blocked(reason)
            promoted.show(
                guidance: (
                    message.title, message.body,
                    message.action.map { ($0, { [weak self] in self?.setup.resume() }) }
                ),
                blocked: true)

        case .idle:
            // Left showing if it was showing: `revealRegion(false)` slides it
            // out and clears it on completion. Clearing it here emptied the
            // region in one frame and the slide animated an invisible view —
            // measured: zero intermediate frames on the way out, one on the
            // way in.
            if !regionWasShowing { promoted.showNothing() }

        case .active, .failed:
            // For a switch the region is about the profile being connected
            // *to*, and the third line names the one coming down — which is
            // how the Switching artboard narrates one operation rather than a
            // disconnect that happens to be followed by a connect (D70).
            var subject = involved
            var leaving: String?
            if case .disconnecting(let teardown) = tunnel.connection,
                let destination = teardown.switchingTo
            {
                subject = destination
                leaving = teardown.profile.flatMap { titles[$0] }
            }
            let name = subject.flatMap { titles[$0] } ?? String(localized: "this VPN")
            promoted.facts = tunnel.facts
            // *What changed since it last worked* (A7, D46): now against the
            // profile's last-good record, for the failure message's fourth
            // part. Only a failure reads it, so only a failure pays for it.
            if case .failed(let record) = tunnel.connection,
                let failed = stored.first(where: { $0.id == record.profile })
            {
                promoted.comparison = NetworkComparison(
                    lastGood: failed.lastGood,
                    now: tunnel.facts ?? currentNetwork(),
                    profileReplaced: (failed.origin.replacedAt ?? .distantPast)
                        > (failed.lastGood?.at ?? .distantFuture))
            } else {
                promoted.comparison = nil
            }
            promoted.show(tunnel.connection, name: name, switchingFrom: leaving)
        }

        // **No card leaves the grid** (M5.11, reversing D114). The lift-out
        // moved the next card into the clicked one's slot in a single frame —
        // label, host and selection border all changing at once — which read
        // as the profile being renamed rather than promoted. So the grid shows
        // every profile, and the one in use says so on its own card.
        grid.show(stored, titles: titles, presence: presence(titles: titles))

        // The region's arrival and departure are the only layout changes a
        // connect makes now, and both are animated (D113).
        revealRegion(state == .active || state == .failed || state == .setup || state == .blocked)

        keepTheClocksHonest()

    }

    /// What each card says about the connection. Derived from the same model
    /// the promoted region reads, never from the region (D236): two surfaces
    /// that must agree read one model.
    private func presence(titles: [Profile.ID: String]) -> [Profile.ID: ProfileCardView.Presence] {
        var marks: [Profile.ID: ProfileCardView.Presence] = [:]
        let connection = tunnel.connection
        switch connection {
        case .disconnected:
            break
        case .connecting(let attempt), .reconnecting(let attempt):
            marks[attempt.profile] = .inUse(.busy, word: connection.stateLine())
        case .connected(let session):
            marks[session.profile] = .inUse(.connected, word: String(localized: "Connected"))
        case .disconnecting(let teardown):
            if let leaving = teardown.profile {
                marks[leaving] = .inUse(.busy, word: String(localized: "Disconnecting"))
            }
            if let arriving = teardown.switchingTo {
                marks[arriving] = .inUse(.busy, word: String(localized: "Switching"))
            }
        case .failed(let record):
            // Marked, so the card that failed is findable when you look back
            // at the grid — and with its Connect (D292): the prose and Try
            // Again are in the region, but the card is a way back too.
            marks[record.profile] = .failed
        }
        return marks
    }

    /// Whether the region was showing at the last render, so its arrival and
    /// departure can be animated as transitions rather than applied as states.
    private var regionWasShowing = false

    /// Slides the region in or out, moving the grid as **one block** — every
    /// card keeps its slot and its neighbours, so the motion reads as a banner
    /// appearing and never as a card changing identity.
    ///
    /// **The model jumps; the presentation glides.** Layout goes to its final
    /// state at once, and Core Animation carries the grid's layer from where it
    /// was to where it now is. Two attempts at animating the *constraints*
    /// failed the same way: `NSScrollView` does not animate a constraint-driven
    /// frame change, so the region grew smoothly while the cards snapped —
    /// measured from the presentation layer, `started 552, presented 448` at
    /// both +100 ms and +200 ms. A translation on the layer is something a
    /// scroll view cannot refuse, and something a layout pass cannot cut short.
    ///
    /// Reduce Motion (D113): no translation. Layout changes at once and the
    /// region cross-fades, so there is still no single frame in which
    /// everything is different.
    private var slideGeneration = 0

    private func revealRegion(_ showing: Bool) {
        guard showing != regionWasShowing else { return }
        regionWasShowing = showing
        // **A slide that is overtaken must not finish.** A switch is a slide
        // out followed ~70 ms later by a slide in; the out's completion then
        // fired *after* the in had put the region back, set the grid's gap to
        // zero and blanked the region — so every switch ended with the cards
        // touching the region (owner's screenshots, 2026-09-08). Each reveal
        // takes a generation; a completion from an earlier one is ignored.
        slideGeneration += 1
        let generation = slideGeneration
        let slides = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let root = content.view
        // The grid's top edge in the root's (unflipped) coordinates, before
        // anything moves. `render()` has changed the region's content but no
        // layout pass has run yet, so this is still where the user sees it.
        let before = gridScroll.frame.maxY

        if showing {
            // Model to the final state now: region at full height, grid below.
            gridTop.constant = Space.gutter
            root.layoutSubtreeIfNeeded()
            let travel = before - gridScroll.frame.maxY  // > 0: the grid moved down
            promoted.alphaValue = 1
            #if DEBUG
                probeSlide(label: "in", travel: travel)
            #endif
            guard slides, let gridLayer = gridScroll.layer, let regionLayer = promoted.layer else {
                fadeOnly(showing: true, generation: generation)
                return
            }
            // From the old position to the new one, presentation only — and
            // "old" is where the layer *is*, which mid-slide-out is not where
            // the model had it (a switch overtakes the slide out).
            let held = gridLayer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = travel + held
            slide.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = regionLayer.presentation()?.opacity ?? 0
            fade.toValue = 1
            for animation in [slide, fade] {
                animation.duration = 0.28
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            gridLayer.add(slide, forKey: "slide")
            regionLayer.add(fade, forKey: "fade")
        } else {
            // The region stays in the model until the slide is over: collapse
            // it first and there is nothing left to fade. The grid glides up
            // over it, then the model catches up in one silent step.
            let travel = promoted.frame.height + Space.gutter  // the space that frees
            #if DEBUG
                probeSlide(label: "out", travel: travel)
            #endif
            guard slides, let gridLayer = gridScroll.layer, let regionLayer = promoted.layer else {
                fadeOnly(showing: false, generation: generation)
                return
            }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { self?.finishSlideOut(generation: generation) }
            }
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = gridLayer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            slide.toValue = travel  // up, in the layer's y-up coordinates
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = regionLayer.presentation()?.opacity ?? 1
            fade.toValue = 0
            for animation in [slide, fade] {
                animation.duration = 0.28
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // Held at the end until `finish` moves the model underneath it.
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
            }
            gridLayer.add(slide, forKey: "slide")
            regionLayer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    /// The slide out has finished: the region is gone from the presentation,
    /// so the model may now catch up — in one step nobody sees, because the
    /// grid's layer is already where the layout is about to put it.
    private func finishSlideOut(generation: Int) {
        // Overtaken by a later reveal: the region is back and the model is
        // already right. Finishing now would undo both.
        guard generation == slideGeneration else { return }
        promoted.showNothing()
        gridTop.constant = 0
        content.view.layoutSubtreeIfNeeded()
        gridScroll.layer?.removeAnimation(forKey: "slide")
        promoted.layer?.removeAnimation(forKey: "fade")
        promoted.alphaValue = 1
    }

    /// Reduce Motion, or no layer to animate: the layout is already final, so
    /// only the region's opacity changes, over 0.2 s.
    private func fadeOnly(showing: Bool, generation: Int) {
        if !showing { promoted.alphaValue = 1 }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                promoted.animator().alphaValue = showing ? 1 : 0
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if !showing { self?.finishSlideOut(generation: generation) }
                }
            })
    }

    #if DEBUG
        private var rendersDuringSlide = 0

        /// The record for the last profile, as the sheet will show it, plus
        /// what the export would carry. Two layers, one stream (D138).
        private func dumpDiagnostics() {
            // **Every profile**, not the last one: the first version dumped
            // `profiles.last` and reported an empty record for a profile
            // nobody had connected, which looked exactly like the feature not
            // working (2026-09-09).
            for profile in catalogue.profiles { dumpDiagnostics(for: profile) }
        }

        private func dumpDiagnostics(for profile: Profile) {
            let name = title(of: profile)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let record = await tunnel.diagnostics(for: profile.id) else {
                    Self.log.notice("debug: no record for \(name, privacy: .public)")
                    return
                }
                Self.log.notice(
                    "debug: \(name, privacy: .public) — \(record.attempts.count, privacy: .public) attempts kept"
                )
                for attempt in record.forScreen() {
                    Self.log.notice(
                        "debug: \(DiagnosticsCopy.header(attempt), privacy: .public)")
                    for entry in attempt.entries {
                        guard let phrase = DiagnosticsCopy.phrase(entry) else { continue }
                        let at = DateFormatter.localizedString(
                            from: entry.at, dateStyle: .none, timeStyle: .medium)
                        Self.log.notice(
                            "debug:   \(at, privacy: .public)  \(phrase, privacy: .public)")
                    }
                }
                // The export's layer: the engine's own lines, which the screen
                // never shows. Counted rather than printed — the point is that
                // they are kept, and the redactor is what makes that safe.
                let engineLines = record.attempts.reduce(0) { total, attempt in
                    total + attempt.entries.filter { !$0.kind.isForScreen }.count
                }
                Self.log.notice(
                    "debug: \(engineLines, privacy: .public) engine lines kept for the export")
                // And the What changed table, which M6.5 puts beside the
                // timeline (A14).
                let comparison = NetworkComparison(
                    lastGood: profile.lastGood, now: NetworkFactsReader.read(),
                    profileReplaced: (profile.origin.replacedAt ?? .distantPast)
                        > (profile.lastGood?.at ?? .distantFuture))
                for row in DiagnosticsCopy.comparison(comparison) {
                    Self.log.notice(
                        "debug:   \(row.label, privacy: .public): \(row.lastGood, privacy: .public) → \(row.now, privacy: .public)\(row.changed ? "  (changed)" : "", privacy: .public)"
                    )
                }
                if comparison.nothingChanged {
                    Self.log.notice("debug:   nothing about this Mac has changed since it worked")
                }
                // **The address hint, on demand** (feature-spec 4.11). It shows
                // only where macOS has randomised this Mac's address, which
                // on this machine is off — the owner turned it off to satisfy
                // an allowlist, which is the very failure the hint explains.
                // So the sentence is rendered here against a reading that has
                // the bit set, because a message nobody can make appear is a
                // message nobody has read.
                var randomised = NetworkFactsReader.read()
                randomised.addressIsRandomised = true
                let stall = FailureRecord(
                    profile: profile.id, at: Date(), reason: .settingsNeverSent, phase: "config",
                    waited: .seconds(20), attempts: 7)
                Self.log.notice(
                    "debug:   with a private address: \(FailureCopy.body(stall, name: name, facts: randomised), privacy: .public)"
                )
            }
        }

        /// Where the grid *is presented* a third and two thirds of the way
        /// through, against where it started. A slide shows two different
        /// intermediate numbers; a snap shows the destination both times.
        private func probeSlide(label: String, travel: CGFloat) {
            rendersDuringSlide = 0
            let start = gridScroll.frame.maxY
            Self.log.notice(
                "slide \(label, privacy: .public): grid travels \(Int(travel), privacy: .public) pt"
            )
            for delay in [0.10, 0.20] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let shown = self.gridScroll.layer?.presentation()?.frame.maxY ?? -1
                        let region = self.promoted.layer?.presentation()?.opacity ?? -1
                        Self.log.notice(
                            "slide +\(Int(delay * 1000), privacy: .public) ms: grid top presented=\(Int(shown), privacy: .public) (model \(Int(start), privacy: .public)); region opacity=\(String(format: "%.2f", region), privacy: .public); renders: \(self.rendersDuringSlide, privacy: .public)"
                        )
                    }
                }
            }
        }
    #endif

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
        catalogue.settings(of: profile)?.title.value ?? profile.title
    }

    /// `View ▸ Show Diagnostics`, and *Show details* on a failure (A14).
    ///
    /// **Reachable without a failure** (D141): with nothing wrong it shows the
    /// current environment against the last good connection, which is useful
    /// *before* connecting, and the recent attempts, successful ones included.
    /// The profile is the one involved — failed, in use — else the selected
    /// card, else the first; a sheet about nothing is not shown.
    @objc func showDiagnostics(_ sender: Any?) {
        let stored = catalogue.profiles
        let involved = tunnel.connection.profile.flatMap { id in stored.first { $0.id == id } }
        guard let profile = involved ?? grid.selected ?? stored.first else { return }
        presentDiagnostics(for: profile)
    }

    private func presentDiagnostics(for profile: Profile) {
        let name = title(of: profile)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let record = await tunnel.diagnostics(for: profile.id) ?? DiagnosticsLog(profile: profile.id)
            let now = tunnel.facts ?? currentNetwork()
            var comparison = NetworkComparison(
                lastGood: profile.lastGood, now: now,
                profileReplaced: (profile.origin.replacedAt ?? .distantPast)
                    > (profile.lastGood?.at ?? .distantFuture))
            // The sentence at the top is the failure the user is looking at,
            // when there is one: the live one, else the last recorded one if
            // it is what the record's latest attempt ended in.
            var failure: FailureRecord?
            if case .failed(let live) = tunnel.connection, live.profile == profile.id {
                failure = live
            } else if let kept = profile.lastFailure, case .failed? = record.latest?.outcome {
                failure = kept
            }
            #if DEBUG
                if let synthetic = debugFailure, synthetic.record.profile == profile.id {
                    failure = synthetic.record
                    comparison = synthetic.comparison
                }
            #endif
            let message = failure.map {
                FailureCopy.message($0, name: name, facts: now, comparison: comparison)
            }
            let sheet = DiagnosticsSheet(
                profileName: name, record: record, comparison: comparison, message: message,
                width: (window?.contentLayoutRect.width ?? DiagnosticsSheet.designWidth) - 2 * Space.gutter)
            content.presentAsSheet(sheet)
        }
    }

    /// *Move to Applications* (D62). The copy is made, the relaunch is
    /// scheduled, and this process quits; if the copy fails the screen stays
    /// and says why in a sentence, so the user is never left with nothing.
    private func moveToApplications() {
        do {
            try InstallLocation.moveAndRelaunch()
            Self.log.notice("moved to \(InstallLocation.destination.path, privacy: .public); relaunching from there")
            NSApp.terminate(nil)
        } catch {
            Self.log.error("could not move to Applications: \(error.localizedDescription, privacy: .public)")
            empty.show(
                title: String(localized: "Couldn't move VPN Plus"),
                body: String(localized: "macOS didn't allow the copy into your Applications folder. Drag VPN Plus there yourself, then open it from there."),
                action: nil)
        }
    }

    /// File > Import Profile…, and the button (2.1).
    @objc func importProfileFromPanel(_ sender: Any?) {
        importer.chooseFile(over: window)
    }

    /// A profile double-clicked in the Finder or dropped on the app icon (2.1).
    func importProfile(at url: URL) {
        importer.importProfile(at: url, over: window)
    }

    /// In rehearsal the window is shown *behind* everything and never made
    /// key (M8.4); otherwise as any window controller shows its window.
    override func showWindow(_ sender: Any?) {
        if Rehearsal.isActive {
            Rehearsal.show(window, sender: sender)
            return
        }
        super.showWindow(sender)
    }

    /// The store changed behind the window's back — the rehearsal's seeding
    /// (M8.4) — so every card is rebuilt from what it now says.
    func storeDidChange() { render() }

    /// `idle`, `active:connecting`, `active:connected`, `failed`, … — the
    /// window state and, while a tunnel is involved, the connection's own.
    private static func name(of state: WindowState, connection: Connection) -> String {
        let base =
            switch state {
            case .empty: "empty"
            case .wrongLocation: "wrongLocation"
            case .setupExplain: "setupExplain"
            case .setup: "setup"
            case .blocked: "blocked"
            case .idle: "idle"
            case .active: "active"
            case .failed: "failed"
            }
        if case .active = state { return base + ":" + connection.state.rawValue }
        return base
    }

    private func configure(_ profile: Profile) {
        guard let descriptor = catalogue.descriptor(of: profile) else { return }
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        let sheet = ProfileConfigurationSheet(
            profile: profile,
            descriptor: descriptor,
            overrides: overrides,
            passwordAlreadySaved: profile.credentialsSaved,
            onDone: { [weak self] outcome in
                guard let self else { return }
                Task { await commit(outcome, to: profile, descriptor: descriptor) }
            },
            onReplaceFile: { [weak self] in
                self?.importer.replaceFile(of: profile, over: self?.window)
            },
            onReveal: { [weak self] in self?.reveal(profile) })
        content.presentAsSheet(sheet)
    }

    /// Carries out what the sheet decided: the overrides, then the sign-in
    /// details, then the certificate. In that order because each is a
    /// different store, and the one that can fail loudest goes last.
    private func commit(
        _ outcome: ProfileConfigurationSheet.Outcome, to profile: Profile,
        descriptor: ProfileDescriptor
    ) async {
        var overrides = outcome.overrides
        switch outcome.certificate {
        case .unchanged:
            break
        case .chosen(let path, _, _):
            overrides.certificatePath = path
        case .cleared:
            overrides.certificatePath = nil
        }
        try? store.setOverrides(overrides, for: profile.id)
        // The title in the list follows the user's name for it.
        render()

        // The password never went into the overrides record (D127), so it is
        // applied here by the same path the sign-in sheet uses — and against
        // the settings the sheet has **just returned**, not the ones it opened
        // with. Unticking "remember the password" is a decision this surface
        // makes, and reading the old settings would have quietly ignored it.
        let decision = credentials(
            typedUsername: outcome.username, typedPassword: outcome.password,
            profile: profile,
            settings: ProfileSettings.compose(
                descriptor, with: overrides, filename: profile.origin.filename))
        if case .missing(let forgetting) = decision {
            // Nothing typed and nothing may be kept, so what is stored goes.
            // No prompt: this surface is never on the path to connecting
            // (2.13), so there is nothing here to ask for.
            if forgetting { await forget(profile) }
        } else {
            await apply(decision, to: profile)
        }
        await applyCertificate(outcome.certificate, to: profile)
    }

    /// D134's certificate, handed to the extension so a connection started
    /// from System Settings has it too.
    private func applyCertificate(
        _ change: ProfileConfigurationSheet.CertificateChange, to profile: Profile
    ) async {
        do {
            switch change {
            case .unchanged:
                return
            case .chosen(_, let certificate, let privateKey):
                let client = PrivilegedClient()
                try await client.setSecret(certificate, kind: .certificate, for: profile.id)
                try await client.setSecret(privateKey, kind: .privateKey, for: profile.id)
                Self.log.notice("stored a certificate for this profile")
            case .cleared:
                let client = PrivilegedClient()
                try await client.deleteSecret(kind: .certificate, for: profile.id)
                try await client.deleteSecret(kind: .privateKey, for: profile.id)
                Self.log.notice("removed this profile's certificate")
            }
        } catch {
            Self.log.error(
                "the certificate could not be stored: \(error.localizedDescription, privacy: .public)"
            )
            notify(
                String(
                    localized:
                        "VPN Plus couldn't store that certificate. The profile still works, using whatever certificate it carries."
                ))
        }
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

    /// **The RemoveConfirm artboard**: exactly what goes, as a list built
    /// from what this profile actually has, and the one reassurance that
    /// matters — the file on the user's Mac is not touched. "Remove", to
    /// match the menu item that opened this (M5.9).
    private func confirmDelete(_ profile: Profile) {
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        var goes = [String(localized: "the profile")]
        if profile.credentialsSaved {
            goes.append(String(localized: "its saved password in your Keychain"))
        }
        if overrides.certificatePath != nil {
            goes.append(String(localized: "its certificate and key"))
        }
        if profile.lastConnected != nil || profile.lastFailure != nil {
            goes.append(String(localized: "the record of when it last connected"))
        }
        let sheet = MessageSheet(
            title: String(localized: "Remove “\(title(of: profile))”?"),
            body: MessageSheet.prose(String(localized: "This removes:")),
            bullets: goes,
            footnote: MessageSheet.note(
                String(localized: "The original .ovpn file on your Mac is not touched."),
                code: [".ovpn"]),
            buttons: [
                MessageSheet.Button(title: String(localized: "Cancel"), role: .cancel),
                MessageSheet.Button(title: String(localized: "Remove"), role: .destructive) {
                    [weak self] in self?.remove(profile)
                },
            ],
            placement: .trailing)
        content.presentAsSheet(sheet)
    }

    private func remove(_ profile: Profile) {
        do {
            try store.remove(profile.id)
        } catch {
            notify(String(localized: "VPN Plus couldn't remove that profile."))
        }
        // The extension holds this profile's configuration and password, so
        // removing here is only half of it. A dangling secret is a secret
        // nobody is managing.
        Task {
            do {
                try await PrivilegedClient().deleteSecrets(for: profile.id)
            } catch {
                Self.log.error(
                    "the extension may still hold secrets for a removed profile: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        render()
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

    /// This Mac's network, read here and now.
    ///
    /// The provider's reading is the one that matters for a *failure* (D201);
    /// this is for the question asked before anything has started, when there
    /// is no provider and no reading to inherit.
    private func currentNetwork() -> NetworkFacts? {
        let facts = NetworkFactsReader.read()
        return facts.hasNetwork ? facts : nil
    }

    /// A10 M13, as a sheet rather than an alert (M5.10's shape).
    private func warnAboutTheLocalNetwork(
        _ profile: Profile,
        typed: (username: String, password: String, remember: Bool)?
    ) {
        let name = title(of: profile)
        let sheet = MessageSheet(
            icon: .warning,
            title: String(localized: "You're already on this network"),
            body: MessageSheet.prose(
                String(
                    localized:
                        "\(name) connects to a network this Mac is already on. Connecting anyway can stop other things working until you disconnect."
                ),
                bold: [name]),
            buttons: [
                MessageSheet.Button(title: String(localized: "Cancel"), role: .cancel),
                MessageSheet.Button(title: String(localized: "Connect Anyway"), role: .primary) {
                    [weak self] in self?.connect(to: profile, typed: typed, confirmed: true)
                },
            ],
            placement: .underTheText)
        content.presentAsSheet(sheet)
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
        typed: (username: String, password: String, remember: Bool)? = nil,
        confirmed: Bool = false
    ) {
        // **Setup is deferred to this moment** (D59). Approval missing: hold
        // the intent, explain first (D65), and come back here when it lands
        // (D60) — the user never clicks Connect twice. And **confirm before
        // trusting** (D309): the extension's toggle can move while the app
        // runs, so the last answer is asked again before the tunnel starts.
        setup.confirm(for: profile) { [weak self] in
            self?.startConnecting(to: profile, typed: typed, confirmed: confirmed)
        }
    }

    private func startConnecting(
        to profile: Profile,
        typed: (username: String, password: String, remember: Bool)?,
        confirmed: Bool
    ) {
        // **J12: already on this network** (A10 M13, D40). A profile whose
        // server is inside this Mac's own subnet is the owner's "arrived
        // home" case: connecting works and then quietly breaks everything
        // else on the LAN until they disconnect. A warning *before*
        // connecting, not a failure afterwards, and their decision either way.
        if !confirmed, let server = catalogue.descriptor(of: profile)?.server.host,
            let facts = tunnel.facts ?? currentNetwork(), facts.isOnThisNetwork(server)
        {
            warnAboutTheLocalNetwork(profile, typed: typed)
            return
        }
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

        let settings = catalogue.settings(of: profile)
        if let typed {
            // Their choice about saving is theirs to keep, so it goes in the
            // overrides record rather than living for one connection.
            if case .credentials(_, .offered(let on), _) = settings?.signIn, on != typed.remember {
                var overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
                overrides.savePassword = typed.remember
                try? store.setOverrides(overrides, for: profile.id)
            }
            rememberUsername(
                typed.username, for: profile, settings: catalogue.settings(of: profile))
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
            settings: catalogue.settings(of: profile))

        if case .missing(let forgetting) = decision {
            if forgetting { Task { await forget(profile) } }
            // **A prompt, not a failure** (A10): nothing has gone wrong, the
            // app simply does not have what it needs yet.
            askToSignIn(for: profile, settings: catalogue.settings(of: profile))
            return
        }

        let start: () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                // Stored before connecting, not after: an interrupted
                // connection must not cost the user their password (D219).
                await self.apply(decision, to: profile)
                do {
                    // Named after the profile, so the System Settings entry
                    // says which one it will connect (A13).
                    try await self.tunnel.prepare(
                        profile: profile.id, name: self.title(of: profile))
                    try self.tunnel.connect(
                        id: profile.id,
                        profile: text,
                        username: decision.sessionUsername,
                        password: decision.sessionPassword,
                        server: self.overrideServer(
                            for: profile, settings: self.catalogue.settings(of: profile)))
                } catch {
                    Self.log.error(
                        "could not start the tunnel: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        // **Switching is one click** (D70). Something else is up, or coming
        // up, for a different profile: the app performs the disconnect *and*
        // the connect, and the user is never told to disconnect first.
        // A Failed state is not something up (D287): its tunnel is gone and
        // the record is a message. Connect on another card from Failed is a
        // plain connect — before this it took the switch path and waited for
        // a teardown that never came, and the click did nothing.
        let current = tunnel.connection
        if current.hasTunnel, current.profile != profile.id {
            tunnel.replaceSession(with: profile.id, then: start)
        } else {
            start()
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

    /// Connecting from the status item's profile list.
    ///
    /// The same path as a card's Connect — **one behaviour, reached two ways**
    /// (D20). The menu is not allowed to be faster than the window, and the
    /// window is not allowed to be faster than the menu; the way to keep that
    /// true is for there to be one route through.
    func connectFromMenu(_ profile: Profile) {
        connect(to: profile)
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
