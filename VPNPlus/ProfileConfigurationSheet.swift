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

/// A profile's settings, as a sheet.
///
/// **M3 ONLY in its chrome.** The designed surface is A13a's and arrives with
/// M5; what is real here is the *behaviour*, which comes entirely from
/// `ProfileSettings.compose` — so a fixed username is read-only because the
/// model says so, not because this file remembers to disable a field, and the
/// same is true of password saving and the server picker.
///
/// Two rules it must honour whatever it looks like: the commit button says
/// **Done**, never Save, and it never connects (D131); and this surface is
/// never on the path to connecting (2.13).
@MainActor
final class ProfileConfigurationSheet: NSViewController {
    private let profile: Profile
    private let descriptor: ProfileDescriptor
    private var overrides: Overrides
    private let onDone: (Overrides) -> Void

    /// D215: without the filename this calls the profile by its IP address,
    /// which is what the sheet did until M5.6 while the card beside it said
    /// "Configure NA". Two surfaces naming the same profile differently is the
    /// defect, not the cosmetics of either one.
    private var settings: ProfileSettings {
        ProfileSettings.compose(descriptor, with: overrides, filename: profile.origin.filename)
    }

    /// The name the profile has when the user has not renamed it. `readFields`
    /// compares against this, so typing the name already shown is not stored
    /// as an override.
    private var defaultTitle: String {
        descriptor.preferredTitle(filename: profile.origin.filename)
    }

    /// One content width for the whole sheet, so the sheet is as wide as its
    /// widest row and no wider. Without it a wrapping caption asks for its
    /// full single-line width, the sheet grows to suit, and the rows sit in a
    /// gutter — which is what "the size looks wrong" was.
    private static let contentWidth: CGFloat = 110 + 8 + 260 + 8 + 72

    private let titleField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let serverPicker = NSPopUpButton()
    private let usernameField = NSTextField(string: "")
    private let savePasswordBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let reconnectBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let openAtLaunchBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var rows = NSStackView()

