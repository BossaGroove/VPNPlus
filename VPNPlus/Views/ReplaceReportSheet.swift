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

/// What replacing a profile's file did — **a report, not a confirmation**
/// (M5.10, the ReplaceFile artboard, 520 wide).
///
/// Three things, in the artboard's order: *What changed in the file*, as
/// before → after rows for the facts the app tracks; *Your settings, kept*,
/// because D132 keeps every override and this is where the user learns that;
/// and, when the file changed a row the user had overridden, a question —
/// **Keep mine · Use the file's** — which is the first surface where "called
/// out, not resolved on the user's behalf" is a choice the user actually
/// makes rather than a sentence they read.
@MainActor
final class ReplaceReportSheet: NSViewController {
    struct Change {
        let label: String
        let before: String
        let after: String
    }

    /// A contradiction. With `resolve` it offers the two links; without, it
    /// is a statement the file has already settled.
    struct Question {
        let text: NSAttributedString
        let resolve: (@MainActor () -> Void)?
    }

    static let width: CGFloat = 520
    private static let inset: CGFloat = Space.xl
    private static let labelColumn: CGFloat = 132
    private static let sectionGap: CGFloat = 20
    private static var contentWidth: CGFloat { width - 2 * inset }

    private let heading: String
    private let summary: String
    /// `nil` when there is no old record to compare with, which is different
    /// from a comparison that found nothing.
    private let changes: [Change]?
    private let kept: [String]
    private let questions: [Question]

    init(title: String, summary: String, changes: [Change]?, kept: [String], questions: [Question]) {
        self.heading = title
        self.summary = summary
        self.changes = changes
        self.kept = kept
        self.questions = questions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Space.s
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let title = text(heading, font: Type.messageTitle, color: Palette.textPrimary)
        column.addArrangedSubview(title)
        let lede = text(summary, font: Type.detail, color: Palette.textSecondary)
        column.addArrangedSubview(lede)

        // What changed in the file.
        let changedLabel = section(String(localized: "What changed in the file"))
        column.addArrangedSubview(changedLabel)
        column.setCustomSpacing(Self.sectionGap, after: lede)
        var last: NSView = changedLabel
        switch changes {
        case nil:
            let none = text(
                String(localized: "VPN Plus has no record of the old file to compare with."),
                font: Type.detail, color: Palette.textSecondary)
            column.addArrangedSubview(none)
            last = none
        case .some(let rows) where rows.isEmpty:
            let none = text(
                String(
                    localized: """
                        The server and sign-in details are the same as before. Certificates, keys \
                        and options aren't compared.
                        """),
                font: Type.detail, color: Palette.textSecondary)
            column.addArrangedSubview(none)
            last = none
        case .some(let rows):
            for change in rows {
                let row = self.row(change)
                column.addArrangedSubview(row)
                column.setCustomSpacing(Space.m, after: last)
                last = row
            }
        }

        // Your settings, kept.
        if !kept.isEmpty {
            let keptLabel = section(String(localized: "Your settings, kept"))
            column.addArrangedSubview(keptLabel)
            column.setCustomSpacing(Self.sectionGap, after: last)
            let list = NSStackView(
                views: kept.map { text("· \($0)", font: Type.detail, color: Palette.textSecondary) })
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = Space.xs
            list.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(list)
            last = list
        }

        // The questions.
        for question in questions {
            let box = QuestionBox(question, width: Self.contentWidth)
            column.addArrangedSubview(box)
            column.setCustomSpacing(Space.l, after: last)
            last = box
        }

        // Done, at the trailing edge.
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, done])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        column.addArrangedSubview(footer)
        column.setCustomSpacing(Space.xl, after: last)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.inset),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func section(_ name: String) -> NSTextField {
        text(name, font: Type.sectionLabel, color: Palette.textSecondary)
    }

    private func text(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        return field
    }

    /// Label · ~~before~~ → **after**, from the artboard.
    private func row(_ change: Change) -> NSView {
        let label = NSTextField(labelWithString: change.label)
        label.font = Type.detail
        label.textColor = Palette.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumn).isActive = true

        let before = NSTextField(
            labelWithAttributedString: NSAttributedString(
                string: change.before,
                attributes: [
                    .font: Type.detail,
                    .foregroundColor: Palette.textSecondary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Palette.textSecondary,
                ]))
        before.lineBreakMode = .byTruncatingMiddle
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = Type.detail
        arrow.textColor = Palette.textSecondary
        let after = NSTextField(labelWithString: change.after)
        after.font = Type.detailEmphasis
        after.textColor = Palette.textSecondary
        after.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [label, before, arrow, after])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Space.s + 2
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
        return row
    }

    @objc private func finish() { dismiss(nil) }

    override func cancelOperation(_ sender: Any?) { dismiss(nil) }
}

/// The artboard's grey box: a sentence, then **Keep mine · Use the file's**.
/// Answering replaces the links with what was done, so the box still reads
/// correctly after the click and nothing can be clicked twice.
@MainActor
private final class QuestionBox: NSView {
    private let question: ReplaceReportSheet.Question
    private let links = NSStackView()
    private let answer = NSTextField(labelWithString: "")
    private static let padding = NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13)

    init(_ question: ReplaceReportSheet.Question, width: CGFloat) {
        self.question = question
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true

        let inner = width - Self.padding.left - Self.padding.right
        let text = NSTextField(labelWithAttributedString: question.text)
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = inner
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: inner).isActive = true

        let column = NSStackView(views: [text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Space.xs
        column.translatesAutoresizingMaskIntoConstraints = false

        if question.resolve != nil {
            let keep = link(String(localized: "Keep mine"), action: #selector(keepMine))
            let dot = NSTextField(labelWithString: "·")
            dot.font = Type.detail
            dot.textColor = Palette.textSecondary
            let use = link(String(localized: "Use the file's"), action: #selector(useTheFiles))
            for view in [keep, dot, use] { links.addArrangedSubview(view) }
            links.orientation = .horizontal
            links.alignment = .firstBaseline
            links.spacing = Space.xs
            links.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(links)

            answer.font = Type.detail
            answer.textColor = Palette.textSecondary
            answer.isHidden = true
            column.addArrangedSubview(answer)
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding.left),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding.right),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding.top),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateLayer() {
        layer?.backgroundColor = Palette.surfaceWindow.cgColor
        layer?.borderColor = Palette.border.cgColor
    }

    private func link(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = Type.detail
        button.contentTintColor = Palette.accent
        button.setButtonType(.momentaryChange)
        return button
    }

    @objc private func keepMine() {
        settle(String(localized: "Keeping yours."))
    }

    @objc private func useTheFiles() {
        question.resolve?()
        settle(String(localized: "Using the file's."))
    }

    private func settle(_ outcome: String) {
        links.isHidden = true
        answer.stringValue = outcome
        answer.isHidden = false
    }
}
