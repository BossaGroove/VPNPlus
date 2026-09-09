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
import VPNPlusCore
import os

/// **S1 — the most important surface in the product**, because it answers the
/// most frequent job (J1: *am I connected?*) with **zero interaction** (D33).
///
/// Which is why it is built as a **peer of the window** rather than derived
/// from it. It reads the same model the window reads (D93), so the two cannot
/// disagree — commitment 6, and the highest-frequency commitment in the brief.
///
/// Three things it does that the incumbents do not:
///
/// - **Failed looks different from Disconnected** (D18). A1 found OpenVPN
///   Connect's `getIcon()` mapping `FAILURE` to the disconnected art, so its
///   menu bar is structurally incapable of saying something went wrong.
/// - **The profile list stays enabled while connected** (D147). OpenVPN
///   Connect sets `enabled: isDisconnected`, greying out switching at exactly
///   the moment switching is what you want.
/// - **The menu is built when opened** (D150), never cached from last time.
@MainActor
final class StatusItemController: NSObject {
    /// Whether to put the active profile's name beside the icon.
    ///
    /// Default **off** (D168, A15). It earns its place as a setting because
    /// both behaviours are legitimately wanted and no default serves both: a
    /// crowded menu bar or a notch wants the icon alone, while somebody
    /// switching several times a day wants to see which profile is up without
    /// opening anything. The picker is M7's; the behaviour is here.
    static let showProfileNameKey = "menuBar.showProfileName"

    private let item = NSStatusItem.make()
    private let tunnel: TunnelController
    private let catalogue: ProfileCatalogue
    private let onOpenWindow: () -> Void
    private let onImport: () -> Void
    private let onConnect: (Profile) -> Void

    /// The busy and reconnecting icons are animated, so something has to turn
    /// the frames over. Nothing else on screen ticks for this.
    private var animation: Timer?
    private var frame = 0

