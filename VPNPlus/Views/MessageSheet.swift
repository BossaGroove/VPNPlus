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

/// A message in the window, where an `NSAlert` used to be (M5.10).
///
/// **From the ImportError and RemoveConfirm artboards**, which share one
/// shape: a 440 pt sheet under the title bar, 22 pt of padding, a 15 pt
/// semibold title, a body in secondary text, and then the two things the
/// artboards order differently. A message that asks the user to *do*
/// something puts its buttons **under the text**, left-aligned, with the
/// alternative as a footnote beneath them; a confirmation puts what it will
/// do in a list, the reassurance under that, and its buttons at the
/// **trailing edge**. `placement` is that choice, and nothing else moves.
///
/// Why not an alert: an alert is the system's window over ours, with the
/// system's icon and the system's idea of where the text goes. The artboards
/// put these in the window because that is where the thing they are about
/// is — the card being removed, the grid the profile was going to join.
@MainActor
final class MessageSheet: NSViewController {
    struct Button {
        enum Role {
            /// The accent-filled default; Return presses it.
            case primary
            /// The system's red, filled; Return presses it, as the artboard
            /// has it — the user opened this confirmation on purpose.
            case destructive
            /// Bezelled, no colour.
            case plain
            /// Bezelled; Escape presses it.
            case cancel
        }
        let title: String
        let role: Role
        var action: @MainActor () -> Void = {}
    }

    enum Placement {
        /// Under the text, leading edge; a footnote may follow (ImportError).
        case underTheText
        /// At the bottom, trailing edge; the footnote sits above (RemoveConfirm).
        case trailing
    }

    enum Icon {
        /// Something needs the user, and nothing is broken.
        case warning
    }

    /// One click behind a count (D187): a link that unfolds the list.
    struct Details {
        let link: String
        let lines: [String]
    }

    static let width: CGFloat = 440
    private static let inset: CGFloat = 22
    private static let iconColumn: CGFloat = 22
    private static let iconGap: CGFloat = 14

    private let icon: Icon?
    private let heading: String
    private let body: NSAttributedString
    private let bullets: [String]
    private let footnote: NSAttributedString?
    private let details: Details?
    private let buttons: [Button]
    private let placement: Placement

    private var detailLines: NSStackView?
    private var detailsLink: NSButton?

