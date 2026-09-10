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

/// D12 — the whole grid is drivable without a mouse, and the sheets answer
/// their keys (M8.5 step 3). Key presses are delivered to the window, which
/// routes them as AppKit would; nothing is posted system-wide.
@MainActor
final class KeyboardTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures()
    }

    private var grid: CardGridView {
        get throws { try XCTUnwrap(firstView(of: CardGridView.self), "no card grid") }
    }

    private func selectedTitle() throws -> String? {
        try grid.selected.map { delegate.catalogue.title(of: $0) }
    }

    /// Arrows move the selection along the row; Return connects the selected
    /// card.
    func testArrowsMoveTheSelectionAndReturnConnects() throws {
        let grid = try grid
        XCTAssertTrue(window.makeFirstResponder(grid), "the grid did not take first responder")
        press(Key.right)
        XCTAssertEqual(try selectedTitle(), Fixtures.home)
        press(Key.right)
        XCTAssertEqual(try selectedTitle(), Fixtures.office)
        press(Key.left)
        XCTAssertEqual(try selectedTitle(), Fixtures.home)
        press(Key.return)
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "Return did not connect; region reads \(state)")
        XCTAssertEqual(delegate.tunnel.connection.profile.flatMap { delegate.catalogue.profile($0) }?.title, Fixtures.home, "Return connected the wrong card")
    }

    /// Letters jump to a card by what it says on it — "off" finds Office even
    /// though every fixture starts with the same word.
    func testTypeAheadJumpsToAName() throws {
        let grid = try grid
        window.makeFirstResponder(grid)
        for character in ["o", "f", "f"] { pressKey(character, keyCode: 0) }
        let landed = try selectedTitle()
        XCTAssertEqual(landed, Fixtures.office, "type-ahead landed on \(landed ?? "nothing")")
        pump(1.1)  // the buffer forgets after a second
        for character in ["h", "o"] { pressKey(character, keyCode: 0) }
        XCTAssertEqual(try selectedTitle(), Fixtures.home)
    }

    /// ⌘⌫ asks before removing, and Escape declines — the card stays.
    func testCommandDeleteAsksAndEscapeDeclines() throws {
        let grid = try grid
        window.makeFirstResponder(grid)
        press(Key.right)
        XCTAssertEqual(try selectedTitle(), Fixtures.home)
        press(Key.delete, modifiers: .command)
        let sheet = try XCTUnwrap(waitForSheet(), "⌘⌫ did not ask")
        XCTAssertNotNil(view(AccessibilityID.messageSheet, in: sheet.contentView), "the sheet is not the remove confirmation")
        press(Key.escape, in: sheet)
        XCTAssertTrue(waitForNoSheet(), "Escape did not decline")
        XCTAssertEqual(cards.count, Fixtures.profiles.count, "a card went missing")
    }

    /// Escape cancels the configuration sheet, and Done is its default button.
    ///
    /// Return itself is not asserted: AppKit disables the default button's key
    /// equivalent while a field editor is active (the Name field has focus
    /// when the sheet opens, and Return commits the name), and in the
    /// rehearsal's never-key window the restore after tabbing out did not
    /// happen (M8.5 step 3, 2026-09-10) — so whether Return closes the sheet
    /// once focus has left a field is checked by a person, not here.
    func testEscapeCancelsTheConfigurationSheetAndDoneIsTheDefault() throws {
        performMenuItem("edit", of: Fixtures.home)
        var sheet = try XCTUnwrap(waitForSheet(), "the configuration sheet did not open")
        press(Key.escape, in: sheet)
        XCTAssertTrue(waitForNoSheet(), "Escape did not cancel the sheet")

        performMenuItem("edit", of: Fixtures.home)
        sheet = try XCTUnwrap(waitForSheet(), "the configuration sheet did not open again")
        let done = try XCTUnwrap(view(AccessibilityID.configurationDone, in: sheet.contentView) as? NSButton)
        XCTAssertTrue(sheet.defaultButtonCell === done.cell, "Done is not the sheet's default button")
        press(Key.return, in: sheet)
        print("KEYBOARD NOTE: Return with the Name field focused closed the sheet: \(waitForNoSheet(timeout: 1))")
        if window.attachedSheet != nil { click(done) }
        XCTAssertTrue(waitForNoSheet())
    }
}