    init(profile: Profile, descriptor: ProfileDescriptor, overrides: Overrides, onDone: @escaping (Overrides) -> Void) {
        self.profile = profile
        self.descriptor = descriptor
        self.overrides = overrides
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        build()

        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        // A spacer that gives way, so Done sits at the trailing edge of the
        // content rather than the rows being dragged over there with it.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, done])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [rows, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth + 40, height: 460))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            rows.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            buttons.widthAnchor.constraint(equalTo: rows.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            // Equal, not at-most: the sheet takes its height from its rows.
            // At-most left the height at whatever the frame above happened to
            // say, so the sheet was too tall for a short profile and clipped a
            // long one.
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: - Rows built from the composed settings

    private func build() {
        let current = settings

        titleField.stringValue = current.title.value
        titleField.placeholderString = profile.origin.filename
        add(String(localized: "Name"), titleField, provenance: current.title.provenance)

        switch current.server {
        case let .single(host, port, transport):
            hostField.stringValue = host.value
            portField.stringValue = port.value
            add(String(localized: "Server"), hostField, provenance: host.provenance)
            add(String(localized: "Port"), portField, provenance: port.provenance)
            add(String(localized: "Transport"), label(transport.value.uppercased()), provenance: transport.provenance)
        case let .choice(offered, selected):
            // 2.16 / D130: several servers make this a choice, not a value.
            serverPicker.removeAllItems()
            for choice in offered { serverPicker.addItem(withTitle: choice.label) }
            if let index = offered.firstIndex(where: { $0.host == selected }) {
                serverPicker.selectItem(at: index)
            }
            serverPicker.target = self
            serverPicker.action = #selector(serverChosen)
            add(String(localized: "Server"), serverPicker, provenance: nil)
        }

        switch current.signIn {
        case .notNeeded:
            add(String(localized: "Sign-in"), label(String(localized: "This profile signs in by itself")), provenance: nil)
        case let .credentials(username, saving, challenge):
            switch username {
            case .fixed(let fixed):
                // 2.14: read-only, never an empty field.
                add(String(localized: "Username"), label(fixed),
                    caption: String(localized: "set by this profile"), provenance: nil)
            case .editable(let value):
                usernameField.stringValue = value.value
                add(String(localized: "Username"), usernameField, provenance: value.provenance)
            }
            switch saving {
            case .offered(let on):
                savePasswordBox.title = String(localized: "Remember the password in my Keychain")
                savePasswordBox.state = on ? .on : .off
                savePasswordBox.target = self
                savePasswordBox.action = #selector(savePasswordChanged)
                rows.addView(savePasswordBox, in: .top)
            case .forbiddenByProfile:
                // 2.15: absent, not shown and disabled. A caption says why,
                // because an unexplained absence is its own confusion.
                rows.addView(caption(String(localized: "This profile doesn't allow saving the password.")), in: .top)
            }
            if let challenge {
                add(String(localized: "Also asks for"), label(challenge.prompt), provenance: nil)
            }
        }

        if current.keyPassphraseNeeded {
            add(String(localized: "Certificate"), label(String(localized: "Needs a passphrase to unlock")), provenance: nil)
        }

        reconnectBox.title = String(localized: "Reconnect automatically if the connection drops")
        reconnectBox.state = current.reconnectAutomatically ? .on : .off
        reconnectBox.target = self
        reconnectBox.action = #selector(reconnectChanged)
        rows.addView(reconnectBox, in: .top)

        openAtLaunchBox.title = String(localized: "Connect when VPN Plus opens")
        openAtLaunchBox.state = current.connectWhenAppOpens ? .on : .off
        openAtLaunchBox.target = self
        openAtLaunchBox.action = #selector(openAtLaunchChanged)
        rows.addView(openAtLaunchBox, in: .top)

        // 2.8 / D187: the count, with the list here rather than one click
        // further, because this surface *is* the click behind the count.
        if !current.waivedDirectives.isEmpty {
            rows.addView(caption(String(localized: """
                VPN Plus doesn't use \(current.waivedDirectives.count) of this profile's settings: \
                \(current.waivedDirectives.joined(separator: ", ")).
                """)), in: .top)
        }
    }

    /// True while the rows are being replaced.
    private var rebuilding = false

    /// Replaces every row from the composed settings.
    ///
    /// **It must not re-enter, and this is not a precaution.** Removing a text
    /// field from the view hierarchy ends its editing session, which fires its
    /// action — which is the very thing that asks for a rebuild. The second
    /// pass then removes everything while the first is still walking a list of
    /// views that no longer exist, and AppKit aborts with *"View … is not (and
    /// has to be) in stack view"*. Measured on 2026-09-07: two rebuilds 5 ms
    /// apart, the second reordering the list under the first.
    ///
    /// `removeFromSuperview()` rather than `removeView(_:)` for the same
    /// reason: it is a no-op on a view that has already gone, where the other
    /// is an assertion.
    private func rebuild() {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        for view in rows.views { view.removeFromSuperview() }
        build()
    }

    // MARK: - Rows

    private func label(_ text: String) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        return field
    }

    private func caption(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .preferredFont(forTextStyle: .caption1)
        // Both, and the constraint is the load-bearing one:
        // `preferredMaxLayoutWidth` alone only decides where the text wraps
        // for the purpose of measuring height — the field still asks for its
        // full single-line width, and the sheet obliges.
        field.preferredMaxLayoutWidth = Self.contentWidth
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return field
    }