    init(
        tunnel: TunnelController,
        catalogue: ProfileCatalogue,
        onOpenWindow: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onConnect: @escaping (Profile) -> Void
    ) {
        self.tunnel = tunnel
        self.catalogue = catalogue
        self.onOpenWindow = onOpenWindow
        self.onImport = onImport
        self.onConnect = onConnect
        super.init()

        item.button?.imagePosition = .imageLeading
        item.menu = NSMenu()
        item.menu?.delegate = self

        tunnel.observe { [weak self] connection, _ in self?.render(connection) }
        // Settings' *Show profile name in the menu bar* takes effect at once.
        NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render(tunnel.connection) }
        }

        #if DEBUG
        // Development only: **the app opens its own status menu on request.**
        //
        //   notifyutil -p com.bossagroove.VPNPlus.debug.popStatusMenu
        //
        // Because the alternative was asking the owner to open the menu and
        // leave it open — which is not a thing anybody can do, since clicking
        // away to say "it's open" closes it. An instruction that cannot be
        // followed is worse than no instruction.
        var popToken: Int32 = NOTIFY_TOKEN_INVALID
        notify_register_dispatch(
            "com.bossagroove.VPNPlus.debug.popStatusMenu", &popToken, DispatchQueue.main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let button = item.button, let menu = item.menu else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
        }
        #endif

        #if DEBUG
            // Development only, and only when asked:
            //
            //   VPNPLUS_DUMP_STATUS_ICON=1 open -a "VPN Plus"
            //
            // The status item cannot be screenshotted on its own — the menu bar is
            // a single window and everybody else's items are in it, and nothing
            // but ours belongs in an image. So the button draws itself instead,
            // which is exact and private. It is how the reconnecting icon was
            // caught wearing Connected's shape.
            // And the icon, on request, for the same reason: it is the only
            // way to see an *animation* without watching somebody's menu bar.
            //
            //   notifyutil -p com.bossagroove.VPNPlus.debug.dumpStatusIcon
            //
            // Firing it a few times during a connect shows the frames turning
            // over, which is the only claim about this surface that a still
            // image cannot settle.
            var dumpToken: Int32 = NOTIFY_TOKEN_INVALID
            notify_register_dispatch(
                "com.bossagroove.VPNPlus.debug.dumpStatusIcon", &dumpToken, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { [weak self] in self?.dumpIcon() }
            }

            guard ProcessInfo.processInfo.environment["VPNPLUS_DUMP_STATUS_ICON"] != nil else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.dumpIcon()
            }
        #endif
    }

    // MARK: - The icon (D94, D112)

    /// **Four visuals for five meanings.** Six states are not legible at this
    /// size, so Connecting and Disconnecting share the busy treatment and the
    /// menu text says which. Reconnecting keeps its own, because it carries
    /// different news: *you were connected and something broke* — which a
    /// glance should convey.
    ///
    /// **Template images only** — owner decision, no colour and no setting.
    /// Shape carries the state, so it survives greyscale, small sizes and the
    /// notch, which is the whole requirement.
    private func render(_ connection: Connection) {
        animation?.invalidate()
        animation = nil
        frame = 0

        switch connection.state {
        case .disconnected:
            symbol("shield")
        case .connected:
            symbol("shield.fill")
        case .failed:
            symbol("shield.slash")
        case .connecting, .disconnecting:
            // Filling up: something is happening.
            animate(["shield", "shield.lefthalf.filled"], every: 0.6)
        case .reconnecting:
            // Sweeping left to right, faster — and **never showing the filled
            // shield**, which belongs to Connected alone.
            //
            // The first attempt at this alternated outline and filled, so half
            // its frames *were* the connected icon: a glance at a recovering
            // tunnel could read as a working one, which is the confusion D18
            // and A16 both exist to prevent. Seen by rendering the symbols
            // rather than by reasoning about their names.
            animate(["shield.lefthalf.filled", "shield.righthalf.filled"], every: 0.35)
        }

        item.button?.title = label(for: connection)
        item.button?.toolTip = tooltip(for: connection)
        // The icon carries the state; the label is only identity, so the
        // accessibility description has to carry the state in words.
        item.button?.setAccessibilityLabel(tooltip(for: connection))
    }

    #if DEBUG
        /// The button draws itself to a file. No screen capture, and nothing
        /// but our own item can be in the result — the menu bar is one window
        /// and everybody else's items are in it.
        ///
        /// The result is a **template** image, drawn in the menu bar's tint,
        /// which is near-white in dark mode: composite it onto a dark ground
        /// before looking at it, or it reads as an empty picture.
        private func dumpIcon() {
            let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "statusItem")
            guard let button = item.button else {
                log.error("no status button to draw")
                return
            }
            guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
                log.error("the status button would not give a bitmap for \(NSStringFromRect(button.bounds), privacy: .public)")
                return
            }
            button.cacheDisplay(in: button.bounds, to: rep)
            let stamp = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000
            let path = "/tmp/vpnplus-status-icon-\(stamp).png"
            guard let png = rep.representation(using: .png, properties: [:]) else {
                log.error("the bitmap would not encode as PNG")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                log.notice("drew the status icon to \(path, privacy: .public)")
            } catch {
                log.error("could not write the icon: \(error.localizedDescription, privacy: .public)")
            }
        }
    #endif

    private func symbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        item.button?.image = image
        #if DEBUG
            // Which frame, and when. **Better evidence than a screenshot for
            // an animation**: two stills prove two shapes exist, while a
            // timestamped sequence proves the frames are turning over, at the
            // cadence they were meant to, in the state that asked for them.
            Logger(subsystem: "com.bossagroove.VPNPlus", category: "statusItem")
                .notice("icon → \(name, privacy: .public)\(image == nil ? " (MISSING)" : "", privacy: .public)")
        #endif
    }

    private func animate(_ names: [String], every interval: TimeInterval) {
        symbol(names[0])
        animation = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame = (self.frame + 1) % names.count
                self.symbol(names[self.frame])
            }
        }
    }

    /// The profile's name beside the icon, when the user asked for it.
    ///
    /// **Only while something is active**: Idle has no profile to name, so it
    /// costs no space. Middle-truncated for the same reason the cards are
    /// (D164) — org-issued profiles share a prefix, and the tail is what
    /// distinguishes them.
    private func label(for connection: Connection) -> String {
        guard Preferences.defaults.bool(forKey: Self.showProfileNameKey),
            connection.state != .disconnected,
            let profile = catalogue.profile(connection.profile)
        else { return "" }
        return " " + middleTruncated(catalogue.title(of: profile), to: 18)
    }

    /// `VPN Plus — Connected to X`: state and identity, in human words.
    ///
    /// A1 found OpenVPN Connect's tooltip returning `${appName}: ${status}` —
    /// *"OpenVPN Connect: FAILURE"* — which was the **only** place in that app
    /// a failure was ever admitted, in the exact form our brief forbids.
    /// **The tooltip is a convenience, never the report.**
    private func tooltip(for connection: Connection) -> String {
        guard let profile = catalogue.profile(connection.profile) else {
            return String(localized: "VPN Plus — not connected")
        }
        let name = catalogue.title(of: profile)
        switch connection.state {
        case .connected: return String(localized: "VPN Plus — connected to \(name)")
        case .connecting: return String(localized: "VPN Plus — connecting to \(name)")
        case .reconnecting: return String(localized: "VPN Plus — reconnecting to \(name)")
        case .disconnecting: return String(localized: "VPN Plus — disconnecting from \(name)")
        case .failed: return String(localized: "VPN Plus — couldn't connect to \(name)")
        case .disconnected: return String(localized: "VPN Plus — not connected")
        }
    }

    private func middleTruncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let half = (limit - 1) / 2
        return text.prefix(half) + "…" + text.suffix(half)
    }
}

