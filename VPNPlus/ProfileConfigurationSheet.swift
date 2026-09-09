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

/// A profile's settings, as A13a designs them: six sections, every row saying
/// where its value came from, and a Revert that reverts **that row**.
///
/// Three rules it must honour whatever it looks like. The commit button says
/// **Done**, never Save, and it never connects (D131). This surface is never on
/// the path to connecting (2.13). And it does not rebuild itself while it is
/// being typed into — see `refresh()`.
@MainActor
final class ProfileConfigurationSheet: NSViewController {
    /// What the sheet decided.
    ///
    /// The password is here and deliberately **not** in `overrides`: an
    /// overrides record is written to preferences, and a password never is
    /// (D127, D190). It travels to the extension's keychain by the same route
    /// the sign-in sheet uses.
    struct Outcome {
        var overrides: Overrides
        var username = ""
        var password = ""
        var certificate: CertificateChange = .unchanged
    }

    enum CertificateChange: Equatable {
        case unchanged
        case chosen(path: String, certificate: Data, privateKey: Data)
        case cleared
    }

    /// Which row a Revert belongs to — the model's vocabulary, not a second
    /// one beside it. What reverting *means* for each is `Overrides.reverting`,
    /// which is where it can be tested.
    private typealias Field = Overrides.Setting

    private let profile: Profile
    private let descriptor: ProfileDescriptor
    private let passwordAlreadySaved: Bool
    private var overrides: Overrides
    private var certificate: CertificateChange = .unchanged

    private let onDone: (Outcome) -> Void
    private let onReplaceFile: () -> Void
    private let onReveal: () -> Void

    private var settings: ProfileSettings {
        ProfileSettings.compose(descriptor, with: overrides, filename: profile.origin.filename)
    }

    /// The name the profile has when the user has not renamed it. Comparing
    /// against this is what keeps "typing the name already shown" from being
    /// stored as an override.
    private var defaultTitle: String {
        descriptor.preferredTitle(filename: profile.origin.filename)
    }

    // MARK: - Controls

    private let titleField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let transportPicker = NSPopUpButton()
    private let serverPicker = NSPopUpButton()
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let savePasswordSwitch = NSSwitch()
    private let reconnectSwitch = NSSwitch()
    private let openAtLaunchSwitch = NSSwitch()

    private let rows = NSStackView()
    /// The caption and the Revert of each row that has provenance, kept so
    /// they can be **updated in place**.
    private var captions: [Field: NSTextField] = [:]
    /// The caption's own container, indented to the field column. Hiding
    /// *this* is what closes the row up: hiding only the label inside it would
    /// leave the indent behind as a blank line.
    private var captionRows: [Field: NSView] = [:]
    private var reverts: [Field: NSButton] = [:]
    /// The editable field of each row, and the placeholder it has when the
    /// profile does supply the value — so "not in this profile" can be put in
    /// the field and taken back out again.
    private var fields: [Field: NSTextField] = [:]
    private var placeholders: [Field: String] = [:]
    /// The two ways a value's trailing edge can be pinned, of which exactly
    /// one is active at a time — see `note`.
    private var besideRevert: [Field: NSLayoutConstraint] = [:]
    private var atTrailingEdge: [Field: NSLayoutConstraint] = [:]
    private let certificateRow = NSStackView()
    private let certificateCaption = NSTextField(labelWithString: "")
    private let certificateButton = NSButton(title: "", target: nil, action: nil)

    /// One content width for the whole sheet: label column, control column, and
    /// room for a Revert. Without it a wrapping caption asks for its full
    /// single-line width and the sheet grows to suit (D243).
    /// **The sibling app's form**, at the owner's direction: labels
    /// right-aligned in a fixed column with a colon, fields filling the rest,
    /// laid out by `NSGridView`. A horizontal row is one line where a stacked
    /// one is two, which is what makes this sheet shorter — and the two apps
    /// are meant to work the same way.
    ///
    /// 560 rather than the artboard's 520 because the layout needs it: a
    /// label column plus a field does not fit in 476 pt of content, which is
    /// exactly why the artboard stacked them.
    private static let sheetWidth: CGFloat = 560
    private static let margin: CGFloat = 22
    /// Wider than the sibling's 80: our longest label is "Certificate:", and
    /// German is longer still (A18).
    private static let labelColumn: CGFloat = 96
    private static let contentWidth: CGFloat = sheetWidth - 2 * margin
    private static let revertWidth: CGFloat = 72
    private static let scrollerGutter: CGFloat = 16

