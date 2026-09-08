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
    private let savePasswordBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let reconnectBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let openAtLaunchBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    private let rows = NSStackView()
    /// The caption and the Revert of each row that has provenance, kept so
    /// they can be **updated in place**.
    private var captions: [Field: NSTextField] = [:]
    private var reverts: [Field: NSButton] = [:]
    private let certificateRow = NSStackView()
    private let certificateCaption = NSTextField(labelWithString: "")
    private let certificateButton = NSButton(title: "", target: nil, action: nil)

    /// One content width for the whole sheet: label column, control column, and
    /// room for a Revert. Without it a wrapping caption asks for its full
    /// single-line width and the sheet grows to suit (D243).
    private static let labelWidth: CGFloat = 132
    private static let controlWidth: CGFloat = 260
    private static let revertWidth: CGFloat = 72
    private static let contentWidth: CGFloat =
        labelWidth + Space.s + controlWidth + Space.s + revertWidth
    private static let scrollerGutter: CGFloat = 16

    /// How tall the rows may be before they scroll. Set from the window this
    /// sheet belongs to, because a fixed cap is either too small on a large
    /// window or too large on the smallest one this app allows.
    private lazy var heightCap = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 520)
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
        // **Always visible, and reserving its own width.** An overlay scroller
        // appears when you scroll, which is no use to somebody who cannot see
        // that there is anything to scroll to: the first build cut the sheet
        // off mid-section with no indication that three more sections existed.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scroll, footer()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.l
        stack.edgeInsets = NSEdgeInsets(
            top: Space.xl, left: Space.xl, bottom: Space.xl, right: Space.xl)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.contentWidth + 2 * Space.xl, height: 600))
        container.addSubview(stack)
        let height = scroll.heightAnchor.constraint(equalTo: rows.heightAnchor)
        // **Below every label's compression resistance**, and that is the
        // whole of it: at `defaultHigh` this tied the scroll view to the rows
        // *and won*, so the stack squeezed 700 pt of content into 520 — text
        // clipped top and bottom, two checkboxes overlapping, three section
        // headings crushed to nothing. Lower, it only pulls the sheet down to
        // its content when the content is short, and gives way to the cap
        // when it is not.
        height.priority = .defaultLow
        NSLayoutConstraint.activate([
            rows.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            // Room for the scroller beside the rows rather than over them.
            scroll.widthAnchor.constraint(
                equalTo: rows.widthAnchor, constant: Self.scrollerGutter),
            height,
            heightCap,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The sheet may be nearly as tall as the window it is attached to.
        // What is subtracted is this view's own chrome: the insets above and
        // below, the gap to the footer, and the footer itself.
        let available =
            view.window?.sheetParent?.contentLayoutRect.height
            ?? view.window?.screen?.visibleFrame.height
            ?? 640
        heightCap.constant = max(240, available - (2 * Space.xl + Space.l + 40))

        // **And then say how big that makes the sheet.** Without this AppKit
        // keeps the height the root view was constructed with, the stack is
        // stretched to fill it, and the footer floats above a band of empty
        // sheet while the last row is clipped behind it.
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize

        #if DEBUG
            dumpRows()
        #endif
    }

    #if DEBUG
        /// **Development only.** Every row, with its height.
        ///
        /// A tall sheet does not fit in one screenshot, and "I could not see
        /// it" is not evidence that a section is missing — nor that it is
        /// there. This says which rows exist and how tall each one is, which
        /// is how the first build's crushed headings were caught: they were
        /// present, and 0 pt high.
        private func dumpRows() {
            let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "sheet")
            log.notice(
                "sheet \(self.preferredContentSize.width, privacy: .public)×\(self.preferredContentSize.height, privacy: .public), \(self.rows.views.count, privacy: .public) rows, content \(self.rows.fittingSize.height, privacy: .public) pt"
            )
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

    /// A13a's footer. **Replace profile file…** is where overrides earn their
    /// keep (D125): an employer reissues the profile and it costs one file
    /// picker rather than a retyped configuration.
    private func footer() -> NSView {
        let replace = NSButton(
            title: String(localized: "Replace Profile File…"), target: self,
            action: #selector(replaceFile))
        let reveal = NSButton(
            title: String(localized: "Reveal in Finder"), target: self, action: #selector(reveal))
        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done))
        done.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [replace, reveal, spacer, cancel, done])
        row.orientation = .horizontal
        row.spacing = Space.s
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
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
        reconnectBox.title = String(localized: "Reconnect automatically if the connection drops")
        reconnectBox.target = self
        reconnectBox.action = #selector(reconnectChanged)
        rows.addView(reconnectBox, in: .top)
        openAtLaunchBox.title = String(localized: "Connect when VPN Plus opens")
        openAtLaunchBox.target = self
        openAtLaunchBox.action = #selector(openAtLaunchChanged)
        rows.addView(openAtLaunchBox, in: .top)

        buildContents()
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
            savePasswordBox.title = String(localized: "Remember the password in my Keychain")
            savePasswordBox.target = self
            savePasswordBox.action = #selector(savePasswordChanged)
            rows.addView(savePasswordBox, in: .top)
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
        let name = NSTextField(labelWithString: String(localized: "Certificate"))
        name.textColor = Palette.textSecondary
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let revert = revertButton(for: .certificate)

        certificateRow.orientation = .horizontal
        certificateRow.spacing = Space.s
        certificateRow.alignment = .centerY
        certificateRow.translatesAutoresizingMaskIntoConstraints = false
        for subview in [name, certificateButton, spacer, revert] {
            certificateRow.addView(subview, in: .trailing)
        }
        rows.addView(certificateRow, in: .top)
        certificateRow.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let note = caption("")
        rows.addView(note, in: .top)
        captions[.certificate] = note
    }

    /// A13a §6: what this profile contains, read-only. The transparency
    /// section, and what makes this a configuration surface rather than a form.
    ///
    /// **Data-channel offload is deliberately absent.** A13a listed it from
    /// `EvalConfig`, before M1 settled that we pass `dco = false` on macOS
    /// unconditionally — reporting the compatibility of a feature we never use
    /// would be noise dressed as transparency.
    private func buildContents() {
        section(String(localized: "What this profile contains"))
        let servers = max(descriptor.alternateServers.count, 1)
        var lines = [String(localized: "Servers offered: \(servers)")]

        switch descriptor.caPresent {
        case true?:
            lines.append(String(localized: "A CA certificate to check the server against"))
        case false?:
            lines.append(String(localized: "No CA certificate — the server is checked another way"))
        case nil:
            // Imported before this was recorded. Saying so beats guessing
            // about a server's identity.
            lines.append(String(localized: "CA certificate: not recorded at import"))
        }

        if descriptor.externalPKI == true {
            lines.append(String(localized: "Its client identity comes from outside the file"))
        } else if !descriptor.needsNothingFromTheUser {
            lines.append(String(localized: "Signs in with a username and password"))
        }
        if descriptor.credentials.contains(.privateKeyPassphrase) {
            lines.append(String(localized: "A private key that needs a passphrase"))
        }
        if !descriptor.waivedDirectives.isEmpty {
            // 2.8 / D187: this surface *is* the click behind the count, so the
            // list is here rather than one click further.
            lines.append(
                String(
                    localized: """
                        \(descriptor.waivedDirectives.count) settings VPN Plus doesn't use: \
                        \(descriptor.waivedDirectives.joined(separator: ", "))
                        """))
        }
        rows.addView(caption(lines.joined(separator: "\n")), in: .top)
    }

    // MARK: - Rows

    private static let transports: [(id: String, label: String)] = [
        ("udp", "UDP"), ("tcp", "TCP"), ("adaptive", String(localized: "Adaptive")),
    ]

    private func section(_ name: String) {
        let heading = NSTextField(labelWithString: name)
        heading.font = Type.cardTitle
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

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = Palette.textSecondary
        field.font = Type.caption
        // Both, and the constraint is the load-bearing one: on its own
        // `preferredMaxLayoutWidth` decides where text wraps when measuring
        // height, while the field still asks for its full single-line width
        // and the sheet obliges (D243).
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
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
    private func add(_ name: String, _ control: NSView, field: Field?) {
        let title = NSTextField(labelWithString: name)
        title.textColor = Palette.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        if let editable = control as? NSTextField {
            editable.translatesAutoresizingMaskIntoConstraints = false
            editable.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
            editable.font = Type.control
            if editable.isEditable {
                editable.target = self
                editable.action = #selector(fieldChanged)
            }
        }
        if let picker = control as? NSPopUpButton {
            picker.translatesAutoresizingMaskIntoConstraints = false
            picker.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        }

        var line: [NSView] = [title, control]
        if let field {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            line.append(spacer)
            line.append(revertButton(for: field))
        }
        let row = NSStackView(views: line)
        row.orientation = .horizontal
        row.spacing = Space.s
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        guard let field else {
            rows.addView(row, in: .top)
            return
        }
        let note = caption("")
        captions[field] = note
        let group = NSStackView(views: [row, note])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = Space.xs
        group.translatesAutoresizingMaskIntoConstraints = false
        rows.addView(group, in: .top)
    }

    // MARK: - Refreshing, without rebuilding

    /// Puts the composed settings into the controls, the captions and the
    /// Reverts. Safe to call from a field's own action, which is exactly what
    /// `build()` was not.
    private func refresh() {
        let current = settings
        set(titleField, to: current.title.value)
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
            if case .offered(let on) = saving { savePasswordBox.state = on ? .on : .off }
        }
        reconnectBox.state = current.reconnectAutomatically ? .on : .off
        openAtLaunchBox.state = current.connectWhenAppOpens ? .on : .off
        refreshCertificate(current)
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
                localized: "Using \(chosenName) for this profile instead of the profile's own.")
        } else {
            certificateButton.title = String(localized: "Choose…")
            captions[.certificate]?.stringValue = String(
                localized: """
                    A certificate and its private key, in one PEM file, used for this profile \
                    alone. Leave it unset to use whatever the profile carries.
                    """)
        }
        reverts[.certificate]?.isHidden = chosenName == nil
    }

    private func note(_ field: Field, _ provenance: Provenance) {
        switch provenance {
        case .fromProfile:
            captions[field]?.stringValue = String(localized: "from this profile")
            reverts[field]?.isHidden = true
        case .notInProfile:
            captions[field]?.stringValue = String(localized: "not in this profile")
            reverts[field]?.isHidden = true
        case .overridden(let profileValue):
            captions[field]?.stringValue =
                profileValue.isEmpty
                ? String(localized: "your choice")
                : String(localized: "this profile says \(profileValue)")
            reverts[field]?.isHidden = false
        }
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
        overrides.savePassword = savePasswordBox.state == .on
        refresh()
    }

    @objc private func reconnectChanged() {
        overrides.reconnectAutomatically = reconnectBox.state == .on
        refresh()
    }

    @objc private func openAtLaunchChanged() {
        overrides.connectWhenAppOpens = openAtLaunchBox.state == .on
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
