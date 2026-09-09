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
    /// A card's fixed height, from the artboard. Every card in the grid is
    /// the same object seen several times, so they are the same size.
    static let height: CGFloat = 128

    /// **220, not D167's 260.** The artboards fit three columns at 760 —
    /// `repeat(3, minmax(0,1fr))` over 720 pt of content with two 16 pt gaps
    /// is 229 pt a card — and they show a long profile name truncated at that
    /// width rather than dropping to two columns. So the design has already
    /// chosen: three columns, and the name truncates. 260 was what made this
    /// grid two columns wide.
    static let minimumWidth: CGFloat = 220

    let profile: Profile
    /// What to call it — the user's name for it if they gave one, else the
    /// configuration's, else the file's. **Composed by the caller**, because
    /// the rule lives with the overrides record and not in a view.
    private(set) var title: String

    /// Whether this card is the profile in use, and what to say about it.
    ///
    /// **This is D114 reversed, on purpose** (M5.11). The lift-out took the
    /// in-use card out of the grid, and the card in the next slot moved into
    /// its place — label, host and selection border all changing in one frame,
    /// which reads as a rename rather than a lift. The owner's words: *"why
    /// did my Singapore connection suddenly become US?"* So the card stays
    /// where it is, keeps its selection, and says what it is doing with the
    /// same gutter mark the promoted region uses. The **word replaces the
    /// Connect button** rather than joining it: one action, one place (D56),
    /// and the same height, so the row does not ripple.
    enum Presence: Equatable {
        case idle
        case inUse(Indicator, word: String)
        /// The profile that failed: **marked, with Connect back** (D292). The
        /// first version showed the word *Failed* in the button's place, and
        /// the owner asked for the button — a failed tunnel is gone, so there
        /// is something to connect, and the region's Try Again is one route,
        /// not the only one.
        case failed

        enum Indicator: Equatable { case busy, connected, failed }

        /// For the UI tests (M8.4): the presence as a word no language changes.
        var name: String {
            switch self {
            case .idle: "idle"
            case .inUse(.busy, _): "busy"
            case .inUse(.connected, _): "connected"
            case .inUse(.failed, _): "failing"
            case .failed: "failed"
            }
        }

        /// Whether Connect — button, double-click, menu — does anything.
        var canConnect: Bool { self == .idle || self == .failed }
    }

    var presence: Presence = .idle {
        didSet {
            setAccessibilityValue(presence.name)
            if presence != oldValue { renderPresence(animated: window != nil) }
        }
    }

    private let stateLabel: NSTextField = {
        // **Refuses hits.** It sits exactly over the Connect button, faded to
        // nothing while the card is idle — and an alpha-0 view still hit-tests.
        // As a plain label it took every single click meant for the button and
        // handed it up to the card, which selected; only a double-click reached
        // `onConnect`, through `mouseDown`. A word is never a target, so it
        // returns nil and the button beneath gets the click.
        let label = PassthroughLabel(labelWithString: "")
        label.font = Type.control
        label.textColor = Palette.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    /// A label that is never the answer to "what did the user click".
    private final class PassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    #if DEBUG
        /// What a click at the Connect button's centre would land on — the
        /// mouse-free version of "does the button work". `NSButton` means yes;
        /// anything else names the view in the way.
        var debugHitAtConnect: String {
            let centre = NSPoint(x: connectButton.frame.midX, y: connectButton.frame.midY)
            let hit = hitTest(convert(centre, to: superview))
            return hit.map { String(describing: type(of: $0)) } ?? "nil"
        }
    #endif
    private let dot = NSView()
    private let spinner = NSProgressIndicator()
    private let warning = NSImageView()

    var onSelect: ((Profile) -> Void)?
    var onFocus: ((Profile) -> Void)?
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
        // 8, from the artboard — the promoted region's 10 is the larger
        // surface and the difference is deliberate.
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        // **One selection indicator, not two.** The accent border below *is*
        // the focus indicator (D57), and the system ring drew a second one
        // just outside it at a wider corner radius — two blue strokes with a
        // sliver of card between them, worst at the corners. The border is
        // also the better of the two here: it stays visible when the window
        // is not key, and selection outlives focus.
        focusRingType = .none
        // **The grid positions a card by frame**, so this stays on: a view
        // with it turned off and no constraints placing it has no position and
        // no size, which is exactly how M5.4 first shipped an empty window.
        // Auto Layout still does everything *inside* the card.
        translatesAutoresizingMaskIntoConstraints = true
        toolTip = title

        connectButton.title = String(localized: "Connect")
        connectButton.bezelStyle = .rounded
        connectButton.font = Type.control
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.setAccessibilityLabel(String(localized: "Connect to \(title)"))
        connectButton.setAccessibilityIdentifier(AccessibilityID.profileConnect)

        moreButton.title = "···"
        // Bare, as the artboard draws it: a bezel gave the menu the same
        // weight as Connect, when Connect is the card's whole purpose.
        moreButton.isBordered = false
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.contentTintColor = Palette.textTertiary
        moreButton.font = Type.control
        moreButton.target = self
        moreButton.action = #selector(showMenu)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setAccessibilityLabel(String(localized: "More options for \(title)"))
        moreButton.setAccessibilityIdentifier(AccessibilityID.profileMore)

        // The artboard puts the `⋯` in the card's **top-right corner**, level
        // with the name, and gives **Connect the full width** at the bottom.
        // Side by side at the bottom made the two look like peers, when one
        // is the card's whole purpose and the other is a menu.
        // The in-use mark sits between the name and the menu, so an idle card
        // and an in-use card keep the name in the same place: a stack detaches
        // a hidden view, so nothing shifts when the mark comes and goes.
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        warning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warning.contentTintColor = Palette.stateFailed
        warning.translatesAutoresizingMaskIntoConstraints = false
        for mark in [dot, spinner, warning] { mark.isHidden = true }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            warning.widthAnchor.constraint(equalToConstant: 14),
            warning.heightAnchor.constraint(equalToConstant: 14),
        ])

        let heading = NSStackView(views: [nameField, dot, spinner, warning, moreButton])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Space.s
        nameField.setContentHuggingPriority(.init(1), for: .horizontal)

        // The state word occupies the Connect button's exact frame, so the two
        // can cross-fade and the card's height never changes.
        stateLabel.alignment = .center
        stateLabel.alphaValue = 0
        stateLabel.setAccessibilityIdentifier(AccessibilityID.profileState)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [heading, hostField, lastField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Space.xs
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(text)
        addSubview(connectButton)
        addSubview(stateLabel)
        NSLayoutConstraint.activate([
            stateLabel.leadingAnchor.constraint(equalTo: connectButton.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: connectButton.trailingAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: connectButton.centerYAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Space.l),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.l),
            heading.widthAnchor.constraint(equalTo: text.widthAnchor),

            connectButton.topAnchor.constraint(
                greaterThanOrEqualTo: text.bottomAnchor, constant: Space.m),
            connectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.l),
            connectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.l),
            connectButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.l),
            connectButton.heightAnchor.constraint(equalToConstant: Space.hitTarget),
            // No width constraint of its own: the grid guarantees the minimum,
            // because the minimum is what the column count is derived *from*
            // (D167), and a second opinion here could only conflict with it.
        ])

        // A card is one thing to VoiceOver, with the name as its identity and
        // its controls reachable inside it. A18 owns the full sweep (M8).
        // An element in its own right, or the tree shows its children loose
        // in the scroll view and there is no card to find (M8.4).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(AccessibilityID.profileCard)
        setAccessibilityValue(presence.name)
    }

    /// Puts the presence on the card. A cross-fade rather than a swap, because
    /// a swap in one frame is the whole defect this exists to fix.
    private func renderPresence(animated: Bool) {
        let inUse: Bool
        switch presence {
        case .idle:
            inUse = false
            dot.isHidden = true
            warning.isHidden = true
            spinner.stopAnimation(nil)
        case .failed:
            inUse = false
            dot.isHidden = true
            warning.isHidden = false
            spinner.stopAnimation(nil)
        case .inUse(let indicator, let word):
            inUse = true
            stateLabel.stringValue = word
            dot.isHidden = indicator != .connected
            warning.isHidden = indicator != .failed
            if indicator == .busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        // Not a control while in use: the action lives in the promoted region.
        connectButton.isEnabled = !inUse
        connectButton.setAccessibilityLabel(
            inUse ? stateLabel.stringValue : String(localized: "Connect to \(title)"))

        let fade = {
            self.connectButton.animator().alphaValue = inUse ? 0 : 1
            self.stateLabel.animator().alphaValue = inUse ? 1 : 0
        }
        if animated {
            // A cross-fade is also what Reduce Motion asks for (D113), so this
            // path does not branch on it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                fade()
            }
        } else {
            connectButton.alphaValue = inUse ? 0 : 1
            stateLabel.alphaValue = inUse ? 1 : 0
        }
    }

    /// "2 hours ago", or "Never". Relative, because the number of hours is not
    /// the point — whether it worked recently is (D46's input).
    /// The relative time, re-read. A card is built once and kept while its
    /// profile is unchanged (the grid's signature), so the words on it age:
    /// built the second the tunnel came up, it said *just now* eleven minutes
    /// later (owner's screenshots, 2026-09-09). The grid calls this on every
    /// render and on a clock (D286).
    func refreshClock(now: Date = Date()) {
        let text = Self.lastConnected(profile.lastConnected, now: now)
        if lastField.stringValue != text { lastField.stringValue = text }
    }

    static func lastConnected(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "Never") }
        // A session that began within the last minute — or, by a few
        // milliseconds of clock skew between the provider's timestamp and this
        // render, "in the future" — is *just now*. Left to the formatter it
        // read "Connected in 0 seconds" (owner's screenshot, 2026-09-09).
        if now.timeIntervalSince(date) < 60 { return String(localized: "Connected just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // "Connected yesterday", not "Last connected yesterday": the artboard
        // spends the width on the date rather than on the word "last", and a
        // card is 229 pt wide.
        return String(
            localized: "Connected \(formatter.localizedString(for: date, relativeTo: now))")
    }

    // MARK: - Drawing

    override func updateLayer() {
        // **Selection is keyboard focus** (D57), so it is drawn as focus: the
        // accent on the border, and the card's own surface underneath either
        // way. Filling the whole card with the selection colour made the one
        // profile on screen look like the connected one — a claim the grid is
        // not allowed to make, because a grid card never carries connection
        // state (D114).
        layer?.backgroundColor = Palette.surfaceCard.cgColor
        layer?.borderColor = (isSelected ? Palette.accent : Palette.border).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        dot.layer?.backgroundColor = Palette.stateConnected.cgColor
    }

    // MARK: - Gestures (D55, D57)

    /// **The body click selects.** It does not connect, and it does not open
    /// anything: A1's dead card was a trap, and a card that connects on a
    /// stray click is worse than a trap.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(profile)
        // Double-click connects an idle card and does nothing to the one in
        // use: it is already what it would become.
        if event.clickCount == 2, presence.canConnect { onConnect?(profile) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?(profile)
        NSMenu.popUpContextMenu(menu(), with: event, for: self)
    }

    /// Refuses while in use: the menu's Connect item and Return both route
    /// here, and the button being disabled covers only the button.
    @objc private func connect() {
        guard presence.canConnect else { return }
        #if DEBUG
            Logger(subsystem: "com.bossagroove.VPNPlus", category: "window")
                .notice("Connect pressed on \(self.profile.id.uuidString, privacy: .public)")
        #endif
        onConnect?(profile)
    }

    @objc private func showMenu() {
        let menu = menu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    /// A13's list, and deliberately short: everything on it is rare.
    private func menu() -> NSMenu {
        let menu = NSMenu()
        add(to: menu, String(localized: "Connect"), #selector(connect), "connect")
        menu.addItem(.separator())
        add(to: menu, String(localized: "Rename…"), #selector(beginRename), "rename")
        add(to: menu, String(localized: "Edit…"), #selector(configure), "edit")
        add(to: menu, String(localized: "Reveal Configuration File in Finder"), #selector(reveal), "reveal")
        menu.addItem(.separator())
        // Keyboard- and VoiceOver-reachable reordering: dragging is invisible
        // to VoiceOver (A18 finding 5), so it cannot be the only way.
        add(to: menu, String(localized: "Move Left"), #selector(moveCardLeft), "moveLeft")
        add(to: menu, String(localized: "Move Right"), #selector(moveCardRight), "moveRight")
        menu.addItem(.separator())
        add(to: menu, String(localized: "Remove…"), #selector(remove), "remove")
        return menu
    }

    private func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.setAccessibilityIdentifier(AccessibilityID.cardMenuPrefix + key)
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

    /// Focus arrived — by Tab, by AppKit choosing a new first responder, or
    /// by the card's own click. Reported apart from a click so the grid can
    /// tell the two apart.
    override func becomeFirstResponder() -> Bool {
        onFocus?(profile)
        return true
    }

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