    /// How tall the rows may be before they scroll. Set from the screen,
    /// because a fixed cap is either too small on a large display or too
    /// large on the smallest one this app allows (D249).
    private var cap: CGFloat = 520
    /// The scroll view's height — **a constant this sheet sets**, never a
    /// relation it hopes will win. See `fitSheet()`.
    private lazy var scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 520)
    /// Header, scroll view and footer, whose fitting size is the sheet's. See
    /// `fitSheet()` for why the root view's own cannot be asked.
    private var chrome: NSStackView?
    private let scroll = NSScrollView()

    init(
        profile: Profile,
        descriptor: ProfileDescriptor,
        overrides: Overrides,
        passwordAlreadySaved: Bool,
        onDone: @escaping (Outcome) -> Void,
        onReplaceFile: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) {
        self.profile = profile
        self.descriptor = descriptor
        self.overrides = overrides
        self.passwordAlreadySaved = passwordAlreadySaved
        self.onDone = onDone
        self.onReplaceFile = onReplaceFile
        self.onReveal = onReveal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Layout

    override func loadView() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Space.s
        rows.translatesAutoresizingMaskIntoConstraints = false
        // The rows are never taller than their content. Whatever is taller
        // around them — a scroll view mid-resize, a clip view — leaves empty
        // space below the last card rather than stretching the first one
        // (measured: the Name card at 212 pt, 2026-09-09).
        rows.setHuggingPriority(.defaultHigh, for: .vertical)

        build()
        refresh()

        // A complete configuration surface is taller than the smallest window
        // this app allows (620 × 440), so the rows scroll and the footer does
        // not: the two buttons that end the sheet are never scrolled away.
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // Legacy rather than overlay, because an overlay scroller appears
        // when you scroll and is no use to somebody who cannot see that there
        // is anything to scroll to. **Auto-hiding**, though: with the cap
        // taken from the screen the sheet usually does not scroll at all, and
        // a scroller standing there with nothing to scroll is its own small
        // lie.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header(), scroll, footer()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.l
        stack.edgeInsets = NSEdgeInsets(
            top: Space.xl, left: Space.xl, bottom: Space.xl, right: Space.xl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome = stack

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.contentWidth + 2 * Space.xl, height: 600))
        container.addSubview(stack)
        // The scroll view's height was once a relation — equal to the rows at
        // low priority, under a cap. At `defaultHigh` that relation *won* and
        // crushed 700 pt of content into 520 (D247); at `defaultLow` it lost
        // to something else: after the transparency section folded, the
        // scroll view kept its old height, the rows were stretched to fill it
        // and `fittingSize` read the stale height back. So it is a constant
        // now, computed from the rows in `fitSheet()`.
        NSLayoutConstraint.activate([
            rows.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            // Room for the scroller beside the rows rather than over them.
            scroll.widthAnchor.constraint(
                equalTo: rows.widthAnchor, constant: Self.scrollerGutter),
            scrollHeight,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier(AccessibilityID.configurationSheet)
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        recomputeCap()
        // **And then say how big that makes the sheet.** Without this AppKit
        // keeps the height the root view was constructed with, the stack is
        // stretched to fill it, and the footer floats above a band of empty
        // sheet while the last row is clipped behind it.
        fitSheet()
        // A sheet whose rows do not all fit opens **at the top**. Re-laying it
        // out during presentation left the clip view part-way down, so the
        // sheet opened with its first section already scrolled away.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        #if DEBUG
            dumpRows()
        #endif
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The sheet is on screen now, so its position is known for certain;
        // if `viewWillAppear` had to guess, this corrects it before the user
        // has read a line.
        recomputeCap()
        fitSheet()
    }

    /// How tall the rows may be before they scroll: **the room below the
    /// sheet's top edge**, less this sheet's own chrome.
    ///
    /// The first version subtracted the chrome from the *whole* screen and
    /// let an unfolded sheet run past the bottom of the owner's display,
    /// footer and all (2026-09-09). A sheet hangs from the top of its parent's
    /// content area, so that is where the room starts — and D249 still holds:
    /// the parent window's *height* is not the limit, the screen's bottom edge
    /// is. The chrome is measured, not estimated: whatever the header, footer,
    /// insets and gaps come to with the scroll view taken out.
    private func recomputeCap() {
        let window = view.window
        let parent = window?.sheetParent
        let screen = window?.screen ?? parent?.screen ?? NSScreen.main
        let bottom = screen?.visibleFrame.minY ?? 0
        let top: CGFloat
        if let parent {
            top = parent.convertToScreen(parent.contentLayoutRect).maxY
        } else {
            top = screen?.visibleFrame.maxY ?? 640
        }
        let chromeHeight = (chrome?.fittingSize.height ?? 0) - scrollHeight.constant
        // A little air under the sheet, so its shadow is not the screen edge.
        let room = top - bottom - Space.l
        cap = max(240, room - chromeHeight)
    }

    #if DEBUG
        /// **Development only: fold the transparency section the way a click
        /// would, then measure.** The owner's steps — open expanded, collapse
        /// — left the Name card 400 pt tall (2026-09-09); this reproduces it
        /// without a mouse and says which frame grew, which the dump of
        /// *fitting* sizes alone cannot.
        func debugToggleContents() {
            headingClicked()
            let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "sheet")
            let card = rows.views.first { $0 is SettingsCard }
            log.notice(
                "after toggle: chrome fitting \(self.chrome?.fittingSize.height ?? -1, privacy: .public) view \(self.view.frame.height, privacy: .public) scroll \(self.scroll.frame.height, privacy: .public) rows \(self.rows.frame.height, privacy: .public) (fitting \(self.rows.fittingSize.height, privacy: .public)) first card frame \(card?.frame.height ?? -1, privacy: .public) (fitting \(card?.fittingSize.height ?? -1, privacy: .public)) expanded=\(Self.contentsExpanded, privacy: .public)"
            )
            dumpRows()
        }

        /// **Development only.** Every row, with its height.
        ///
        /// A tall sheet does not fit in one screenshot, and "I could not see
        /// it" is not evidence that a section is missing — nor that it is
        /// there. This says which rows exist and how tall each one is, which
        /// is how the first build's crushed headings were caught: they were
        /// present, and 0 pt high.
        private func dumpRows() {
            let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "sheet")
            // The three switches, because **a capture cannot be trusted for
            // this**: macOS draws accent controls unemphasised in a window
            // that is not key, so a switch that is on renders with a grey
            // track and reads as off in a screenshot. Measured, not looked at.
            log.notice(
                "switches: keychain=\(self.savePasswordSwitch.state == .on, privacy: .public) open=\(self.openAtLaunchSwitch.state == .on, privacy: .public) reconnect=\(self.reconnectSwitch.state == .on, privacy: .public)"
            )
            let screenHeight = self.view.window?.screen?.visibleFrame.height ?? -1
            log.notice(
                "sheet \(self.preferredContentSize.width, privacy: .public)×\(self.preferredContentSize.height, privacy: .public), \(self.rows.views.count, privacy: .public) rows, content \(self.rows.fittingSize.height, privacy: .public) pt, cap \(self.cap, privacy: .public), scroll \(self.scrollHeight.constant, privacy: .public), screen visible \(screenHeight, privacy: .public)"
            )
            for card in rows.views.compactMap({ $0 as? SettingsCard }) {
                log.notice(
                    "  card \(Int(card.fittingSize.height), privacy: .public) pt: \(card.rowHeights, privacy: .public)"
                )
            }
            for row in rows.views {
                let text =
                    (row as? NSTextField)?.stringValue
                    ?? (row as? NSButton)?.title
                    ?? Self.describe(row)
                log.notice(
                    "  \(Int(row.fittingSize.height), privacy: .public) pt  \(text, privacy: .public)"
                )
            }
        }

        private static func describe(_ view: NSView) -> String {
            guard let stack = view as? NSStackView else { return "\(type(of: view))" }
            return stack.views.compactMap {
                ($0 as? NSTextField)?.stringValue.isEmpty == false
                    ? ($0 as? NSTextField)?.stringValue
                    : ($0 as? NSButton)?.title ?? ($0 as? NSPopUpButton)?.titleOfSelectedItem
            }.joined(separator: " | ")
        }
    #endif

    /// **The sheet names the profile it is about**, which it did not — the
    /// Name field was the only clue, and a field is a thing you edit rather
    /// than a thing that tells you where you are. A fixed bar with a rule
    /// under it, from the artboard, so it does not scroll away from the
    /// content it names.
    private func header() -> NSView {
        let heading = NSTextField(labelWithString: defaultTitle)
        heading.font = Type.sheetTitle
        heading.textColor = Palette.textPrimary
        heading.lineBreakMode = .byTruncatingMiddle
        sheetTitle = heading

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Palette.border.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let bar = NSStackView(views: [heading, rule])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = Space.m
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        rule.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        return bar
    }

    /// A13a's footer. **Replace profile file…** is where overrides earn their
    /// keep (D125): an employer reissues the profile and it costs one file
    /// picker rather than a retyped configuration.
    private func footer() -> NSView {
        // **Links, not buttons.** The artboard gives the two left-hand actions
        // accent-coloured text and no bezel, which is right: four bezelled
        // buttons in a row made "Replace Profile File…" look like a peer of
        // Done, and one of them ends the sheet while the other rewrites the
        // profile.
        let replace = link(
            String(localized: "Replace profile file…"), action: #selector(replaceFile))
        let reveal = link(String(localized: "Reveal in Finder"), action: #selector(self.reveal))
        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(self.cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done))
        done.setAccessibilityIdentifier(AccessibilityID.configurationDone)
        done.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [replace, reveal, spacer, cancel, done])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.m
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Palette.border.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let bar = NSStackView(views: [rule, row])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = Space.m
        bar.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return bar
    }

    private func link(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = Type.control
        button.contentTintColor = Palette.accent
        button.setButtonType(.momentaryChange)
        return button
    }

    // MARK: - The sections (A13a)

    /// Builds every row **once**. Nothing here runs again while the sheet is
    /// open, which is the whole answer to D223: removing a focused text field
    /// ends its editing session, which fires its action, which asked for the
    /// rebuild that was already running. A surface that never rebuilds cannot
    /// re-enter — so what an edit changes is a caption and a button's
    /// visibility, in `refresh()`.
    private func build() {
        section(String(localized: "Profile"))
        titleField.placeholderString = profile.origin.filename
        // **A deliberate departure from A13a §1**, which says the name is the
        // one field with no provenance "because we own it". We do not own it
        // outright: it is defaulted from the profile's own name, or from the
        // filename when the engine reports the server's address instead
        // (D215). So the row says where the current name came from, and a
        // rename can be undone — which is what D132's "a rename is an
        // override, not a rewrite" implies for this surface.
        add(String(localized: "Name"), titleField, field: .title)

        section(String(localized: "Server"))
        switch settings.server {
        case .single:
            add(String(localized: "Server"), hostField, field: .host)
            add(String(localized: "Port"), portField, field: .port)
            transportPicker.removeAllItems()
            for choice in Self.transports {
                transportPicker.addItem(withTitle: choice.label)
            }
            transportPicker.target = self
            transportPicker.action = #selector(transportChosen)
            add(String(localized: "Transport"), transportPicker, field: .transport)
        case .choice(let offered, _):
            // 2.16 / D130: several servers make this a choice, not a value.
            serverPicker.removeAllItems()
            for choice in offered { serverPicker.addItem(withTitle: choice.label) }
            serverPicker.target = self
            serverPicker.action = #selector(serverChosen)
            add(String(localized: "Server"), serverPicker, field: .selectedServer)
        }

        buildSignIn()
        buildCertificate()

        section(String(localized: "When connecting"))
        // The artboard's order, and it is the better one: what happens when
        // the app opens comes before what happens if a connection drops.
        addSwitch(
            String(localized: "Connect when VPN Plus opens"), openAtLaunchSwitch,
            action: #selector(openAtLaunchChanged))
        addSwitch(
            String(localized: "Reconnect automatically if the connection drops"), reconnectSwitch,
            action: #selector(reconnectChanged))

        buildContents()
        closeCard()
    }

    /// A13a §3: the section's shape comes from the profile, not from a fixed
    /// form (D128).
    private func buildSignIn() {
        section(String(localized: "Sign-in"))
        guard case .credentials(let username, let saving, let challenge) = settings.signIn else {
            rows.addView(
                caption(
                    String(
                        localized:
                            "This profile signs in on its own. No username or password needed.")),
                in: .top)
            return
        }

        switch username {
        case .fixed(let fixed):
            // 2.14: read-only, never an empty field.
            add(String(localized: "Username"), label(fixed), field: nil)
            rows.addView(caption(String(localized: "set by this profile")), in: .top)
        case .editable:
            add(String(localized: "Username"), usernameField, field: .username)
        }

        // A13a §3 asks for a Password beside the Username, and it was missing:
        // a "Remember the password" box sat on a surface with no password on
        // it. Nothing typed here is written to the profile store (D127) — it
        // goes to the extension's keychain.
        passwordField.placeholderString =
            passwordAlreadySaved
            ? String(localized: "Saved — type to replace it")
            : String(localized: "Asked at connect if left empty")
        add(String(localized: "Password"), passwordField, field: nil)

        switch saving {
        case .offered:
            // The artboard's shorter title. Its caption — "This profile
            // permits saving the password." — is **not** adopted: that is a
            // caption stating the default, which is exactly what D248
            // removed, and the owner kept D248.
            addSwitch(
                String(localized: "Remember in Keychain"), savePasswordSwitch,
                action: #selector(savePasswordChanged))
            savePasswordSwitch.setAccessibilityIdentifier(AccessibilityID.configurationRemember)
        case .forbiddenByProfile:
            // 2.15: absent, not shown and disabled — A13a's own anti-pattern.
            // A caption says why, because an unexplained absence is its own
            // confusion.
            rows.addView(
                caption(String(localized: "This profile doesn't allow saving the password.")),
                in: .top)
        }

        if let challenge {
            add(String(localized: "Also asks for"), label(challenge.prompt), field: nil)
            rows.addView(
                caption(String(localized: "Asked at connect, and never stored.")), in: .top)
        }
    }

    /// A13a §3a and D134. The capability, not OpenVPN Connect's plumbing: one
    /// certificate for this profile, no shared store, no tokens.
    private func buildCertificate() {
        section(String(localized: "Certificate"))
        if descriptor.credentials.contains(.privateKeyPassphrase) {
            rows.addView(
                caption(String(localized: "This profile's key needs a passphrase to unlock it.")),
                in: .top)
        }

        certificateButton.target = self
        certificateButton.action = #selector(chooseCertificate)
        // The label goes above, like every other row in the sheet — its
        // section heading says "Certificate" too, and the repetition is the
        // cheaper cost than a row that looks different from its neighbours.
        let name = NSTextField(labelWithString: String(localized: "Certificate"))
        name.textColor = Palette.textSecondary
        name.font = Type.fieldLabel

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        certificateRow.orientation = .horizontal
        certificateRow.spacing = Space.s
        certificateRow.alignment = .centerY
        certificateRow.translatesAutoresizingMaskIntoConstraints = false
        for subview in [certificateButton, spacer] {
            certificateRow.addView(subview, in: .trailing)
        }
        certificateRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let note = caption("", width: Self.contentWidth - Self.revertWidth - Space.s)
        captions[.certificate] = note
        let noteSpacer = NSView()
        noteSpacer.translatesAutoresizingMaskIntoConstraints = false
        noteSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let noteRow = NSStackView(views: [note, noteSpacer, revertButton(for: .certificate)])
        noteRow.orientation = .horizontal
        noteRow.alignment = .centerY
        noteRow.spacing = Space.s
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let group = openCard()
        group.addRow(String(localized: "Certificate"), certificateButton)
        captionRows[.certificate] = group.addFullWidthRow(noteRow)
        _ = (name, certificateRow)
    }

    /// A13a §6: what this profile contains, read-only. The transparency
    /// section, and what makes this a configuration surface rather than a form.
    ///
    /// **Data-channel offload is deliberately absent.** A13a listed it from
    /// `EvalConfig`, before M1 settled that we pass `dco = false` on macOS
    /// unconditionally — reporting the compatibility of a feature we never use
    /// would be noise dressed as transparency.
    private func buildContents() {
        // **Before the heading**, not after: the pending rows are still
        // waiting to become a grid, and a heading added first appears above
        // them — which put the disclosure between "When connecting" and its
        // own two switches.
        closeCard()
        // The heading is the control: a disclosure triangle beside it, and the
        // section folded away by default. It is read once — what the profile
        // contains does not change while you are looking at it — and this
        // surface was reported as too packed.
        // **`.disclosure` draws the triangle and throws the title away**, so
        // the heading is its own label beside it — and clickable, because a
        // heading that looks like the control has to behave like it.
        let triangle = NSButton(title: "", target: self, action: #selector(toggleContents))
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.onOff)
        triangle.state = Self.contentsExpanded ? .on : .off
        triangle.setAccessibilityLabel(String(localized: "What this profile contains"))
        triangle.setAccessibilityIdentifier(AccessibilityID.configurationContents)
        disclosure = triangle

        let heading = NSTextField(labelWithString: String(localized: "What this profile contains"))
        heading.font = Type.cardTitle
        heading.textColor = Palette.textPrimary
        heading.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(headingClicked)))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: Space.m).isActive = true
        rows.addView(spacer, in: .top)

        let headingRow = NSStackView(views: [triangle, heading])
        headingRow.orientation = .horizontal
        headingRow.spacing = Space.xs
        headingRow.alignment = .centerY
        rows.addView(headingRow, in: .top)

        let group = SettingsCard(width: Self.contentWidth)
        group.isHidden = !Self.contentsExpanded
        rows.addView(group, in: .top)
        rows.setCustomSpacing(Space.l, after: group)
        factCard = group
        contents = group

        let servers = max(descriptor.alternateServers.count, 1)
        fact(String(localized: "Servers"), "\(servers)")

        switch descriptor.caPresent {
        case true?:
            fact(
                String(localized: "Certificate authority"),
                String(localized: "Included in the profile"))
        case false?:
            fact(
                String(localized: "Certificate authority"),
                String(localized: "None — the server is checked another way"))
        case nil:
            // Imported before this was recorded. Saying so beats guessing
            // about a server's identity.
            fact(
                String(localized: "Certificate authority"),
                String(localized: "Not recorded at import"))
        }

        if descriptor.externalPKI == true {
            fact(String(localized: "Sign-in"), String(localized: "Certificate kept outside the file"))
        } else if descriptor.needsNothingFromTheUser {
            fact(String(localized: "Sign-in"), String(localized: "None — signs in by itself"))
        } else {
            fact(String(localized: "Sign-in"), String(localized: "Username and password required"))
        }

        fact(
            String(localized: "Private key passphrase"),
            descriptor.credentials.contains(.privateKeyPassphrase)
                ? String(localized: "Required") : String(localized: "Not required"))

        if !descriptor.waivedDirectives.isEmpty {
            // 2.8 / D187: this surface *is* the click behind the count, so the
            // list is here rather than one click further. The artboard has no
            // such row because the profile it draws has nothing waived.
            fact(
                String(localized: "Settings not used"),
                descriptor.waivedDirectives.joined(separator: ", "))
        }
    }

    /// One read-only fact: a label in a fixed column, its value beside it.
    /// A **table**, not a paragraph — four sentences run together were the
    /// densest thing on the sheet and the least readable.
    private func fact(_ name: String, _ value: String) {
        let detail = NSTextField(wrappingLabelWithString: value)
        detail.font = Type.control
        detail.textColor = Palette.textSecondary
        detail.alignment = .right
        detail.preferredMaxLayoutWidth = Self.contentWidth * 0.5
        factCard?.addRow(name, detail)
    }

    /// The transparency section's body, hidden until asked for. `NSStackView`
    /// detaches a hidden view, so the sheet closes up around it rather than
    /// leaving a gap.
    private var contents: NSView?
    private var disclosure: NSButton?
    /// The facts, in their own stack, so the disclosure folds the group
    /// rather than a single paragraph — §6 is five rows now, not one.
    private var factCard: SettingsCard?
    private var sheetTitle: NSTextField?

    @objc private func headingClicked() {
        guard let disclosure else { return }
        disclosure.state = disclosure.state == .on ? .off : .on
        toggleContents(disclosure)
    }

    @objc private func toggleContents(_ sender: NSButton) {
        Self.contentsExpanded = sender.state == .on
        contents?.isHidden = sender.state == .off
        // The sheet is as tall as its rows until they reach the cap, so
        // folding the section away has to be followed by saying so.
        fitSheet()
    }

    /// Makes the scroll view exactly as tall as its rows, up to the cap, and
    /// tells the window.
    ///
    /// **A constant we set, not a relation we hope wins.** The first version
    /// tied the scroll view's height to the rows' at low priority and read
    /// `view.fittingSize`. After the transparency section folded, the scroll
    /// view kept its old height, the rows were stretched to fill it, the Name
    /// card absorbed 178 pt of the slack, and `fittingSize` reported the old
    /// size back — measured on the owner's steps, 2026-09-09: rows 853 pt
    /// against 675 of content, first card 212 against 34. The same mechanism
    /// was behind the "Name card grew after clicking into it" report of
    /// 2026-09-08 that could not be reproduced at the time.
    private func fitSheet() {
        guard isViewLoaded else { return }
        rows.layoutSubtreeIfNeeded()
        let wanted = min(rows.fittingSize.height, cap)
        guard wanted != scrollHeight.constant || preferredContentSize.height == 0 else { return }
        scrollHeight.constant = wanted
        view.layoutSubtreeIfNeeded()
        // **The stack's fitting size, not the root view's.** Once this view is
        // a window's content view its frame is a required constraint, so
        // `view.fittingSize` answers with the window's current size — 999 pt
        // after a fold that left 821 pt of content (measured 2026-09-09). The
        // stack holds only the constraints between its own parts, and its
        // answer is the sum of them.
        preferredContentSize = chrome?.fittingSize ?? view.fittingSize
    }

    /// Whether the transparency section is open, remembered.
    ///
    /// **Not a setting** — it never appears in Settings and D25 is not in
    /// play. It is where a disclosure triangle was left, which every Mac app
    /// remembers, and remembering it is the difference between a section you
    /// folded away and one you have to fold away again every time.
    private static var contentsExpanded: Bool {
        get { Preferences.defaults.bool(forKey: "sheet.contents.expanded") }
        set { Preferences.defaults.set(newValue, forKey: "sheet.contents.expanded") }
    }

    // MARK: - Rows

    private static let transports: [(id: String, label: String)] = [
        ("udp", "UDP"), ("tcp", "TCP"), ("adaptive", String(localized: "Adaptive")),
    ]

    /// The card rows are being added to. One card per category, which is what
    /// separates the groups — a flat form put every category in one list and
    /// the switches read as starting halfway across it.
    private var card: SettingsCard?

    private func openCard() -> SettingsCard {
        if let card { return card }
        let fresh = SettingsCard(width: Self.contentWidth)
        rows.addView(fresh, in: .top)
        rows.setCustomSpacing(Space.l, after: fresh)
        card = fresh
        return fresh
    }

    private func closeCard() { card = nil }

    private func section(_ name: String) {
        closeCard()
        let heading = NSTextField(labelWithString: name)
        heading.font = Type.sectionLabel
        heading.textColor = Palette.textPrimary
        // Space above a heading and not below it, so a heading belongs to what
        // follows rather than floating between two groups.
        if !rows.views.isEmpty {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: Space.m).isActive = true
            rows.addView(spacer, in: .top)
        }
        rows.addView(heading, in: .top)
    }

    private func label(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.textColor = text.isEmpty ? Palette.textSecondary : Palette.textPrimary
        return field
    }

    private func caption(_ text: String, width: CGFloat = ProfileConfigurationSheet.contentWidth)
        -> NSTextField
    {
        let field = NSTextField(wrappingLabelWithString: text)
        // A step down in size, and **not** a step down in contrast: size,
        // the indent and the labels' right alignment already tell a hint from
        // a label, and dimming it further would buy nothing legibility does
        // not have to pay for (A18).
        field.textColor = Palette.textSecondary
        field.font = Type.hint
        // Both, and the constraint is the load-bearing one: on its own
        // `preferredMaxLayoutWidth` decides where text wraps when measuring
        // height, while the field still asks for its full single-line width
        // and the sheet obliges (D243).
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func revertButton(for field: Field) -> NSButton {
        let revert = NSButton(
            title: String(localized: "Revert"), target: self, action: #selector(revertRow(_:)))
        revert.bezelStyle = .accessoryBarAction
        revert.translatesAutoresizingMaskIntoConstraints = false
        revert.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.revertWidth).isActive = true
        revert.setAccessibilityLabel(String(localized: "Revert this setting"))
        // Present from the start and hidden when there is nothing to revert:
        // `NSStackView` detaches a hidden view, so the row closes up rather
        // than leaving a gap, and nothing has to be added or removed later.
        revert.isHidden = true
        reverts[field] = revert
        return revert
    }

    /// One row: a name, a control, its Revert, and a caption beneath saying
    /// where the value came from (D126). `field` is nil for a row with no
    /// provenance — a value the profile fixes, which nothing can revert.
    /// One row: **a label above its field**, with the caption beneath saying
    /// where the value came from (D126) and its Revert at the end of that same
    /// line. Three tiers of type, each doing one job — heading bold, label
    /// regular, caption a size down — which is the artboard's answer to the
    /// complaint that a label and a hint were indistinguishable (D248).
    private func add(_ name: String, _ control: NSView, field: Field?) {
        if let editable = control as? NSTextField {
            editable.font = Type.control
            // **One line, and pinned to it.** A programmatic `NSTextField`
            // wraps by default, and a wrapping field with no
            // `preferredMaxLayoutWidth` can report a height of many lines
            // once a field editor is installed in it — which is a card row
            // growing to hundreds of points the moment you click into it.
            // Every value here is a single line by nature.
            editable.usesSingleLineMode = true
            editable.cell?.wraps = false
            editable.cell?.isScrollable = true
            editable.lineBreakMode = .byTruncatingTail
            // **No bezel: a box inside a card row is a box inside a box.**
            // I argued the other way — that a borderless field reads as
            // read-only — and the owner looked at both and chose this: in a
            // grouped card the value is plain text at the trailing edge, and
            // only a control that *does* something (a popup, a button) carries
            // a bezel. Editing is still discoverable: clicking gives an
            // insertion point and a focus ring.
            editable.isBordered = false
            editable.drawsBackground = false
            editable.alignment = .right
            editable.textColor = Palette.textPrimary
            // **No focus ring either.** A ring round a value is the same box
            // by another name, and this row already has an edge — the card's.
            // Focus stays visible without it: tabbing into a field selects the
            // whole value, and clicking gives an insertion point.
            //
            // Flagged for A18's sweep (M8): a selection highlight is a weaker
            // keyboard cue than a ring, and if it does not survive that review
            // the answer is to tint the row, not to put the box back.
            editable.focusRingType = .none
            if editable.isEditable {
                editable.target = self
                editable.action = #selector(fieldChanged)
            }
            if let field {
                fields[field] = editable
                placeholders[field] = editable.placeholderString ?? ""
            }
        }
        let group = openCard()
        if field == .title {
            // The card whose height D278 is about, reachable by the UI tests.
            group.setAccessibilityElement(true)
            group.setAccessibilityRole(.group)
            group.setAccessibilityIdentifier(AccessibilityID.configurationNameCard)
        }
        guard let field else {
            group.addRow(name, control, fillsWidth: control is NSTextField)
            return
        }

        // **Revert sits in the row, to the right of the value.** It had a row
        // of its own with an "Original value: …" caption, which cost a whole
        // row per override and read as a half-height oddity between two proper
        // rows.
        //
        // I put it to the *left* first, so the value's trailing edge would
        // keep lining up with the rows that have no Revert. The owner looked
        // at it and moved it right, which is the better call: the action reads
        // after the thing it acts on, and a column of values is worth less
        // than that when only one row in a card ever has a button.
        //
        // The original value is not lost: it is the Revert button's tooltip
        // and its accessibility label, which is where it belongs — it exists
        // to make *that button* decidable, and nothing else needed it.
        let revert = revertButton(for: field)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        // **The inner control needs this too.** `addRow` clears it on whatever
        // it is handed — the holder — and nothing cleared it on the field
        // inside, so every constraint below was ignored and the field kept its
        // autoresized frame: 12 pt wide at the holder's origin, underneath the
        // button. Measured, not guessed: `value {{0, 0}, {12, 24}}`.
        control.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(revert)
        holder.addSubview(control)
        NSLayoutConstraint.activate([
            revert.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            // The button defines the row's height, not the field: the field is
            // shorter, and pinning its top and bottom would leave the 28 pt
            // button nowhere to go.
            revert.topAnchor.constraint(equalTo: holder.topAnchor),
            revert.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            control.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            control.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])

        // **A hidden view still occupies its space in the constraint
        // system** — `isHidden` is not `removeFromSuperview`, and only
        // `NSStackView` pretends otherwise. So the value's trailing edge is
        // pinned two ways and exactly one is active: to the button when there
        // is a button, and to the row's own edge when there is not. Without
        // this, every un-overridden row's value sat 80 pt short of the margin,
        // reserving room for a Revert nobody could see.
        besideRevert[field] = control.trailingAnchor.constraint(
            equalTo: revert.leadingAnchor, constant: -Space.s)
        atTrailingEdge[field] = control.trailingAnchor.constraint(
            equalTo: holder.trailingAnchor)
        // Only a text field fills the row — a popup hugs its content at the
        // trailing edge, which is what the artboard draws and what every
        // capture before this refactor showed. Routing every overridable row
        // through the holder had quietly stretched the Transport picker across
        // half the sheet.
        group.addRow(name, holder, fillsWidth: control is NSTextField)
    }

    /// A per-profile boolean, as the artboard draws it: the label and its
    /// explanation on the left, an **`NSSwitch`** on the right. Not a
    /// checkbox — three of these are the only switches in the app, and a
    /// switch is what macOS uses for a setting that takes effect as you set
    /// it rather than on OK.
    private func addSwitch(
        _ title: String, _ control: NSSwitch, caption note: String? = nil,
        action: Selector
    ) {
        control.target = self
        control.action = action
        let group = openCard()
        group.addRow(title, control)
        if let note {
            group.addFullWidthRow(
                caption(note, width: Self.contentWidth - 2 * SettingsCard.Metric.inset))
        }
    }

    /// Room reserved for the switch and its gap, so a label wraps before it
    /// reaches one rather than after.
    private static let switchColumn: CGFloat = 60

    // MARK: - Refreshing, without rebuilding

    /// Puts the composed settings into the controls, the captions and the
    /// Reverts. Safe to call from a field's own action, which is exactly what
    /// `build()` was not.
    private func refresh() {
        let current = settings
        set(titleField, to: current.title.value)
        sheetTitle?.stringValue = current.title.value
        set(usernameField, to: overrides.username ?? "")
        note(.title, current.title.provenance)

        switch current.server {
        case .single(let host, let port, let transport):
            set(hostField, to: host.value)
            set(portField, to: port.value)
            if let index = Self.transports.firstIndex(where: { transport.value.hasPrefix($0.id) }) {
                transportPicker.selectItem(at: index)
            }
            note(.host, host.provenance)
            note(.port, port.provenance)
            note(.transport, transport.provenance)
        case .choice(let offered, let selected):
            if let index = offered.firstIndex(where: { $0.host == selected }) {
                serverPicker.selectItem(at: index)
            }
            note(
                .selectedServer,
                overrides.selectedServer == nil ? .fromProfile : .overridden(profileValue: ""))
        }

        if case .credentials(let username, let saving, _) = current.signIn {
            if case .editable(let value) = username { note(.username, value.provenance) }
            if case .offered(let on) = saving { savePasswordSwitch.state = on ? .on : .off }
        }
        reconnectSwitch.state = current.reconnectAutomatically ? .on : .off
        openAtLaunchSwitch.state = current.connectWhenAppOpens ? .on : .off
        refreshCertificate(current)
        // A row that appeared or went changes the height the rows want.
        fitSheet()
    }

    private func refreshCertificate(_ current: ProfileSettings) {
        let chosenName: String?
        switch certificate {
        case .chosen(let path, _, _): chosenName = (path as NSString).lastPathComponent
        case .cleared: chosenName = nil
        case .unchanged:
            chosenName = current.certificatePath.map { ($0.value as NSString).lastPathComponent }
        }
        if let chosenName {
            certificateButton.title = String(localized: "Replace…")
            captions[.certificate]?.stringValue = String(
                localized: "Using \(chosenName) instead of the profile's own.")
        } else {
            certificateButton.title = String(localized: "Choose…")
            certificateButton.setAccessibilityLabel(
                String(localized: "Choose a certificate for this profile"))
            captions[.certificate]?.stringValue = String(
                localized: "One PEM file holding a certificate and its private key.")
        }
        reverts[.certificate]?.isHidden = chosenName == nil
    }

    /// Makes a row's provenance apparent — **and a caption is the last
    /// resort, not the mechanism** (D248).
    ///
    /// From the profile says nothing: it is true of almost every row, and
    /// stating it five times running buried the one row that was actually the
    /// user's. Not in the profile goes in the field, where an empty field's
    /// explanation belongs natively. Only an override gets a line, and it says
    /// the thing nothing else can — what Revert would put back.
    private func note(_ field: Field, _ provenance: Provenance) {
        var overridden = false
        var placeholder = placeholders[field] ?? ""

        switch provenance {
        case .fromProfile:
            break
        case .notInProfile:
            placeholder = String(localized: "not in this profile")
        case .overridden(let profileValue):
            overridden = true
            let original = display(profileValue, for: field)
            // Two strings, not one with the phrase passed in as the value: a
            // translator handed `%@` cannot know whether it will be a number
            // or a phrase, and German and Japanese need different grammar
            // around each (A18).
            let restores =
                original.isEmpty
                ? String(localized: "Revert to no value")
                : String(localized: "Revert to \(original)")
            reverts[field]?.toolTip = restores
            reverts[field]?.setAccessibilityLabel(restores)
        }

        captionRows[field]?.isHidden = !overridden
        reverts[field]?.isHidden = !overridden
        fields[field]?.placeholderString = placeholder
        // Exactly one, and in this order: deactivate before activating, or the
        // two fight for a frame and Auto Layout logs a conflict.
        (overridden ? atTrailingEdge[field] : besideRevert[field])?.isActive = false
        (overridden ? besideRevert[field] : atTrailingEdge[field])?.isActive = true
    }

    /// The configuration's value in the **control's** vocabulary. The profile
    /// says `tcp-client` where the picker says `TCP`, and a caption naming a
    /// setting the control never shows looks like it is describing something
    /// else entirely.
    private func display(_ profileValue: String, for field: Field) -> String {
        guard field == .transport, !profileValue.isEmpty else { return profileValue }
        return Self.transports.first { profileValue.hasPrefix($0.id) }?.label
            ?? profileValue.uppercased()
    }

    /// Writes a field only when it differs, so a refresh never moves the
    /// insertion point of the field being typed into.
    private func set(_ field: NSTextField, to value: String) {
        guard field.stringValue != value else { return }
        field.stringValue = value
    }

    // MARK: - Editing

    @objc private func fieldChanged() {
        readFields()
        refresh()
    }

    /// Reads what is typed into the overrides. **No layout of any kind**: a
    /// caller that is closing the sheet has no business rebuilding it (D223).
    private func readFields() {
        overrides.title = value(titleField, default: defaultTitle)
        overrides.username = value(usernameField, default: "")
        replaceServerOverride(
            host: hostField.stringValue.trimmingCharacters(in: .whitespaces),
            port: portField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// nil when the field agrees with the profile, so agreeing is not an
    /// override — the model's rule, honoured here.
    private func value(_ field: NSTextField, default profileValue: String) -> String? {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || typed == profileValue { return nil }
        return typed
    }

    /// Rewrites one part of the server override, keeping the rest, and drops
    /// the record entirely once it agrees with the profile again — so
    /// reverting the last overridden part leaves nothing behind.
    private func replaceServerOverride(
        host: String? = nil, port: String? = nil, transport: String? = nil
    ) {
        let base = overrides.server ?? descriptor.server
        let endpoint = ServerEndpoint(
            host: (host?.isEmpty == false ? host : nil) ?? base.host,
            port: (port?.isEmpty == false ? port : nil) ?? base.port,
            transport: transport ?? base.transport)
        // Agreeing with the configuration is not an override, so the record
        // goes rather than holding a copy of what the file already says.
        overrides.server = endpoint == descriptor.server ? nil : endpoint
    }

    @objc private func transportChosen() {
        let index = transportPicker.indexOfSelectedItem
        guard Self.transports.indices.contains(index) else { return }
        replaceServerOverride(transport: Self.transports[index].id)
        refresh()
    }

    @objc private func serverChosen() {
        guard case .choice(let offered, _) = settings.server,
            offered.indices.contains(serverPicker.indexOfSelectedItem)
        else { return }
        overrides.selectedServer = offered[serverPicker.indexOfSelectedItem].host
        refresh()
    }

    @objc private func savePasswordChanged() {
        overrides.savePassword = savePasswordSwitch.state == .on
        refresh()
    }

    @objc private func reconnectChanged() {
        overrides.reconnectAutomatically = reconnectSwitch.state == .on
        refresh()
    }

    @objc private func openAtLaunchChanged() {
        overrides.connectWhenAppOpens = openAtLaunchSwitch.state == .on
        refresh()
    }

    /// **Per-row Revert** (M3.6's note, A13a's provenance table). The blunt one
    /// this replaces cleared everything the sheet edits, because a button in a
    /// row had no way to say which row it was in.
    ///
    /// What each one *means* is the model's (`Overrides.reverting`); this puts
    /// the reverted value back in the control, because a text field holds its
    /// own copy of what was typed.
    @objc private func revertRow(_ sender: NSButton) {
        guard let field = reverts.first(where: { $0.value === sender })?.key else { return }
        overrides = overrides.reverting(field, to: descriptor)
        switch field {
        case .title: titleField.stringValue = defaultTitle
        case .host: hostField.stringValue = descriptor.server.host
        case .port: portField.stringValue = descriptor.server.port
        case .username: usernameField.stringValue = ""
        // The certificate is not an override until Done, so clearing it is a
        // change to report rather than a value to put back.
        case .certificate: certificate = .cleared
        case .transport, .selectedServer: break
        }
        refresh()
    }

    // MARK: - The certificate (D134)

    @objc private func chooseCertificate() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Use This Certificate")
        panel.message = String(
            localized: "Choose a PEM file holding this profile's certificate and its private key.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // Off the panel's own completion handler: presenting an alert from
            // inside it lands while the panel is still going away.
            DispatchQueue.main.async { [weak self] in self?.accept(url) }
        }
    }

    private func accept(_ url: URL) {
        switch ClientCertificateFile.read(url) {
        case .success(let identity):
            certificate = .chosen(
                path: url.path, certificate: identity.certificate,
                privateKey: identity.privateKey)
            refresh()
        case .failure(let refusal):
            // Named, and never "invalid file" (2.10): each of these tells the
            // user something different about what to go and find.
            let message: String
            switch refusal {
            case .keystoreNotSupported:
                message = String(
                    localized: """
                        \(url.lastPathComponent) is a keystore, which VPN Plus can't open. \
                        Ask for the certificate and key as a PEM file.
                        """)
            case .noCertificate:
                message = String(localized: "\(url.lastPathComponent) has no certificate in it.")
            case .noPrivateKey:
                message = String(
                    localized: """
                        \(url.lastPathComponent) has a certificate but no private key. \
                        VPN Plus needs both, in the one file.
                        """)
            case .unreadable:
                message = String(
                    localized: """
                        \(url.lastPathComponent) isn't a PEM file. A certificate VPN Plus can \
                        use begins with BEGIN CERTIFICATE.
                        """)
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "That certificate can't be used")
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "OK"))
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: { _ in })
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: - Ending

    @objc private func replaceFile() {
        readFields()
        onDone(outcome())
        dismiss(nil)
        onReplaceFile()
    }

    @objc private func reveal() {
        onReveal()
    }

    @objc private func cancel() {
        // Everything the sheet edited lives in its own copy, so discarding it
        // is simply not handing it back.
        dismiss(nil)
    }

    /// **Done, never Save, and it never connects** (D131). A1 found OpenVPN
    /// Connect's *Save Changes* had become the act of choosing a profile; the
    /// echo stays out of this product.
    @objc private func done() {
        readFields()
        onDone(outcome())
        dismiss(nil)
    }

    private func outcome() -> Outcome {
        Outcome(
            overrides: overrides,
            username: usernameField.stringValue.trimmingCharacters(in: .whitespaces),
            password: passwordField.stringValue,
            certificate: certificate)
    }
}
