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

/// The Diagnostics sheet (A14, the Diagnostics artboard, 660 × 700).
///
/// **A sheet, not a window** (D136): investigation, not operation — dismissing
/// it returns to exactly where you were, with the failure still on screen
/// behind it. Reached from *Show details* on a failure and from
/// `View ▸ Show Diagnostics` with no failure at all (D141): a log you can only
/// reach by failing is a log you cannot check.
///
/// Four parts, the artboard's: the sentence this is about; **What changed**
/// as LAST GOOD / NOW with all five rows, so an unchanged environment is a
/// fact rather than an absence; the log, searchable and filterable, as
/// **per-attempt sections** of timestamped phrases in our own words (D138,
/// D139); and *Copy diagnostics · Export…* with the footer that says what was
/// removed (D87).
///
/// **The log is a text view.** A2's requirements — wrap at the script's break
/// opportunities and never inside a token, continuation lines indented, no
/// horizontal scroll, selectable and copyable by line (D137) — are what the
/// text system does when it is left alone; a table would have to be taught
/// each of them.
@MainActor
final class DiagnosticsSheet: NSViewController {
    static let width: CGFloat = 660
    private static let height: CGFloat = 700
    private static let inset: CGFloat = 22
    private static var contentWidth: CGFloat { width - 2 * inset }
    /// The artboard's two fixed columns.
    private static let labelColumn: CGFloat = 190
    private static let lastGoodColumn: CGFloat = 150
    /// The artboard's time column, and where the phrase starts.
    private static let timeColumn: CGFloat = 76

    private let profileName: String
    private let record: DiagnosticsLog
    private let comparison: NetworkComparison
    private let message: FailureMessage?

    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let log = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeight: NSLayoutConstraint?

    init(
        profileName: String, record: DiagnosticsLog, comparison: NetworkComparison,
        message: FailureMessage?
    ) {
        self.profileName = profileName
        self.record = record
        self.comparison = comparison
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        let column = NSStackView(views: [header(), whatChanged(), controls(), logView(), footer()])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        fit()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        fit()
    }

