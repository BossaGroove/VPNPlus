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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
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

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
