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

/// A title, a sentence or two, and **at most one action**.
///
/// Every screen in A5 has this shape: the empty library, the two setup
/// moments, and the blocked one. None of them offers Quit (D22) — if the user
/// would rather not, they close the window, which is what the red dot is for.
/// Offering Quit is Tunnelblick's mistake, and it is worse on a screen whose
/// problem is one click from being solved.
@MainActor
final class GuidanceView: NSView {
    private let titleLabel = NSTextField.label(font: Type.sectionTitle, colour: Palette.textPrimary)
    private let bodyLabel = NSTextField.label(
        font: Type.body, colour: Palette.textSecondary, truncation: .byWordWrapping)
    private let hintLabel = NSTextField.label(
        font: Type.caption, colour: Palette.textTertiary, truncation: .byWordWrapping)
    private let actionButton = NSButton()
    private var action: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.usesSingleLineMode = false

        actionButton.bezelStyle = .rounded
        actionButton.font = Type.control
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(act)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, bodyLabel, actionButton, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.m
        stack.setCustomSpacing(Space.l, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Space.hitTarget),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// `hint` is the quiet line under the button — the drag hint on the empty
    /// screen, and nothing on the others.
    func show(
        title: String, body: String, action: (title: String, run: () -> Void)?, hint: String = ""
    ) {
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.preferredMaxLayoutWidth = 460
        hintLabel.stringValue = hint
        hintLabel.isHidden = hint.isEmpty
        hintLabel.preferredMaxLayoutWidth = 460
        if let action {
            actionButton.title = action.title
            actionButton.isHidden = false
            self.action = action.run
        } else {
            actionButton.isHidden = true
            self.action = nil
        }
    }

    @objc private func act() { action?() }
}
