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

/// The stored profiles, as a list you can select, connect, configure and
/// delete.
///
/// **M3 ONLY in its chrome**: the designed surface is A12/A13's card grid and
/// arrives with M5. What is real is that connecting reads a stored profile,
/// which is what removes the file picker from the everyday path.
@MainActor
final class ProfileListView: NSView {
    var onSelect: ((Profile?) -> Void)?
    var onConnect: ((Profile) -> Void)?
    var onConfigure: ((Profile) -> Void)?
    var onDelete: ((Profile) -> Void)?

    private var profiles: [Profile] = []
    private let table = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.title = String(localized: "Profiles")
        column.width = 320
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .inset
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.menu = rowMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    var selected: Profile? {
        let row = table.selectedRow
        return profiles.indices.contains(row) ? profiles[row] : nil
    }

    func show(_ profiles: [Profile]) {
        let previous = selected?.id
        self.profiles = profiles
        table.reloadData()
        if let previous, let row = profiles.firstIndex(where: { $0.id == previous }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !profiles.isEmpty, table.selectedRow < 0 {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        onSelect?(selected)
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Connect"), action: #selector(connectSelected), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(configureSelected), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Delete…"), action: #selector(deleteSelected), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func doubleClicked() {
        // Double-click connects: the everyday action, one gesture (A6).
        guard let profile = selected else { return }
        onConnect?(profile)
    }

    @objc private func connectSelected() {
        guard let profile = selected else { return }
        onConnect?(profile)
    }

    @objc private func configureSelected() {
        guard let profile = selected else { return }
        onConfigure?(profile)
    }

    @objc private func deleteSelected() {
        guard let profile = selected else { return }
        onDelete?(profile)
    }

    override func keyDown(with event: NSEvent) {
        // Delete removes, with the confirmation the caller puts up: a profile
        // holds a private key, and losing it silently is not recoverable.
        let deleteKeys: Set<UInt16> = [51, 117]
        if deleteKeys.contains(event.keyCode), let profile = selected {
            onDelete?(profile)
            return
        }
        super.keyDown(with: event)
    }
}

extension ProfileListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]

        let title = NSTextField(labelWithString: profile.title)
        let detail = NSTextField(labelWithString: subtitle(for: profile))
        detail.textColor = .secondaryLabelColor
        detail.font = .preferredFont(forTextStyle: .caption1)

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    /// The count of set-aside settings, never the list: that is one click
    /// behind, in the settings sheet (D187).
    private func subtitle(for profile: Profile) -> String {
        let waived = profile.waivedDirectives.count
        guard waived > 0 else { return profile.origin.filename }
        return String(localized: "\(profile.origin.filename) — \(waived) settings not used")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selected)
    }
}
