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

/// One group of settings rows, drawn as System Settings draws them: a rounded
/// inset card, each row a label on the left and its control on the right,
/// hairlines between.
///
/// **Why this and not a two-column form.** A flat form put every category in
/// one list and indented the switches to the field column, so they read as
/// starting halfway across the sheet — the owner's words, and correct. A card
/// per category separates the groups, and a row whose control sits at the
/// card's own trailing edge gives every control one edge to line up on
/// whatever its label's length (D251).
///
/// **Why AppKit and not SwiftUI.** The sibling app gets exactly this from
/// `Form { Section { … } }.formStyle(.grouped)`, and that is what M7's Settings
/// panel should use. This sheet is not a leaf surface — it owns a file picker,
/// Keychain writes and D223's no-rebuild discipline — and CLAUDE.md reserves
/// SwiftUI for the simple ones.
@MainActor
final class SettingsCard: NSView {
    enum Metric {
        static let radius: CGFloat = 8
        /// Inside the card, left and right of every row.
        static let inset: CGFloat = 12
        static let rowHeight: CGFloat = 34
        /// The label column's share, so a control has room but a long label
        /// still wraps rather than shoving it off the edge.
        static let labelShare: CGFloat = 0.46
    }

    private let stack = NSStackView()
    private let width: CGFloat

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metric.radius

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    #if DEBUG
        /// Each row's height, for the dump. A card that grows does so because
        /// one row grew, and this says which.
        var rowHeights: String {
            stack.views.map { $0.isHidden ? "·" : "\(Int($0.fittingSize.height))" }
                .joined(separator: " ")
        }
    #endif

    override func updateLayer() {
        layer?.backgroundColor = Palette.surfaceGrouped.cgColor
    }

    /// Adds a row: `label` on the left, `control` at the trailing edge.
    ///
    /// The control's trailing edge is **pinned**, never left to a stack view's
    /// hugging priorities — those answer differently for a short label than a
    /// long one, which is how two switches ended up in two different places
    /// (D251).
    @discardableResult
    func addRow(_ label: String, _ control: NSView, fillsWidth: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: label)
        name.font = Type.control
        name.textColor = Palette.textPrimary
        name.lineBreakMode = .byWordWrapping
        name.maximumNumberOfLines = 0
        name.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)
        row.addSubview(control)

        var constraints = [
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metric.inset),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: control.leadingAnchor, constant: -Space.m),
            control.trailingAnchor.constraint(
                equalTo: row.trailingAnchor, constant: -Metric.inset),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Space.xs),
            control.bottomAnchor.constraint(
                lessThanOrEqualTo: row.bottomAnchor, constant: -Space.xs),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: Metric.rowHeight),
        ]
        if fillsWidth {
            // A text field takes the rest of the row rather than hugging its
            // own text, so every field in a card has the same left edge.
            constraints.append(
                control.leadingAnchor.constraint(
                    equalTo: row.leadingAnchor,
                    // The card's own width, not `bounds`, which is zero
                    // until the first layout pass.
                    constant: Metric.inset + width * Metric.labelShare))
        }
        add(row, constraints: constraints)
        return row
    }

    /// A row with no label — a caption, or something that spans the width.
    ///
    /// Note: the rule belongs to the row *below* it, so a card whose **first**
    /// row can be hidden would show a rule at its top edge. No card in this
    /// app has one — every card's first row is always visible — and the fix if
    /// one ever does is to hide the first visible row's rule on refresh.
    @discardableResult
    func addFullWidthRow(_ content: NSView, height: CGFloat? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        var constraints = [
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metric.inset),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -Metric.inset),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: Space.s),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Space.s),
        ]
        if let height { constraints.append(row.heightAnchor.constraint(equalToConstant: height)) }
        add(row, constraints: constraints)
        return row
    }

    private func add(_ row: NSView, constraints: [NSLayoutConstraint]) {
        var own = constraints
        if !stack.views.isEmpty {
            // **The hairline lives inside the row it separates**, not beside
            // it. As its own view in the stack it outlived the row: every
            // caption that reads "from this profile" is hidden, and each left
            // a rule behind — one dangling at the bottom of a single-row card,
            // and two abutting into a 2 pt line wherever two hidden rows met.
            // Measured, 2026-09-08. Inside the row, hiding the row hides it.
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Palette.border.cgColor
            rule.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(rule)
            own += [
                rule.heightAnchor.constraint(equalToConstant: 1),
                rule.topAnchor.constraint(equalTo: row.topAnchor),
                rule.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Metric.inset),
                rule.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            ]
        }
        stack.addView(row, in: .top)
        NSLayoutConstraint.activate(own + [row.widthAnchor.constraint(equalTo: widthAnchor)])
    }
}
