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

/// The README's screenshots (R2b): the routine states a reader should see,
/// on the showcase profiles, in the dark appearance, each window with its
/// shadow and each sheet over its window. They land beside the sweep's, as
/// `$VPNPLUS_SHOTS/<language>/readme-<state>.png`.
///
/// Every value in them is a stand-in: the tunnel is the rehearsal's, the
/// servers are on reserved domains, and the network is `Rehearsal.network`'s
/// documentation addresses — never this Mac's, because these are published.
@MainActor
final class ReadmeShotsTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures(Fixtures.showcase)
    }

    func testTheReadmeShots() throws {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defer { NSApp.appearance = nil }
        pump(0.5)

        // Connecting, once the step has a name; then connected.
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.tokyo))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "region reads \(state)")
        pump(2.4)
        XCTAssertTrue(capture(framed: true, as: "readme-connecting"))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" }, "region reads \(state)")
        pump(0.5)
        XCTAssertTrue(capture(framed: true, as: "readme-connected"))

        // A profile's settings, over the window.
        performMenuItem("edit", of: Fixtures.tokyo)
        let configuration = try XCTUnwrap(waitForSheet(), "Edit… did not open a sheet")
        XCTAssertNotNil(view(AccessibilityID.configurationSheet, in: configuration.contentView))
        XCTAssertTrue(capture(with: configuration, framed: true, as: "readme-configuration"))
        click(try XCTUnwrap(view(AccessibilityID.configurationDone, in: configuration.contentView)))
        XCTAssertTrue(waitForNoSheet())

        click(try XCTUnwrap(view(AccessibilityID.promotedPrimary), "no primary button on the connected region"))
        XCTAssertTrue(waitUntil(timeout: 5) { self.state == "idle" }, "region reads \(state)")
        pump(0.7)

        // A failure, in plain words; then its diagnostics, over the window.
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.frankfurt))))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "failed" }, "region reads \(state)")
        pump(0.5)
        XCTAssertTrue(capture(framed: true, as: "readme-failed"))
        click(try XCTUnwrap(view(AccessibilityID.promotedSecondary), "no Show Details on the failed region"))
        let diagnostics = try XCTUnwrap(waitForSheet(), "Show Details did not open a sheet")
        XCTAssertNotNil(view(AccessibilityID.diagnosticsSheet, in: diagnostics.contentView), "the sheet is not Diagnostics")
        XCTAssertTrue(capture(with: diagnostics, framed: true, as: "readme-diagnostics"))
        click(try XCTUnwrap(view(AccessibilityID.diagnosticsDone, in: diagnostics.contentView)))
        XCTAssertTrue(waitForNoSheet())

        // Settings, General.
        XCTAssertTrue(pressKeyEquivalent(",", .command))
        let settings = try XCTUnwrap(waitForSettingsWindow(), "Settings did not open")
        let section = try XCTUnwrap(view(AccessibilityID.settingsSection, in: settings.contentView))
        click(try XCTUnwrap(view(AccessibilityID.settingsSidebarPrefix + "general", in: settings.contentView)))
        XCTAssertTrue(waitUntil(timeout: 2) { section.accessibilityValue() as? String == "general" })
        XCTAssertTrue(capture(settings, framed: true, as: "readme-settings"))
        settings.close()
    }
}
