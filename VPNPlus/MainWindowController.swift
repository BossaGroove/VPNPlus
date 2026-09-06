// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 VPN Plus contributors
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

/// M0's only screen: it says what the extension is doing. The real main window
/// is designed in docs/ux/screen-main.md and built in a later milestone.
@MainActor
final class MainWindowController: NSWindowController {
    private let installer = ExtensionInstaller(
        identifier: "com.bossagroove.VPNPlus.tunnel"
    )
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VPN Plus"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 620, height: 440)
        super.init(window: window)
        buildLayout()
        installer.onChange = { [weak self] status in self?.render(status) }
        render(installer.status)
        installer.activate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildLayout() {
        let stack = NSStackView(views: [statusLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .title2)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 480

        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func render(_ status: ExtensionInstaller.Status) {
        switch status {
        case .idle:
            statusLabel.stringValue = "Starting up"
            detailLabel.stringValue = ""
        case .requesting:
            statusLabel.stringValue = "Setting up the network component"
            detailLabel.stringValue = "This happens once."
        case .needsApproval:
            statusLabel.stringValue = "Waiting for your approval"
            detailLabel.stringValue = """
                macOS is asking you to allow VPN Plus in System Settings.                 This window will notice when you have.
                """
        case .active:
            statusLabel.stringValue = "Network component ready"
            detailLabel.stringValue = "M0 scaffold — no tunnel engine yet."
        case .failed(let message):
            statusLabel.stringValue = "Setup did not finish"
            detailLabel.stringValue = message
        }
    }
}
