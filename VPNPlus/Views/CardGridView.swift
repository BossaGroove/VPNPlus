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

/// The grid of cards.
///
/// **The column count is derived from the card, never fixed** (D167, found by
/// A19). A fixed three columns makes a real profile name fit or not fit by
/// accident; deriving the count from a width chosen to hold one means it fits
/// by arithmetic:
///
/// ```
/// columns = max(1, floor((width + gap) / (cardMinimum + gap)))
/// ```
///
/// `width` is the grid's own width — whoever hosts it owns the margins, and
/// the grid only divides what it is given.
///
/// **A12's worked example is wrong and this is the arithmetic.** It says a
/// 760 pt window gives three columns; three 260 pt cards with two 16 pt gaps
/// and two 24 pt margins need **860 pt**, so 760 gives **two**. The example
/// predates the 260 pt minimum, which A19 added later as D167 — nobody
/// re-checked the multiplication against it. Three columns arrive at 860 pt
/// and four at 1,412 pt.
///
/// Cards keep a consistent width whatever the profile count.
///
/// **The order is the user's and nothing moves on its own** (D119). A
/// self-sorting grid destroys the muscle memory that makes a one-click switch
/// feel like one click, and it moves the target between the glance and the
/// click.
/// A clip view that puts its content at the **top**.
///
/// `NSClipView` is not flipped, so a document view shorter than the scroll
/// view sits in the middle of it — which is where the first card appeared
/// before this existed. Five lines, and the alternative is laying the document
/// view out by hand.
@MainActor
final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CardGridView: NSView {
    private static let gap = Space.l

    var onSelect: ((Profile) -> Void)?
    var onRename: ((Profile, String) -> Void)?
    var onConnect: ((Profile) -> Void)?
    var onConfigure: ((Profile) -> Void)?
    var onDelete: ((Profile) -> Void)?
    var onReveal: ((Profile) -> Void)?
    var onMove: ((Profile, Int) -> Void)?

    private(set) var profiles: [Profile] = []
    /// What to call each profile, by id. Composed by the window from the
    /// configuration and the user's overrides, because that rule is the
    /// model's and not a view's.
    private var titles: [Profile.ID: String] = [:]
    /// What the cards were built from, so an unchanged grid is left alone.
    private var signature: [String] = []
    private var cards: [ProfileCardView] = []
    private(set) var selected: Profile?

    /// Type-ahead's buffer. A13 answered "how many profiles" with *usually
    /// under ten* and removed search on the strength of this, so it is
    /// load-bearing rather than a flourish.
    private var typed = ""
    private var typedAt = Date.distantPast

    override var isFlipped: Bool { true }

    /// D167's formula, and the only place a column count is decided.
    static func columns(
        forWidth width: CGFloat, cardMinimum: CGFloat = ProfileCardView.minimumWidth
    ) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int(((width + gap) / (cardMinimum + gap)).rounded(.down)))
    }

    func show(_ profiles: [Profile], titles: [Profile.ID: String] = [:]) {
        // **Rebuild only when something on a card changed.**
        //
        // The window renders on every report from the provider — five phases
        // and a 2 s poll during an attempt — and rebuilding the cards each
        // time would take the focus ring away, lose the selection, and, worst,
        // destroy an in-place rename under the user's hands mid-word.
        let signature = profiles.map {
            "\($0.id)|\(titles[$0.id] ?? $0.title)|\($0.lastConnected?.timeIntervalSince1970 ?? 0)|\($0.credentialsSaved)"
        }
        guard signature != self.signature else {
            self.profiles = profiles
            self.titles = titles
            renderSelection()
            return
        }
        self.signature = signature
        self.profiles = profiles
        self.titles = titles
        cards.forEach { $0.removeFromSuperview() }
        cards = profiles.map { profile in
            let card = ProfileCardView(profile: profile, title: titles[profile.id] ?? profile.title)
            card.onSelect = { [weak self] in self?.select($0) }
            card.onRename = { [weak self] in self?.onRename?($0, $1) }
            card.onConnect = { [weak self] in self?.onConnect?($0) }
            card.onConfigure = { [weak self] in self?.onConfigure?($0) }
            card.onDelete = { [weak self] in self?.onDelete?($0) }
            card.onReveal = { [weak self] in self?.onReveal?($0) }
            card.onMove = { [weak self] in self?.onMove?($0, $1) }
            addSubview(card)
            return card
        }
        // A selection that survives a redraw: the user's place in the grid is
        // not ours to lose because a name changed somewhere.
        if let selected, !profiles.contains(where: { $0.id == selected.id }) {
            self.selected = profiles.first
        } else if selected == nil {
            self.selected = profiles.first
        }
        renderSelection()
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func select(_ profile: Profile) {
        selected = profile
        renderSelection()
        onSelect?(profile)
    }

    private func renderSelection() {
        for card in cards { card.isSelected = card.profile.id == selected?.id }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let columns = Self.columns(forWidth: bounds.width)
        let gaps = CGFloat(columns - 1) * Self.gap
        let width = max(ProfileCardView.minimumWidth, (bounds.width - gaps) / CGFloat(columns))
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, card) in cards.enumerated() {
            let column = index % columns
            if column == 0, index > 0 {
                y += rowHeight + Self.gap
                rowHeight = 0
            }
            // A card has a minimum *and* a preferred height and never a fixed
            // one (D158, D166): a long name in German is taller than a short
            // one in English, and the layout follows the content.
            let height = card.fittingSize.height
            rowHeight = max(rowHeight, height)
            card.frame = NSRect(
                x: CGFloat(column) * (width + Self.gap), y: y, width: width, height: height)
        }
        contentHeight = y + rowHeight
    }

    private var contentHeight: CGFloat = 0 {
        didSet { if contentHeight != oldValue { invalidateIntrinsicContentSize() } }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(contentHeight, 1))
    }

    // MARK: - Keyboard (D12, D57)

    override var acceptsFirstResponder: Bool { true }

    /// Arrows move, Return connects, ⌘⌫ removes, and letters jump to a name.
    /// **The whole grid is drivable without a mouse** (D12) — and none of it
    /// is a shortcut for something there is no other way to do.
    override func keyDown(with event: NSEvent) {
        let columns = Self.columns(forWidth: bounds.width)
        guard
            let index = profiles.firstIndex(where: { $0.id == selected?.id })
                ?? (profiles.isEmpty ? nil : 0)
        else {
            super.keyDown(with: event)
            return
        }

        switch event.specialKey {
        case .leftArrow: move(to: index - 1)
        case .rightArrow: move(to: index + 1)
        case .upArrow: move(to: index - columns)
        case .downArrow: move(to: index + columns)
        case .carriageReturn, .enter:
            onConnect?(profiles[index])
        case .delete,
            .backspace where event.modifierFlags.contains(.command):
            onDelete?(profiles[index])
        default:
            guard let characters = event.charactersIgnoringModifiers,
                !characters.isEmpty,
                !event.modifierFlags.contains(.command)
            else {
                super.keyDown(with: event)
                return
            }
            typeAhead(characters)
        }
    }

    private func move(to index: Int) {
        guard profiles.indices.contains(index) else { return }
        select(profiles[index])
        window?.makeFirstResponder(cards[index])
    }

    /// Prefix match, and the buffer forgets after a second so a second word
    /// starts a new search rather than extending a stale one.
    private func typeAhead(_ characters: String) {
        if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
        typed += characters.lowercased()
        typedAt = Date()
        // Against what the user *sees* on the card, not the underlying
        // default name: typing "sing" must find the card that says Singapore.
        func name(_ profile: Profile) -> String {
            (titles[profile.id] ?? profile.title).lowercased()
        }
        guard
            let match = profiles.firstIndex(where: { name($0).hasPrefix(typed) })
                ?? profiles.firstIndex(where: { name($0).contains(typed) })
        else { return }
        move(to: match)
    }
}
