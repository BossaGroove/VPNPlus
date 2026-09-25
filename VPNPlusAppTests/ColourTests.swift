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

/// D94 — colour is never the only carrier (M8.5 step 3). Every state a card
/// or the region shows has a word or a shape beside any colour: a spinner
/// while busy, a symbol when failed, the state's own word when connected —
/// the dot alone is never the message.
@MainActor
final class ColourTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures()
    }

    private func visible(_ identifier: String, in root: NSView?) -> NSView? {
        guard let found = view(identifier, in: root), !found.isHiddenOrHasHiddenAncestor, found.alphaValue > 0.5 else { return nil }
        return found
    }

    private func word(_ identifier: String, in root: NSView?) -> String? {
        guard let label = visible(identifier, in: root) as? NSTextField, !label.stringValue.isEmpty else { return nil }
        return label.stringValue
    }

    func testEveryStateHasAWordOrAShapeBesideItsColour() throws {
        let region = try XCTUnwrap(view(AccessibilityID.promotedRegion))

        // Connecting: a spinner (shape) and the step's word, on both surfaces.
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.office))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" })
        layoutNow()
        let officeCard = try XCTUnwrap(card(Fixtures.office))
        XCTAssertNotNil(visible(AccessibilityID.indicatorSpinner, in: officeCard), "busy card: no spinner")
        // The card cross-fades its button and its word, so the word is waited
        // for rather than read at one instant: read mid-fade, it was under
        // half opaque and failed once in six languages (R3, Japanese).
        XCTAssertTrue(waitUntil(timeout: 1) { self.word(AccessibilityID.profileState, in: officeCard) != nil }, "busy card: no word")
        XCTAssertNotNil(visible(AccessibilityID.indicatorSpinner, in: region), "connecting region: no spinner")
        XCTAssertNotNil(word(AccessibilityID.promotedState, in: region), "connecting region: no word")

        // Connected: the dot is colour; the word beside it is the carrier.
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" })
        layoutNow()
        let connectedCard = try XCTUnwrap(card(Fixtures.office))
        XCTAssertNotNil(visible(AccessibilityID.indicatorDot, in: connectedCard), "connected card: no dot")
        XCTAssertTrue(
            waitUntil(timeout: 1) { self.word(AccessibilityID.profileState, in: connectedCard) != nil },
            "connected card: the dot is the only carrier")
        XCTAssertNotNil(visible(AccessibilityID.indicatorDot, in: region), "connected region: no dot")
        XCTAssertNotNil(word(AccessibilityID.promotedState, in: region), "connected region: the dot is the only carrier")
        XCTAssertEqual(connectedCard.accessibilityValue() as? String, "connected")

        click(try XCTUnwrap(view(AccessibilityID.promotedPrimary)))
        XCTAssertTrue(waitUntil(timeout: 5) { self.state == "idle" })
        pump(0.7)

        // Failed: a warning symbol (shape) on the card, a symbol and a title on
        // the region, and Connect still offered on the card (D292).
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.broken))))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "failed" })
        layoutNow()
        let brokenCard = try XCTUnwrap(card(Fixtures.broken))
        let warning = try XCTUnwrap(visible(AccessibilityID.indicatorSymbol, in: brokenCard) as? NSImageView, "failed card: no symbol")
        XCTAssertNotNil(warning.image, "failed card: the symbol has no image")
        XCTAssertNotNil(visible(AccessibilityID.profileConnect, in: brokenCard), "failed card: Connect is gone")
        let icon = try XCTUnwrap(visible(AccessibilityID.indicatorSymbol, in: region) as? NSImageView, "failed region: no symbol")
        XCTAssertNotNil(icon.image, "failed region: the symbol has no image")
        XCTAssertNotNil(word(AccessibilityID.promotedTitle, in: region), "failed region: no title")

        // The idle card carries no indicator at all — nothing to misread.
        let homeCard = try XCTUnwrap(card(Fixtures.home))
        XCTAssertNil(visible(AccessibilityID.indicatorDot, in: homeCard))
        XCTAssertNil(visible(AccessibilityID.indicatorSymbol, in: homeCard))
        XCTAssertNil(word(AccessibilityID.profileState, in: homeCard))
    }
}
