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

import Foundation

/// The hooks a UI test holds on to (M8.4). Identifiers, not labels: a label
/// is what the user reads and changes with the language; an identifier is the
/// same in all six. Whatever harness drives the app shares this file, so the
/// two cannot drift.
///
/// Where a surface has a *state* the tests care about, it is exposed as the
/// element's accessibility **value** — `promotedRegion` carries the window
/// state's name, `profileCard` the card's presence — so a test waits on a
/// word that no translation touches.
enum AccessibilityID {
    static let mainWindow = "main.window"
    static let guidance = "main.guidance"
    static let guidanceAction = "main.guidance.action"

    static let promotedRegion = "promoted.region"
    static let promotedTitle = "promoted.title"
    static let promotedPrimary = "promoted.primary"
    static let promotedProseAction = "promoted.prose-action"
    static let promotedSecondary = "promoted.secondary"
    static let promotedTertiary = "promoted.tertiary"

    static let profileCard = "profile.card"
    static let profileConnect = "profile.connect"
    static let profileMore = "profile.more"
    static let profileState = "profile.state"
    /// `card.menu.connect`, `.rename`, `.edit`, `.reveal`, `.moveLeft`,
    /// `.moveRight`, `.remove` — the card's menu items.
    static let cardMenuPrefix = "card.menu."

    static let configurationSheet = "sheet.configuration"
    static let configurationDone = "sheet.configuration.done"
    static let configurationNameCard = "sheet.configuration.name-card"
    static let configurationRemember = "sheet.configuration.remember"
    static let configurationContents = "sheet.configuration.contents"

    static let replaceReport = "sheet.replace-report"
    static let replaceReportDone = "sheet.replace-report.done"

    static let messageSheet = "sheet.message"

    static let diagnosticsSheet = "sheet.diagnostics"
    static let diagnosticsDone = "sheet.diagnostics.done"

    static let settingsWindow = "settings.window"
    static let settingsSidebarPrefix = "settings.sidebar."
    static let settingsSection = "settings.section"
}
