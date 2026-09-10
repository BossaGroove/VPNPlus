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

/// What has only ever been found by clicking (M8.4): each of these is a
/// defect the owner found in the running app, with the test that would have
/// caught it. The directive numbers are the private working docs' names.
@MainActor
final class ClickOnlyBugsTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures()
    }

    /// D259 — a single click on Connect connects. A label at alpha 0 sat over
    /// the button and took every click; only a double-click got through.
    func testASingleClickOnConnectConnects() throws {
        layoutNow()
        let office = try XCTUnwrap(card(Fixtures.office), "no card for \(Fixtures.office); cards: \(cardLabels)")
        let connect = try XCTUnwrap(view(AccessibilityID.profileConnect, in: office), "no Connect on \(Fixtures.office)")
        // The mechanism: the state word over the button refuses every hit.
        let word = try XCTUnwrap(view(AccessibilityID.profileState, in: office), "no state word")
        XCTAssertNil(word.hitTest(word.frame.origin), "the state word takes hits, so it would swallow the click beneath it")
        let centre = connect.convert(NSPoint(x: connect.bounds.midX, y: connect.bounds.midY), to: word.superview)
        XCTAssertTrue(word.frame.contains(centre), "the word (\(word.frame)) no longer covers the button's centre (\(centre)), which is what made its hit test matter")
        click(connect)
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "after one click the region reads \(state)")
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" }, "the rehearsal did not connect; region reads \(state)")
        XCTAssertEqual(card(Fixtures.office)?.accessibilityValue() as? String, "connected", "the card does not show the connection")
    }

    /// D287 — Connect on another card while a profile has Failed connects it.
    /// Failed is not Disconnected, so it took the switch path and waited for
    /// a teardown that would never come.
    func testConnectFromFailedConnectsTheOtherProfile() throws {
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.broken))))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "failed" }, "the broken fixture did not fail; region reads \(state)")
        XCTAssertEqual(card(Fixtures.broken)?.accessibilityValue() as? String, "failed", "the failed card is not marked")

        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.office))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "Connect from Failed did nothing; region reads \(state)")
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" }, "region reads \(state)")
    }

    /// M4.6's freeze — untick the password switch, Done. An exception inside
    /// the button action was swallowed by AppKit and the window stopped
    /// responding to everything.
    func testTheSheetSurvivesUntickingRememberAndDone() throws {
        performMenuItem("edit", of: Fixtures.home)
        let sheet = try XCTUnwrap(waitForSheet(), "the configuration sheet did not open")
        let remember = try XCTUnwrap(view(AccessibilityID.configurationRemember, in: sheet.contentView) as? NSSwitch, "no Remember switch")
        XCTAssertEqual(remember.state, .on, "the fixture counts as signed in, so the switch starts on")
        click(remember)
        XCTAssertTrue(waitUntil(timeout: 2) { remember.state == .off }, "the click did not untick the switch")
        click(try XCTUnwrap(view(AccessibilityID.configurationDone, in: sheet.contentView)))
        XCTAssertTrue(waitForNoSheet(), "the sheet did not close")

        // Still alive: the window answers a click and a menu.
        XCTAssertEqual(card(Fixtures.home)?.accessibilityValue() as? String, "idle")
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.office))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "after Done the window no longer responds; region reads \(state)")
    }

    /// D278 — the Name card keeps its height when the transparency section is
    /// folded and unfolded. It grew to 212 pt once, because the sheet asked a
    /// window's content view for its fitting size.
    func testTheNameCardKeepsItsHeightWhenTheContentsFold() throws {
        performMenuItem("edit", of: Fixtures.home)
        let sheet = try XCTUnwrap(waitForSheet(), "the configuration sheet did not open")
        let nameCard = try XCTUnwrap(view(AccessibilityID.configurationNameCard, in: sheet.contentView), "no Name card")
        let contents = try XCTUnwrap(view(AccessibilityID.configurationContents, in: sheet.contentView) as? NSButton, "no contents disclosure")
        layoutNow()
        let before = nameCard.frame.height
        XCTAssertGreaterThan(before, 0)

        click(contents)
        XCTAssertTrue(waitUntil(timeout: 2) { contents.state == .on }, "the disclosure did not open")
        pump(0.3)
        XCTAssertEqual(nameCard.frame.height, before, accuracy: 0.5, "the Name card grew on unfolding")

        click(contents)
        XCTAssertTrue(waitUntil(timeout: 2) { contents.state == .off }, "the disclosure did not fold")
        pump(0.3)
        XCTAssertEqual(nameCard.frame.height, before, accuracy: 0.5, "the Name card grew on folding")

        click(try XCTUnwrap(view(AccessibilityID.configurationDone, in: sheet.contentView)))
        XCTAssertTrue(waitForNoSheet())
    }
}
