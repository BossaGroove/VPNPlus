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

/// "Sign in to *Singapore*" — one of S2's six sheets (A20).
///
/// **A prompt, not a failure** (A10). Nothing has gone wrong: the app simply
/// does not have what it needs yet, so there is no red, no "couldn't", and no
/// error styling. It appears on the way to connecting and nowhere else, which
/// is what keeps a form off the path to *choosing* a profile (D58).
///
/// The fields follow what the configuration asks for rather than a fixed form
/// (D128): a profile that fixes the username shows it read-only instead of as
/// an empty box (2.14), and a profile that forbids saving does not offer to
/// save (2.15, D129) — **not offered rather than offered and disabled**.
@MainActor
final class SignInSheet: NSViewController {
    private let name: String
    private let settings: ProfileSettings?
    private let onSubmit: (String, String, Bool) -> Void

    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let rememberBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var remembersOffered = false

    /// `saved` says a password is already stored, so the field can promise
    /// nothing rather than pretend to be empty (D222).
    init(
        name: String,
        settings: ProfileSettings?,
        saved: Bool,
        onSubmit: @escaping (String, String, Bool) -> Void
    ) {
        self.name = name
        self.settings = settings
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
        passwordField.placeholderString =
            saved
            ? String(localized: "Saved")
            : String(localized: "Password")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let title = NSTextField.label(
            String(localized: "Sign in to \(name)"), font: Type.sectionTitle,
            colour: Palette.textPrimary, truncation: .byTruncatingMiddle)

        var rows: [NSView] = [title]

        var usernameLocked = false
        if case .credentials(let username, let saving, let challenge) = settings?.signIn {
            switch username {
            case .fixed(let fixed):
                usernameField.stringValue = fixed
                usernameField.isEditable = false
                usernameLocked = true
            case .editable(let value):
                usernameField.stringValue = value.value
                usernameField.placeholderString = String(localized: "Username")
            }
            rows.append(field(String(localized: "Username"), usernameField))
            if usernameLocked {
                rows.append(
                    NSTextField.label(
                        String(localized: "set by this profile"), font: Type.caption,
                        colour: Palette.textTertiary))
            }
            rows.append(field(String(localized: "Password"), passwordField))

            if case .offered(let on) = saving {
                remembersOffered = true
                rememberBox.title = String(localized: "Remember the password in my Keychain")
                rememberBox.state = on ? .on : .off
                rows.append(rememberBox)
            } else {
                rows.append(
                    NSTextField.label(
                        String(localized: "This profile doesn't allow saving the password."),
                        font: Type.caption, colour: Palette.textTertiary))
            }

            // The server's own extra question, quoted rather than spoken in
            // our voice (D104). Answering it is M6's; naming it is honest now.
            if let challenge {
                rows.append(
                    NSTextField.label(
                        String(localized: "This profile also asks: \(challenge.prompt)"),
                        font: Type.caption, colour: Palette.textTertiary))
            }
        }

        let connect = NSButton(
            title: String(localized: "Connect"), target: self, action: #selector(submit))
        connect.keyEquivalent = "\r"
        connect.bezelStyle = .rounded
        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(dismissSheet))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, connect])
        buttons.orientation = .horizontal
        buttons.spacing = Space.s
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.m
        stack.edgeInsets = NSEdgeInsets(
            top: Space.xl, left: Space.xl, bottom: Space.xl, right: Space.xl)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The field they have to fill in, focused. Not the one the profile
        // already answered.
        view.window?.makeFirstResponder(usernameField.isEditable ? usernameField : passwordField)
    }

    private func field(_ label: String, _ control: NSTextField) -> NSView {
        control.font = Type.control
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let name = NSTextField.label(label, font: Type.caption, colour: Palette.textSecondary)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [name, control])
        row.orientation = .horizontal
        row.spacing = Space.s
        return row
    }

    @objc private func submit() {
        let remember = remembersOffered && rememberBox.state == .on
        onSubmit(usernameField.stringValue, passwordField.stringValue, remember)
        close()
    }

    @objc private func dismissSheet() { close() }

    private func close() {
        // The same postcondition the configuration sheet keeps (D223): AppKit
        // swallows an exception thrown in an action, and a sheet nobody can
        // dismiss blocks the whole window.
        dismiss(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let sheet = self?.view.window, let parent = sheet.sheetParent else { return }
            parent.endSheet(sheet)
        }
    }
}
