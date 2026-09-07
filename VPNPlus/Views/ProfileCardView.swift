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

/// One profile, as a card. **There is exactly one design of this**, and that
/// is a consequence rather than a simplification: the lift-out rule (D114)
/// takes the involved profile *out* of the grid into the promoted region, so a
/// card in the grid is always inactive. No status dot, no state variants,
/// nothing to keep in sync with a tunnel.
///
/// What it shows, and why each line is there (A12):
///
/// | Line | Why |
/// |---|---|
/// | Name, **truncated in the middle** | Org-issued profiles share a prefix, so the tail is what distinguishes them (D164). The full name is the tooltip |
/// | Server host | Identity, not diagnostics — two "office" profiles may differ only here |
/// | Last connected | "2 hours ago", or "Never" |
/// | **Connect** | The one control, state-labelled (D56) |
/// | ⋯ | Rename · Edit · Move · Remove · Reveal (D58) |
@MainActor
final class ProfileCardView: NSView {
    /// A12/D167: what a real profile name needs on one line, and the number
    /// the column count is derived from. Not a column count — that is derived
    /// from *this*, so a name fits or does not by arithmetic rather than by
    /// accident.
    static let minimumWidth: CGFloat = 260

    let profile: Profile
    /// What to call it — the user's name for it if they gave one, else the
    /// configuration's, else the file's. **Composed by the caller**, because
    /// the rule lives with the overrides record and not in a view.
    private(set) var title: String

    var onSelect: ((Profile) -> Void)?
    /// The new name, once the user has committed it.
    var onRename: ((Profile, String) -> Void)?
    var onConnect: ((Profile) -> Void)?
    var onConfigure: ((Profile) -> Void)?
    var onDelete: ((Profile) -> Void)?
    var onReveal: ((Profile) -> Void)?
    var onMove: ((Profile, Int) -> Void)?

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let nameField: NSTextField
    private let hostField: NSTextField
    private let lastField: NSTextField
    private let connectButton = NSButton()
    private let moreButton = NSButton()
    /// Present only while the name is being edited in place.
    private var editor: NSTextField?

    init(profile: Profile, title: String) {
        self.profile = profile
        self.title = title
        // Middle truncation, per D164. The whole name is one hover away.
        nameField = .label(
            title, font: Type.cardTitle, colour: Palette.textPrimary,
            truncation: .byTruncatingMiddle)
        hostField = .label(
            profile.descriptor?.server.host ?? "", font: Type.caption,
            colour: Palette.textSecondary)
        lastField = .label(
            Self.lastConnected(profile.lastConnected), font: Type.caption,
            colour: Palette.textTertiary)
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = title

        connectButton.title = String(localized: "Connect")
        connectButton.bezelStyle = .rounded
        connectButton.font = Type.control
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.setAccessibilityLabel(String(localized: "Connect to \(title)"))

        moreButton.title = "···"
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.font = Type.control
        moreButton.target = self
        moreButton.action = #selector(showMenu)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setAccessibilityLabel(String(localized: "More options for \(title)"))

        let text = NSStackView(views: [nameField, hostField, lastField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Space.xs
        text.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [connectButton, moreButton])
        controls.orientation = .horizontal
        controls.spacing = Space.s
        controls.translatesAutoresizingMaskIntoConstraints = false

        addSubview(text)
        addSubview(controls)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor, constant: Space.l),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.l),

            controls.topAnchor.constraint(
                greaterThanOrEqualTo: text.bottomAnchor, constant: Space.m),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            controls.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Space.l),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.l),
            controls.heightAnchor.constraint(greaterThanOrEqualToConstant: Space.hitTarget),

            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
        ])

        // A card is one thing to VoiceOver, with the name as its identity and
        // its controls reachable inside it. A18 owns the full sweep (M8).
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    /// "2 hours ago", or "Never". Relative, because the number of hours is not
    /// the point — whether it worked recently is (D46's input).
    static func lastConnected(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never connected") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(
            localized: "Last connected \(formatter.localizedString(for: date, relativeTo: Date()))")
    }

    // MARK: - Drawing

    override func updateLayer() {
        layer?.backgroundColor =
            (isSelected ? Palette.surfaceSelected : Palette.surfaceCard).cgColor
        layer?.borderColor = (isSelected ? Palette.accent : Palette.border).cgColor
        // Selection is keyboard focus (D57), so it has to be visible as more
        // than a tint — Increase Contrast users and anyone with a light
        // selection colour need the border to carry it too.
        layer?.borderWidth = isSelected ? 2 : 1
        nameField.textColor = isSelected ? .selectedTextColor : Palette.textPrimary
    }

    // MARK: - Gestures (D55, D57)

    /// **The body click selects.** It does not connect, and it does not open
    /// anything: A1's dead card was a trap, and a card that connects on a
    /// stray click is worse than a trap.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(profile)
        if event.clickCount == 2 { onConnect?(profile) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?(profile)
        NSMenu.popUpContextMenu(menu(), with: event, for: self)
    }

    @objc private func connect() { onConnect?(profile) }

    @objc private func showMenu() {
        let menu = menu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    /// A13's list, and deliberately short: everything on it is rare.
    private func menu() -> NSMenu {
        let menu = NSMenu()
        add(to: menu, String(localized: "Connect"), #selector(connect))
        menu.addItem(.separator())
        add(to: menu, String(localized: "Rename…"), #selector(beginRename))
        add(to: menu, String(localized: "Edit…"), #selector(configure))
        add(to: menu, String(localized: "Reveal Configuration in Finder"), #selector(reveal))
        menu.addItem(.separator())
        // Keyboard- and VoiceOver-reachable reordering: dragging is invisible
        // to VoiceOver (A18 finding 5), so it cannot be the only way.
        add(to: menu, String(localized: "Move Left"), #selector(moveCardLeft))
        add(to: menu, String(localized: "Move Right"), #selector(moveCardRight))
        menu.addItem(.separator())
        add(to: menu, String(localized: "Remove…"), #selector(remove))
        return menu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    /// **Renaming happens on the card**, not in a dialogue.
    ///
    /// A13 notes the one subtlety and AppKit hands it to us: while the field
    /// has focus it owns Return, so Return commits the rename instead of
    /// connecting. The grid's key handling never sees the event, which means
    /// there is no flag to get wrong.
    @objc private func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: title)
        field.font = Type.cardTitle
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        nameField.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
        ])
        editor = field
        window?.makeFirstResponder(field)
    }

    private func endRename(commit: Bool) {
        guard let editor else { return }
        let typed = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        self.editor = nil
        nameField.isHidden = false
        window?.makeFirstResponder(self)
        // An empty name is not a name: it reverts rather than leaving a card
        // with nothing on it.
        guard commit, !typed.isEmpty, typed != title else { return }
        onRename?(profile, typed)
    }

    @objc private func configure() { onConfigure?(profile) }
    @objc private func reveal() { onReveal?(profile) }
    @objc private func remove() { onDelete?(profile) }
    // Named away from NSResponder's own moveLeft(_:)/moveRight(_:), which
    // are the caret-movement actions and would be ambiguous here.
    @objc private func moveCardLeft() { onMove?(profile, -1) }
    @objc private func moveCardRight() { onMove?(profile, 1) }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onSelect?(profile)
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}

extension ProfileCardView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        // Return, Tab, or focus leaving: all of them commit. Escape arrives as
        // `cancelOperation` below and does not.
        endRename(commit: true)
    }

    override func cancelOperation(_ sender: Any?) {
        endRename(commit: false)
    }
}