    /// The artboard's 700, or the room there is (D279): the log takes the
    /// difference, because it is the one part that scrolls.
    private func fit() {
        let window = view.window
        let parent = window?.sheetParent
        let screen = window?.screen ?? parent?.screen ?? NSScreen.main
        let bottom = screen?.visibleFrame.minY ?? 0
        let top = parent.map { $0.convertToScreen($0.contentLayoutRect).maxY } ?? (screen?.visibleFrame.maxY ?? Self.height)
        let room = top - bottom - Space.l
        let height = min(Self.height, max(420, room))
        view.layoutSubtreeIfNeeded()
        let fixed = view.fittingSize.height - (logHeight?.constant ?? 0)
        logHeight?.constant = max(120, height - fixed)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: height)
    }

    /// The artboard's 56 pt header: the sentence this is about, and when.
    private func header() -> NSView {
        let title = label(
            message?.title ?? String(localized: "Diagnostics for \(profileName)"),
            font: Type.sheetTitle, color: Palette.textPrimary)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = label(when(), font: Type.caption, color: Palette.textSecondary)
        let lines = NSStackView(views: [title, subtitle])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 3
        return band(lines, height: 56, rule: true)
    }

    /// *"Today at 14:32 · attempt 2"*, or the honest alternative.
    private func when() -> String {
        guard let latest = record.latest else {
            return String(localized: "No connection attempts recorded yet")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        let time = formatter.string(from: latest.startedAt)
        return String(localized: "\(time) · attempt \(latest.number)")
    }

    /// LAST GOOD / NOW, all five rows (D89; A14 §1).
    private func whatChanged() -> NSView {
        let heading = label(String(localized: "What changed"), font: Type.sectionLabel, color: Palette.textPrimary)
        let columns = NSStackView(views: [
            spacer(width: Self.labelColumn),
            label(String(localized: "LAST GOOD").uppercased(), font: Type.hint, color: Palette.textSecondary, width: Self.lastGoodColumn),
            label(String(localized: "NOW").uppercased(), font: Type.hint, color: Palette.textSecondary),
        ])
        columns.orientation = .horizontal
        columns.spacing = 10
        columns.alignment = .firstBaseline

        let table = NSStackView(views: [heading, columns])
        table.orientation = .vertical
        table.alignment = .leading
        table.spacing = Space.s
        for row in DiagnosticsCopy.comparison(comparison) {
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Palette.border.cgColor
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            rule.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            let cells = NSStackView(views: [
                label(row.label, font: Type.detail, color: Palette.textSecondary, width: Self.labelColumn),
                label(row.lastGood, font: Type.detail, color: Palette.textSecondary, width: Self.lastGoodColumn),
                label(
                    row.now,
                    // Changed rows are the point, so they are the ones in
                    // full weight and full colour (the artboard's bold).
                    font: row.changed ? Type.detailEmphasis : Type.detail,
                    color: row.changed ? Palette.textPrimary : Palette.textSecondary),
            ])
            cells.orientation = .horizontal
            cells.spacing = 10
            cells.alignment = .firstBaseline
            table.addArrangedSubview(rule)
            table.setCustomSpacing(5, after: rule)
            table.addArrangedSubview(cells)
            table.setCustomSpacing(5, after: cells)
        }
        let padded = NSStackView(views: [table])
        padded.edgeInsets = NSEdgeInsets(top: Space.l, left: 0, bottom: 14, right: 0)
        return band(padded, height: nil, rule: true)
    }

    /// Search and the `All ▾` filter.
    private func controls() -> NSView {
        search.placeholderString = String(localized: "Search")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 180).isActive = true
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        filter.addItems(withTitles: [String(localized: "All"), String(localized: "Problems only")])
        filter.target = self
        filter.action = #selector(filterChanged)
        let row = NSStackView(views: [search, filter])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: Space.m, left: 0, bottom: Space.m, right: 0)
        return band(row, height: nil, rule: false)
    }

    /// The log, in the artboard's grey box, taking whatever height is left.
    private func logView() -> NSView {
        log.isEditable = false
        log.isSelectable = true
        log.drawsBackground = false
        log.isRichText = false
        log.isHorizontallyResizable = false
        log.isVerticallyResizable = true
        log.textContainer?.widthTracksTextView = true
        log.textContainerInset = NSSize(width: 14, height: 10)
        log.autoresizingMask = [.width]
        log.minSize = .zero
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.hasHorizontalScroller = false
        logScroll.autohidesScrollers = true
        logScroll.borderType = .noBorder
        logScroll.drawsBackground = false
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Palette.border.cgColor
        box.layer?.backgroundColor = Palette.surfaceWindow.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(logScroll)
        let height = box.heightAnchor.constraint(equalToConstant: 300)
        logHeight = height
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            height,
            logScroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            logScroll.topAnchor.constraint(equalTo: box.topAnchor),
            logScroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return band(box, height: nil, rule: false)
    }

    /// *Copy diagnostics · Export…*, the promise, and Done.
    private func footer() -> NSView {
        let copy = link(String(localized: "Copy diagnostics"), action: #selector(copyDiagnostics))
        let export = link(String(localized: "Export…"), action: #selector(exportDiagnostics))
        let promise = label(
            String(localized: "Passwords and keys are removed"), font: Type.hint,
            color: Palette.textSecondary)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let row = NSStackView(views: [copy, export, promise, spacer, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return band(row, height: 62, rule: false)
    }

    // MARK: - The log's text

    private var problemsOnly: Bool { filter.indexOfSelectedItem == 1 }

    /// Rebuilds the text from the record, the filter and the search.
    private func render() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let text = NSMutableAttributedString()
        let attempts = record.forScreen(problemsOnly: problemsOnly)

        let headerStyle = NSMutableParagraphStyle()
        headerStyle.alignment = .center
        headerStyle.paragraphSpacingBefore = Space.m
        headerStyle.paragraphSpacing = 6
        let entryStyle = NSMutableParagraphStyle()
        // The phrase starts at the time column's edge, and a wrapped phrase
        // continues under itself rather than under the time (D137).
        entryStyle.tabStops = [NSTextTab(textAlignment: .left, location: Self.timeColumn)]
        entryStyle.headIndent = Self.timeColumn
        entryStyle.paragraphSpacing = 3
        entryStyle.lineBreakMode = .byWordWrapping

        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"

        var shown = 0
        for attempt in attempts {
            let entries = attempt.entries.filter { entry in
                guard let phrase = DiagnosticsCopy.phrase(entry) else { return false }
                return query.isEmpty || phrase.localizedCaseInsensitiveContains(query)
            }
            if !entries.isEmpty || query.isEmpty {
                text.append(
                    NSAttributedString(
                        string: DiagnosticsCopy.header(attempt) + "\n",
                        attributes: [
                            .font: Type.sectionLabel, .foregroundColor: Palette.textSecondary,
                            .paragraphStyle: headerStyle,
                        ]))
            }
            for entry in entries {
                guard let phrase = DiagnosticsCopy.phrase(entry) else { continue }
                let line = NSMutableAttributedString(
                    string: "\(time.string(from: entry.at))\t",
                    attributes: [
                        .font: Type.mono, .foregroundColor: Palette.textSecondary,
                        .paragraphStyle: entryStyle,
                    ])
                line.append(
                    NSAttributedString(
                        string: phrase + "\n",
                        attributes: [
                            .font: Type.mono,
                            // A problem in the state colour, as the artboard
                            // has it — and never the only carrier: the words
                            // say it too (D94).
                            .foregroundColor: entry.kind.isProblem ? Palette.stateFailed : Palette.textPrimary,
                            .paragraphStyle: entryStyle,
                        ]))
                text.append(line)
                shown += 1
            }
        }
        if shown == 0 {
            let empty: String =
                record.attempts.isEmpty
                ? String(localized: "Nothing has been recorded for this profile yet. Connect once and the attempt appears here.")
                : (query.isEmpty
                    ? String(localized: "No problems in what is recorded.")
                    : String(localized: "Nothing matches “\(query)”."))
            text.append(
                NSAttributedString(
                    string: empty,
                    attributes: [.font: Type.body, .foregroundColor: Palette.textSecondary]))
        }
        log.textStorage?.setAttributedString(text)
        log.scrollToBeginningOfDocument(nil)
    }

    // MARK: - Actions

    @objc private func searchChanged() { render() }
    @objc private func filterChanged() { render() }
    @objc private func finish() { dismiss(nil) }
    override func cancelOperation(_ sender: Any?) { dismiss(nil) }

    private var exportText: String {
        DiagnosticsExport.text(
            profileName: profileName, record: record, comparison: comparison, message: message)
    }

    @objc private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exportText, forType: .string)
    }

    @objc private func exportDiagnostics() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsExport.filename(profileName: profileName)
        panel.canCreateDirectories = true
        let text = exportText
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Pieces

    /// A full-width band with the artboard's 22 pt side insets, and a rule
    /// under it where the artboard draws one.
    private func band(_ content: NSView, height: CGFloat?, rule: Bool) -> NSView {
        let band = NSView()
        band.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(content)
        var constraints = [
            band.widthAnchor.constraint(equalToConstant: Self.width),
            content.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -Self.inset),
            content.centerYAnchor.constraint(equalTo: band.centerYAnchor),
        ]
        if let height {
            constraints.append(band.heightAnchor.constraint(equalToConstant: height))
        } else {
            constraints += [
                content.topAnchor.constraint(equalTo: band.topAnchor),
                content.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            ]
        }
        if rule {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Palette.border.cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(line)
            constraints += [
                line.heightAnchor.constraint(equalToConstant: 1),
                line.leadingAnchor.constraint(equalTo: band.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: band.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return band
    }

    private func label(_ text: String, font: NSFont, color: NSColor, width: CGFloat? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func link(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = Type.detail
        button.contentTintColor = Palette.accent
        button.setButtonType(.momentaryChange)
        return button
    }
}
