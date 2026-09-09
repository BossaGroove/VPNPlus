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

@main
enum VPNPlusApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One model, and **the app owns it** so that both surfaces read the same
    /// one. The status item is a peer of the window (D33), not something
    /// derived from it, and nothing derived from the other could be trusted to
    /// agree with it (D93).
    private let tunnel = TunnelController()
    private let catalogue = ProfileCatalogue()
    private var windowController: MainWindowController?
    private var statusItem: StatusItemController?
    private var notifier: FailureNotifier?
    private let updater = Updater()
    private lazy var settings = SettingsWindowController(updater: updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Someone who lives in the menu bar asked for no Dock tile; honoured
        // before any window appears, so nothing flashes.
        AppSettings.applyDockPolicy()
        // Sparkle, in its own words for the update and ours for the check.
        updater.start()
        let controller = MainWindowController(tunnel: tunnel, catalogue: catalogue)
        windowController = controller

        statusItem = StatusItemController(
            tunnel: tunnel,
            catalogue: catalogue,
            onOpenWindow: { [weak self] in
                self?.windowController?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            },
            onImport: { [weak self] in self?.windowController?.importProfileFromPanel(nil) },
            onConnect: { [weak self] in self?.windowController?.connectFromMenu($0) })

        // D76: the one push the app ever sends, for a failure nobody is
        // looking at. The window is "looked at" when the app is active and
        // the window is on screen; a closed window and a hidden app both mean
        // the Failed state is invisible.
        notifier = FailureNotifier(
            tunnel: tunnel, catalogue: catalogue,
            isLooking: { [weak controller] in
                NSApp.isActive && (controller?.window.map { $0.isVisible && !$0.isMiniaturized } ?? false)
            },
            onOpen: { [weak self] _ in
                self?.windowController?.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
            })

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        settings.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
        /// **Development only.** Opens Settings, or closes it if it is open:
        ///
        ///   notifyutil -p com.bossagroove.VPNPlus.debug.openSettings
        /// Each post steps on: open on General, then Menu Bar, then Software
        /// Update, then closed — so a capture loop sees every section.
        func debugToggleSettings() {
            guard settings.window?.isVisible == true else {
                settings.show(.general)
                showSettings(nil)
                return
            }
            let all = SettingsWindowController.Section.allCases
            let index = all.firstIndex(of: settings.section) ?? 0
            if index + 1 < all.count {
                settings.show(all[index + 1])
            } else {
                settings.close()
            }
        }

        /// **Development only.** A silent update check, reported on the card:
        ///
        ///   notifyutil -p com.bossagroove.VPNPlus.debug.checkForUpdates
        func debugCheckForUpdates() { updater.checkNow() }

        /// **Development only.** Posts the notification for a synthetic M14
        /// failure of the first profile, whether or not anyone is looking:
        ///
        ///   notifyutil -p com.bossagroove.VPNPlus.debug.postNotice
        func debugPostNotice() {
            guard let profile = catalogue.profiles.first else { return }
            notifier?.askOnce()
            notifier?.post(
                FailureNotice.notice(
                    for: FailureRecord(profile: profile.id, at: Date(), reason: .recoveryGaveUp, attempts: 5),
                    name: catalogue.title(of: profile)))
        }
    #endif

    /// Double-clicking a profile in the Finder, and dropping one on the app
    /// icon (2.1). The window may not exist yet on a cold launch, so the
    /// import is handed to it rather than run here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller = windowController else { return }
        for url in urls {
            controller.importProfile(at: url)
        }
    }

    /// The application menu. A16's *status* menu is `StatusItemController`'s;
    /// this is the one in the menu bar's left half, which macOS expects and
    /// which D12 needs for keyboard reachability. Settings (⌘,) arrives with
    /// its window in M7.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: "About VPN Plus"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘, and nowhere else (D13, D52).
        let settingsItem = appMenu.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: "Quit VPN Plus"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(
            withTitle: String(localized: "Import Profile…"),
            action: #selector(MainWindowController.importProfileFromPanel(_:)), keyEquivalent: "o")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        for (title, selector, key) in [
            (String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            (String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            (String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            (String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View ▸ Show Diagnostics: the log is reachable without a failure
        // (D141). ⌘D, and the window controller answers it.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: String(localized: "View"))
        viewMenu.addItem(
            withTitle: String(localized: "Show Diagnostics"),
            action: #selector(MainWindowController.showDiagnostics(_:)), keyEquivalent: "d")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    /// **False, now that there is a status item.**
    ///
    /// Closing the window is not quitting: the icon is the app's persistent
    /// presence and the answer to J1, and an app that vanished when its window
    /// closed would take that answer with it. *Open VPN Plus* in the menu
    /// brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
