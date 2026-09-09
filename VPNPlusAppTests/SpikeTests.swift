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

/// Step 3's spike (M8.4): one test that proves the harness's four claims
/// before any real test is written on them — the bundle loads into the
/// unsigned host, a posted click reaches a Connect button without the app
/// activating, a window ordered to the back is captured whole, and the
/// screenshot directory reaches the host. Runs only when the owner says go.
@MainActor
final class SpikeTests: RehearsalTestCase {
    func testTheHarnessDrivesTheAppWithoutTakingFocus() throws {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "a rehearsal is an accessory")
        XCTAssertTrue(window.isVisible, "the window is not on screen")
        XCTAssertFalse(window.isKeyWindow, "the window became key")

        try importFixtures()
        XCTAssertEqual(state, "idle")

        guard let connect = view(AccessibilityID.profileConnect, in: card(Fixtures.office)) else {
            return XCTFail("no Connect button on \(Fixtures.office)")
        }
        click(connect)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.state == "active:connecting" },
            "after the click the region reads \(state)")
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.state == "active:connected" },
            "the rehearsal did not connect; region reads \(state)")

        XCTAssertTrue(capture(as: "spike-connected"))
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["VPNPLUS_SHOTS"],
            "VPNPLUS_SHOTS did not reach the host; the PNG went to the result bundle only")
    }
}
