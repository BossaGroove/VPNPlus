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
import OSLog

/// Settings (A15), from the three approved artboards: a sidebar of sections
/// on the left, the selected one filled with the accent; the section's
/// grouped cards on the right in the configuration sheet's idiom (D252–D256);
/// the window titled after the section. **⌘, from the application menu and
/// nowhere else** (D13, D52).
///
/// Three sections earn a place (D142): General, Menu Bar, Software Update.
/// Appearance is deliberately absent — the theme is macOS's setting, and ours
/// would be a second, disagreeing answer (D143).
@MainActor
final class SettingsWindowController: NSWindowController {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "settings")
    static let size = NSSize(width: 760, height: 540)

    enum Section: CaseIterable {
        case general, menuBar, softwareUpdate

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .menuBar: String(localized: "Menu Bar")
            case .softwareUpdate: String(localized: "Software Update")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .menuBar: "menubar.rectangle"
            case .softwareUpdate: "arrow.triangle.2.circlepath"
            }
        }
    }

    private let root = SettingsViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        window.setContentSize(Self.size)
        window.center()
        super.init(window: window)
        root.onSectionChange = { [weak self] section in self?.window?.title = section.title }
        window.title = root.section.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func showWindow(_ sender: Any?) {
        root.refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    /// Debug: the section shown, and a way to step through them.
    var section: Section { root.section }
    func show(_ section: Section) { root.show(section) }
}