    init(
        icon: Icon? = nil,
        title: String,
        body: NSAttributedString,
        bullets: [String] = [],
        footnote: NSAttributedString? = nil,
        details: Details? = nil,
        buttons: [Button],
        placement: Placement
    ) {
        self.icon = icon
        self.heading = title
        self.body = body
        self.bullets = bullets
        self.footnote = footnote
        self.details = details
        self.buttons = buttons
        self.placement = placement
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Prose

    /// A body with a name in bold and a filename in code, the way the
    /// artboard sets "**work.ovpn** refers to `ca.crt`".
    /// Built from the finished sentence, so translations keep their order.
    static func prose(
        _ text: String, bold: [String] = [], code: [String] = [], font: NSFont = Type.body
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: Palette.textSecondary])
        func mark(_ needle: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard !needle.isEmpty, let range = text.range(of: needle) else { return }
            result.addAttributes(attributes, range: NSRange(range, in: text))
        }
        for needle in bold {
            mark(needle, [
                .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                .foregroundColor: Palette.textPrimary,
            ])
        }
        for needle in code {
            mark(needle, [.font: Type.code])
        }
        return result
    }

    /// A footnote: the same, one size down.
    static func note(_ text: String, code: [String] = []) -> NSAttributedString {
        prose(text, code: code, font: Type.detail)
    }

    // MARK: - Layout

    private var columnWidth: CGFloat {
        Self.width - 2 * Self.inset - (icon == nil ? 0 : Self.iconColumn + Self.iconGap)
    }

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Space.s
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true

        let title = label(heading, font: Type.messageTitle, color: Palette.textPrimary)
        column.addArrangedSubview(title)

        let text = NSTextField(labelWithAttributedString: body)
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = columnWidth
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        column.addArrangedSubview(text)

        if !bullets.isEmpty {
            let list = NSStackView(
                views: bullets.map {
                    label("· \($0)", font: Type.body, color: Palette.textSecondary)
                })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = Space.xs
            list.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(list)
        }

        if let details {
            let link = NSButton(
                title: details.link, target: self, action: #selector(toggleDetails))
            link.isBordered = false
            link.font = Type.detail
            link.contentTintColor = Palette.accent
            link.setButtonType(.momentaryChange)
            detailsLink = link
            column.addArrangedSubview(link)

            let lines = NSStackView(
                views: details.lines.map { label($0, font: Type.code, color: Palette.textSecondary) }
            )
            lines.orientation = .vertical
            lines.alignment = .leading
            lines.spacing = Space.xs
            lines.translatesAutoresizingMaskIntoConstraints = false
            lines.isHidden = true
            detailLines = lines
            column.addArrangedSubview(lines)
        }

        let note = footnote.map { text -> NSTextField in
            let field = NSTextField(labelWithAttributedString: text)
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = columnWidth
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            return field
        }
        let row = buttonRow()
        switch placement {
        case .underTheText:
            column.addArrangedSubview(row)
            column.setCustomSpacing(Space.m, after: text)
            if let note {
                column.addArrangedSubview(note)
                column.setCustomSpacing(Space.m, after: row)
            }
        case .trailing:
            if let note {
                column.addArrangedSubview(note)
                column.setCustomSpacing(Space.m, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
            }
            column.addArrangedSubview(row)
            column.setCustomSpacing(Space.xl, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
            row.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        }

        let content: NSView
        if let icon {
            let image = NSImageView()
            image.image = NSImage(
                systemSymbolName: Self.symbol(for: icon), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            image.contentTintColor = Self.tint(for: icon)
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: Self.iconColumn).isActive = true
            image.heightAnchor.constraint(equalToConstant: 24).isActive = true

            let pair = NSStackView(views: [image, column])
            pair.orientation = .horizontal
            pair.alignment = .top
            pair.spacing = Self.iconGap
            pair.translatesAutoresizingMaskIntoConstraints = false
            content = pair
        } else {
            content = column
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.inset),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier(AccessibilityID.messageSheet)
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    /// Says how big the content makes the sheet; without it the sheet keeps
    /// the height the root view was constructed with (M5.7's lesson).
    private func fit() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = columnWidth
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: columnWidth).isActive = true
        return field
    }

    private func buttonRow() -> NSStackView {
        let views = buttons.enumerated().map { index, spec -> NSButton in
            let button = NSButton(title: spec.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            switch spec.role {
            case .primary:
                button.keyEquivalent = "\r"
            case .destructive:
                button.keyEquivalent = "\r"
                button.bezelColor = Palette.destructive
            case .cancel:
                button.keyEquivalent = "\u{1b}"
            case .plain:
                break
            }
            return button
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.s
        row.translatesAutoresizingMaskIntoConstraints = false
        if placement == .trailing {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            row.insertArrangedSubview(spacer, at: 0)
        }
        return row
    }

    private static func symbol(for icon: Icon) -> String {
        switch icon {
        case .warning: "exclamationmark.triangle"
        }
    }

    private static func tint(for icon: Icon) -> NSColor {
        switch icon {
        case .warning: Palette.stateWarning
        }
    }

    // MARK: - Actions

    @objc private func pressed(_ sender: NSButton) {
        guard buttons.indices.contains(sender.tag) else { return }
        let action = buttons[sender.tag].action
        dismiss(nil)
        // After the sheet has gone: the action may open an Open panel on the
        // same window, and a sheet cannot attach while another is closing.
        Task { @MainActor in action() }
    }

    /// Escape, when no button owns it.
    override func cancelOperation(_ sender: Any?) {
        dismiss(nil)
    }

    @objc private func toggleDetails() {
        guard let detailLines else { return }
        detailLines.isHidden.toggle()
        // The sheet grows to the list and shrinks back; AppKit animates a
        // presented sheet to its new `preferredContentSize`.
        fit()
    }
}
