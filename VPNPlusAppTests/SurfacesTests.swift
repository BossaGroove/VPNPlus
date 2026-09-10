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
import XCTest

@testable import VPN_Plus

/// The surfaces a click reaches (M8.4, step 4): the replace report through
/// the real import path, Settings' three sections, the card menu's items, and
/// reordering from it.
@MainActor
final class SurfacesTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures()
    }

    /// Importing a file with the name of an existing profile replaces it and
    /// says so (D289): the report, not silence, and not a fourth card.
    func testImportingTheSameFileAgainShowsTheReplaceReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPNPlusAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("\(Fixtures.office).ovpn")
        try Fixtures.officeReissued.write(to: url, atomically: true, encoding: .utf8)

        controller.importProfile(at: url)
        let sheet = try XCTUnwrap(waitForSheet(), "no sheet after a replacing import")
        XCTAssertNotNil(view(AccessibilityID.replaceReport, in: sheet.contentView), "the sheet is not the replace report")
        XCTAssertEqual(cards.count, Fixtures.profiles.count, "a replacing import added a card instead")
        XCTAssertEqual(delegate.catalogue.profiles.first { $0.title == Fixtures.office }?.descriptor?.server.port, "443", "the profile does not carry the reissued file's port")

        click(try XCTUnwrap(view(AccessibilityID.replaceReportDone, in: sheet.contentView), "no Done on the report"))
        XCTAssertTrue(waitForNoSheet(), "the report did not close")
    }

    /// ⌘, opens Settings, and its three sections are each one click away.
    func testSettingsHasItsThreeSections() throws {
        XCTAssertTrue(pressKeyEquivalent(",", .command), "the main menu did not take ⌘,")
        let settings = try XCTUnwrap(waitForSettingsWindow(), "Settings did not open")
        XCTAssertFalse(settings.isKeyWindow, "Settings became key — the rehearsal must not take focus")
        let section = try XCTUnwrap(view(AccessibilityID.settingsSection, in: settings.contentView), "no section view")
        XCTAssertEqual(section.accessibilityValue() as? String, "general", "Settings did not open on General")

        for key in ["menuBar", "softwareUpdate", "general"] {
            let item = try XCTUnwrap(view(AccessibilityID.settingsSidebarPrefix + key, in: settings.contentView), "no sidebar item for \(key)")
            click(item)
            XCTAssertTrue(waitUntil(timeout: 2) { section.accessibilityValue() as? String == key }, "the \(key) section did not show; section reads \(section.accessibilityValue() ?? "nil")")
            XCTAssertEqual(settings.title, SettingsWindowController.Section.allCases.first { $0.key == key }?.title, "the window title does not follow the section")
        }
        settings.close()
    }

    /// The card's menu offers what the design says — connect, rename, edit,
    /// reveal, move both ways, remove — with a word on every item.
    func testTheCardMenuOffersItsActions() throws {
        let card = try XCTUnwrap(card(Fixtures.home) as? ProfileCardView)
        let menu = card.menuForTesting()
        let keys = ["connect", "rename", "edit", "reveal", "moveLeft", "moveRight", "remove"]
        let identifiers = menu.items.filter { !$0.isSeparatorItem }.map { $0.accessibilityIdentifier() }
        XCTAssertEqual(identifiers, keys.map { AccessibilityID.cardMenuPrefix + $0 }, "the menu's items, in order")
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertFalse(item.title.isEmpty, "\(item.accessibilityIdentifier()) has no title")
            XCTAssertNotNil(item.target, "\(item.title) goes nowhere")
        }
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 3, "the menu's three groups")
    }

    /// Move Right swaps a card with its neighbour, Move Left brings it back,
    /// and the order is what the store says, not only what the grid shows.
    func testMoveRightAndMoveLeftReorderTheCards() throws {
        XCTAssertEqual(cardOrder, [Fixtures.broken, Fixtures.home, Fixtures.office])

        performMenuItem("moveRight", of: Fixtures.broken)
        XCTAssertTrue(waitUntil(timeout: 3) { self.cardOrder == [Fixtures.home, Fixtures.broken, Fixtures.office] }, "after Move Right the order is \(cardOrder)")
        XCTAssertEqual(delegate.catalogue.profiles.map(\.title), [Fixtures.home, Fixtures.broken, Fixtures.office], "the store's order differs from the grid's")

        performMenuItem("moveLeft", of: Fixtures.broken)
        XCTAssertTrue(waitUntil(timeout: 3) { self.cardOrder == [Fixtures.broken, Fixtures.home, Fixtures.office] }, "after Move Left the order is \(cardOrder)")

        // The first card cannot move left: nothing changes, nothing breaks.
        performMenuItem("moveLeft", of: Fixtures.broken)
        pump(0.3)
        XCTAssertEqual(cardOrder, [Fixtures.broken, Fixtures.home, Fixtures.office])
    }
}