/// The window's content: sidebar and section.
@MainActor
final class SettingsViewController: NSViewController {
    typealias Section = SettingsWindowController.Section
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "settings")

    private static let sidebarWidth: CGFloat = 216
    private static let sidebarInset: CGFloat = 16
    private static let contentInset: CGFloat = 20
    private static var contentWidth: CGFloat {
        SettingsWindowController.size.width - sidebarInset - sidebarWidth - 2 * contentInset
    }
    private static let rowHeight: CGFloat = 44

    private(set) var section: Section = .general {
        didSet {
            if section != oldValue {
                renderSidebar()
                renderSection()
                onSectionChange?(section)
            }
        }
    }
    var onSectionChange: ((Section) -> Void)?

    private var items: [Section: NSButton] = [:]
    private let content = NSStackView()

    // General
    private let languagePicker = NSPopUpButton()
    private let loginSwitch = NSSwitch()
    private let dockSwitch = NSSwitch()
    // Menu Bar
    private let profileNameSwitch = NSSwitch()

    /// A view that says when the appearance changed, so the layer colours
    /// follow dark and light (a view controller is not told).
    private final class Root: NSView {
        var onAppearanceChange: (() -> Void)?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearanceChange?()
        }
    }

    /// Debug and tests: the section, set from outside.
    func show(_ section: Section) { self.section = section }

    override func loadView() {
        let root = Root(frame: NSRect(origin: .zero, size: SettingsWindowController.size))
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.paint() }

        // Sidebar: a raised panel with one button per section.
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.cornerRadius = 12
        sidebar.layer?.borderWidth = 1
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        for section in Section.allCases {
            let item = sidebarItem(for: section)
            items[section] = item
            list.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        sidebar.addSubview(list)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.sidebarInset),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.sidebarInset),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.sidebarInset),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            // The sibling's panel: a full gutter around the pills, not a lip.
            list.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: Self.sidebarInset),
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: Self.sidebarInset),
            list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -Self.sidebarInset),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: Self.contentInset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.sidebarInset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.contentInset),
        ])
        self.sidebar = sidebar
        view = root
        renderSidebar()
        renderSection()
    }

    private var sidebar: NSView?

    override func viewWillAppear() {
        super.viewWillAppear()
        paint()
    }

    private func paint() {
        view.layer?.backgroundColor = Palette.surfaceWindow.cgColor
        sidebar?.layer?.backgroundColor = Palette.surfaceCard.cgColor
        sidebar?.layer?.borderColor = Palette.border.cgColor
        renderSidebar()
    }

    /// Re-reads every control from the settings, for a window shown again.
    func refresh() {
        languagePicker.selectItem(at: AppSettings.Language.allCases.firstIndex(of: AppSettings.language) ?? 0)
        loginSwitch.state = AppSettings.launchesAtLogin ? .on : .off
        dockSwitch.state = AppSettings.showsDockIcon ? .on : .off
        profileNameSwitch.state = AppSettings.showsProfileNameInMenuBar ? .on : .off
    }

    // MARK: - Sidebar

    private var icons: [Section: NSImageView] = [:]
    private var labels: [Section: NSTextField] = [:]

    /// A pill: the button for the click and the keyboard, and its content
    /// laid out by us — NSButton's own image-leading layout puts the icon on
    /// the pill's edge, and the sibling insets it (owner, 2026-09-09).
    private func sidebarItem(for section: Section) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(select(_:)))
        button.tag = Section.allCases.firstIndex(of: section) ?? 0
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.setAccessibilityLabel(section.title)

        let icon = NSImageView(
            image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: section.title)
        label.font = Type.control
        label.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, label] as [NSView] {
            // Clicks fall through to the button beneath.
            view.setAccessibilityElement(false)
            button.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Space.s),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -Space.m),
        ])
        icons[section] = icon
        labels[section] = label
        return button
    }

    @objc private func select(_ sender: NSButton) {
        section = Section.allCases[sender.tag]
    }

    private func renderSidebar() {
        for (candidate, button) in items {
            let selected = candidate == section
            button.layer?.backgroundColor = selected ? Palette.accent.cgColor : NSColor.clear.cgColor
            let colour: NSColor = selected ? .white : Palette.textPrimary
            icons[candidate]?.contentTintColor = colour
            labels[candidate]?.textColor = colour
            labels[candidate]?.font = selected ? Type.controlEmphasis : Type.control
        }
    }

    // MARK: - Sections

    private func renderSection() {
        content.views.forEach { $0.removeFromSuperview() }
        switch section {
        case .general: renderGeneral()
        case .menuBar: renderMenuBar()
        case .softwareUpdate: renderSoftwareUpdate()
        }
        refresh()
    }

    private func renderGeneral() {
        let language = card()
        languagePicker.removeAllItems()
        for choice in AppSettings.Language.allCases { languagePicker.addItem(withTitle: choice.title) }
        languagePicker.target = self
        languagePicker.action = #selector(languageChanged)
        // The sibling's picker: the value and its chevron, no bezel — a
        // setting reads as a value, not as a form field (owner, 2026-09-09).
        languagePicker.isBordered = false
        languagePicker.font = Type.control
        language.addRow(String(localized: "Language"), languagePicker)
        footnote(String(localized: "Changing this restarts VPN Plus."))

        let behaviour = card()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        behaviour.addRow(String(localized: "Launch VPN Plus at login"), loginSwitch)
        dockSwitch.target = self
        dockSwitch.action = #selector(dockChanged)
        behaviour.addRow(String(localized: "Show icon in the Dock"), dockSwitch)
    }

    private func renderMenuBar() {
        let menuBar = card()
        profileNameSwitch.target = self
        profileNameSwitch.action = #selector(profileNameChanged)
        menuBar.addRow(String(localized: "Show profile name in the menu bar"), profileNameSwitch)
        footnote(
            String(localized: """
                Shown only while a connection is active. A crowded menu bar wants the icon alone; \
                someone switching often wants to see which profile is up.
                """))
    }

    private func renderSoftwareUpdate() {
        // The update controls arrive with the updater (M7.4); the version is
        // a fact the app has now.
        let version = card()
        let line = NSTextField(labelWithString: AppSettings.versionLine)
        line.font = Type.control
        line.textColor = Palette.textSecondary
        version.addRow(String(localized: "Version"), line)
    }

    private func card() -> SettingsCard {
        let card = SettingsCard(width: Self.contentWidth, rowHeight: Self.rowHeight)
        content.addArrangedSubview(card)
        content.setCustomSpacing(Space.l + 2, after: card)
        return card
    }

    private func footnote(_ text: String) {
        guard let card = content.views.last else { return }
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = Type.hint
        note.textColor = Palette.textSecondary
        note.preferredMaxLayoutWidth = Self.contentWidth - 2 * SettingsCard.Metric.inset
        note.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(6, after: card)
        content.addArrangedSubview(note)
        content.setCustomSpacing(Space.l + 2, after: note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsCard.Metric.inset),
            note.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -SettingsCard.Metric.inset),
        ])
    }

    // MARK: - Changes

    /// D145: a language change offers the relaunch it needs, and never
    /// changes half the app under the user.
    @objc private func languageChanged() {
        let chosen = AppSettings.Language.allCases[max(0, languagePicker.indexOfSelectedItem)]
        guard chosen != AppSettings.language else { return }
        AppSettings.language = chosen
        Self.log.notice("language → \(chosen.rawValue.isEmpty ? "system" : chosen.rawValue, privacy: .public)")
        let sheet = MessageSheet(
            title: String(localized: "Restart VPN Plus to switch to \(chosen.title)?"),
            body: MessageSheet.prose(
                String(localized: "The new language takes effect when VPN Plus starts again. Nothing else changes.")),
            buttons: [
                MessageSheet.Button(title: String(localized: "Later"), role: .cancel),
                MessageSheet.Button(
                    title: String(localized: "Restart Now"), role: .primary,
                    action: {
                        do {
                            try Relaunch.schedule()
                            NSApp.terminate(nil)
                        } catch {
                            Self.log.error("relaunch: \(error.localizedDescription, privacy: .public)")
                        }
                    }),
            ],
            placement: .trailing)
        presentAsSheet(sheet)
    }

    @objc private func loginChanged() {
        let on = loginSwitch.state == .on
        do {
            try AppSettings.setLaunchesAtLogin(on)
            Self.log.notice("launch at login → \(on, privacy: .public)")
        } catch {
            Self.log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            loginSwitch.state = on ? .off : .on
            let sheet = MessageSheet(
                icon: .warning,
                title: String(localized: "Couldn't change the login item"),
                body: MessageSheet.prose(
                    String(localized: "macOS didn't allow it. You can add or remove VPN Plus under Login Items in System Settings.")),
                buttons: [MessageSheet.Button(title: String(localized: "OK"), role: .primary)],
                placement: .trailing)
            presentAsSheet(sheet)
        }
    }

    @objc private func dockChanged() {
        AppSettings.showsDockIcon = dockSwitch.state == .on
        Self.log.notice("dock icon → \(AppSettings.showsDockIcon, privacy: .public)")
    }

    @objc private func profileNameChanged() {
        AppSettings.showsProfileNameInMenuBar = profileNameSwitch.state == .on
        Self.log.notice("menu bar profile name → \(AppSettings.showsProfileNameInMenuBar, privacy: .public)")
    }
}