    /// One row: a name, a control, and where its value came from (D126).
    private func add(_ name: String, _ control: NSView, caption custom: String? = nil, provenance: Provenance?) {
        let name = NSTextField(labelWithString: name)
        name.textColor = .secondaryLabelColor
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if let field = control as? NSTextField, field.isEditable {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            field.target = self
            field.action = #selector(fieldChanged)
        }

        var line: [NSView] = [name, control]
        if case .overridden = provenance {
            let revert = NSButton(title: String(localized: "Revert"), target: self, action: #selector(revert(_:)))
            revert.bezelStyle = .accessoryBarAction
            revert.identifier = control.identifier
            revert.tag = rows.views.count
            // Flush with the content's trailing edge, so Revert and Done sit
            // in the same column rather than a few points apart.
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            line.append(spacer)
            line.append(revert)
        }
        let row = NSStackView(views: line)
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        rows.addView(row, in: .top)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        let text: String?
        switch (custom, provenance) {
        case (let custom?, _): text = custom
        case (nil, .fromProfile): text = String(localized: "from this profile")
        case (nil, .notInProfile): text = String(localized: "not in this profile")
        case let (nil, .overridden(profileValue)):
            text = profileValue.isEmpty
                ? String(localized: "your choice")
                : String(localized: "this profile says \(profileValue)")
        case (nil, nil): text = nil
        }
        if let text {
            let note = caption(text)
            note.translatesAutoresizingMaskIntoConstraints = false
            rows.addView(note, in: .top)
        }
    }

    // MARK: - Editing

    @objc private func fieldChanged() {
        readFields()
        rebuild()
    }

    /// Reads what is typed into the overrides. No layout of any kind: a
    /// caller that is closing the sheet has no business rebuilding it.
    private func readFields() {
        overrides.title = value(titleField, default: defaultTitle)
        overrides.username = value(usernameField, default: "")
        let host = value(hostField, default: descriptor.server.host)
        let port = value(portField, default: descriptor.server.port)
        if host == nil, port == nil {
            overrides.server = nil
        } else {
            overrides.server = ServerEndpoint(
                host: host ?? descriptor.server.host,
                port: port ?? descriptor.server.port,
                transport: overrides.server?.transport ?? descriptor.server.transport)
        }
    }

    /// nil when the field agrees with the profile, so agreeing is not an
    /// override — the model's rule, honoured here.
    private func value(_ field: NSTextField, default profileValue: String) -> String? {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || typed == profileValue { return nil }
        return typed
    }

    @objc private func serverChosen() {
        guard case let .choice(offered, _) = settings.server,
              serverPicker.indexOfSelectedItem >= 0,
              serverPicker.indexOfSelectedItem < offered.count
        else { return }
        overrides.selectedServer = offered[serverPicker.indexOfSelectedItem].host
    }

    @objc private func savePasswordChanged() {
        overrides.savePassword = savePasswordBox.state == .on
    }

    @objc private func reconnectChanged() {
        overrides.reconnectAutomatically = reconnectBox.state == .on
    }

    @objc private func openAtLaunchChanged() {
        overrides.connectWhenAppOpens = openAtLaunchBox.state == .on
    }

    @objc private func revert(_ sender: NSButton) {
        // A blunt revert while the chrome is provisional: everything the user
        // typed on this sheet goes back to what the profile says. M5's sheet
        // reverts one row, as A13a designed.
        overrides.title = nil
        overrides.username = nil
        overrides.server = nil
        titleField.stringValue = descriptor.displayName
        usernameField.stringValue = ""
        hostField.stringValue = descriptor.server.host
        portField.stringValue = descriptor.server.port
        rebuild()
    }

    /// "Done", never "Save", and it never connects (D131).
    @objc private func done() {
        readFields()
        onDone(overrides)
        dismiss(nil)
        // And then check that it actually went.
        //
        // AppKit catches an exception thrown inside a control's action and
        // carries on, so a failure part-way through this method leaves the
        // sheet up with nothing to close it: the window is blocked, Quit is
        // refused, and the user's only way out is Force Quit. That is exactly
        // what happened on 2026-09-07 — an assertion in the rebuild, invisible
        // as anything but "the app froze". The cause is fixed; this checks the
        // postcondition anyway, because the cost of being wrong here is the
        // whole app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let sheet = self?.view.window, let parent = sheet.sheetParent else { return }
            parent.endSheet(sheet)
        }
    }
}