// MARK: - The menu

extension StatusItemController: NSMenuDelegate {
    /// **Built when opened, from current state** (D150) — never cached from
    /// the last time it was shown, because the tunnel can change without us
    /// (D75) and a stale menu is a lie with a click target on it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let connection = tunnel.connection
        let involved = catalogue.profile(connection.profile)

        // **The menu opens with the answer to J1**, always — even when the
        // answer is "nothing is running".
        //
        // Without this, Idle opened straight into the profile list, and the
        // one profile at the top of the menu read like a heading rather than
        // something to click (seen in the owner's screenshot). A16 makes the
        // status menu a full control surface that is never worse than the
        // window at anything; a control surface that does not say the state
        // is worse at the only thing this surface is for.
        if let involved {
            add(menu, catalogue.title(of: involved), enabled: false)
            add(menu, connection.menuLine(), enabled: false)
        } else {
            add(menu, String(localized: "Not connected"), enabled: false)
        }
        menu.addItem(.separator())

        switch connection.state {
        case .connected:
            add(menu, String(localized: "Disconnect")) { [weak self] in self?.tunnel.disconnect() }
        case .connecting, .reconnecting:
            add(menu, String(localized: "Cancel")) { [weak self] in self?.tunnel.disconnect() }
        case .failed:
            if let involved {
                add(menu, String(localized: "Try Again")) { [weak self] in self?.onConnect(involved)
                }
            }
            // The window is where the details are (A4); this brings it
            // forward rather than inventing a second place to read them.
            add(menu, String(localized: "Show Details…")) { [weak self] in self?.onOpenWindow() }
        case .disconnecting, .disconnected:
            break
        }
        if connection.state != .disconnected { menu.addItem(.separator()) }

        // **Flat, and live while connected** (D147). Clicking one connects or
        // switches to it: OpenVPN Connect greys this list out exactly when
        // switching is what you want, and burying it in a submenu charges a
        // move for the second-most-common action.
        //
        // Same order as the window — one order to learn, on both surfaces
        // (D119).
        for profile in catalogue.profiles {
            let item = add(menu, catalogue.title(of: profile)) { [weak self] in
                self?.onConnect(profile)
            }
            item?.state = profile.id == involved?.id ? .on : .off
        }
        if !catalogue.profiles.isEmpty { menu.addItem(.separator()) }

        add(menu, String(localized: "Import Profile…")) { [weak self] in self?.onImport() }
        add(menu, String(localized: "Open VPN Plus")) { [weak self] in self?.onOpenWindow() }
        menu.addItem(.separator())

        // **State-labelled, and no confirmation** (D148) — the label already
        // said it. Quitting while connected is a real problem: the tunnel can
        // outlive the app, and then the icon is gone, the window is gone, and
        // J1 becomes unanswerable.
        let quit =
            connection.state == .connected
            ? String(localized: "Disconnect and Quit")
            : String(localized: "Quit VPN Plus")
        add(menu, quit) { [weak self] in
            if self?.tunnel.connection.state == .connected { self?.tunnel.disconnect() }
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    private func add(
        _ menu: NSMenu, _ title: String, enabled: Bool = true, run: (() -> Void)? = nil
    ) -> NSMenuItem? {
        let item = NSMenuItem(
            title: title, action: run == nil ? nil : #selector(Action.run), keyEquivalent: "")
        if let run {
            let action = Action(run)
            item.target = action
            item.representedObject = action
        }
        item.isEnabled = enabled && run != nil
        menu.addItem(item)
        return item
    }

    /// A menu item's target has to be an object, and the object has to outlive
    /// the menu. The item holds it.
    private final class Action: NSObject {
        private let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run() { body() }
    }
}

extension Connection {
    /// The state line inside the menu, which has room for the count and the
    /// clock that the icon cannot carry.
    ///
    /// **The failure title goes here** (D149) — never a code, and never only
    /// a tooltip.
    func menuLine(at now: Date = Date()) -> String {
        switch self {
        case .connected:
            return String(localized: "Connected · \(clock(at: now))")
        case .connecting, .reconnecting:
            let clock = clock(at: now)
            return "\(stateLine(at: now)) · \(clock)"
        case .failed(let record):
            return FailureCopy.shortTitle(record)
        case .disconnecting, .disconnected:
            return stateLine(at: now)
        }
    }
}

extension NSStatusItem {
    static func make() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
