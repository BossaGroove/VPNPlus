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

/// The A18 sweep's evidence (M8.4 step 5 → M8.5): every routine state, one
/// capture each, in whichever language the host was launched in
/// (`xcodebuild test -testLanguage`; `Scripts/ui-test.sh` loops the six).
/// PNGs land in `$VPNPLUS_SHOTS/<language>/<state>.png` and in the result
/// bundle. Sheets and Settings are windows of their own and are captured as
/// such.
@MainActor
final class LanguageSweepTests: RehearsalTestCase {
    override func prepare() throws {
        try importFixtures()
    }

    func testEveryRoutineStateIsCaptured() throws {
        XCTAssertTrue(capture(as: "idle"))

        // Connecting, past D235's two-second reveal so the step has a name;
        // then connected.
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.office))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "region reads \(state)")
        pump(2.4)
        XCTAssertTrue(capture(as: "connecting"))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" }, "region reads \(state)")
        XCTAssertTrue(capture(as: "connected"))

        // Disconnect from the region's own button, back to idle.
        click(try XCTUnwrap(view(AccessibilityID.promotedPrimary), "no primary button on the connected region"))
        XCTAssertTrue(waitUntil(timeout: 5) { self.state == "idle" }, "region reads \(state)")
        pump(0.7)

        // Failed, with the region's causes and comparison; then Show Details.
        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.broken))))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "failed" }, "region reads \(state)")
        XCTAssertTrue(capture(as: "failed"))
        click(try XCTUnwrap(view(AccessibilityID.promotedSecondary), "no Show Details on the failed region"))
        let diagnostics = try XCTUnwrap(waitForSheet(), "Show Details did not open a sheet")
        XCTAssertNotNil(view(AccessibilityID.diagnosticsSheet, in: diagnostics.contentView), "the sheet is not Diagnostics")
        XCTAssertTrue(capture(diagnostics, as: "diagnostics"))
        click(try XCTUnwrap(view(AccessibilityID.diagnosticsDone, in: diagnostics.contentView)))
        XCTAssertTrue(waitForNoSheet())

        // The configuration sheet, with the transparency section open.
        performMenuItem("edit", of: Fixtures.home)
        let configuration = try XCTUnwrap(waitForSheet(), "Edit… did not open a sheet")
        XCTAssertNotNil(view(AccessibilityID.configurationSheet, in: configuration.contentView))
        XCTAssertTrue(capture(configuration, as: "configuration"))
        let contents = try XCTUnwrap(view(AccessibilityID.configurationContents, in: configuration.contentView) as? NSButton)
        if contents.state == .off {
            click(contents)
            pump(0.3)
        }
        XCTAssertTrue(capture(configuration, as: "configuration-contents"))
        click(try XCTUnwrap(view(AccessibilityID.configurationDone, in: configuration.contentView)))
        XCTAssertTrue(waitForNoSheet())

        // Settings, section by section.
        XCTAssertTrue(pressKeyEquivalent(",", .command))
        let settings = try XCTUnwrap(waitForSettingsWindow(), "Settings did not open")
        let section = try XCTUnwrap(view(AccessibilityID.settingsSection, in: settings.contentView))
        for key in ["general", "menuBar", "softwareUpdate"] {
            click(try XCTUnwrap(view(AccessibilityID.settingsSidebarPrefix + key, in: settings.contentView)))
            XCTAssertTrue(waitUntil(timeout: 2) { section.accessibilityValue() as? String == key })
            XCTAssertTrue(capture(settings, as: "settings-\(key)"))
        }
        settings.close()

        // Empty, last: no profiles, the guidance.
        delegate.rehearsalReset()
        XCTAssertTrue(waitUntil(timeout: 3) { self.cards.isEmpty && self.view(AccessibilityID.guidance)?.isHidden == false })
        pump(0.3)
        XCTAssertTrue(capture(as: "empty"))
    }

    /// The same states at the window's minimum, 640 × 640 (D315): where German
    /// runs out of room first, and where the sheets must fit the window
    /// (D314). Settings has one size and is not repeated here.
    func testEveryRoutineStateIsCapturedAtTheMinimum() throws {
        resizeWindow(toContent: NSSize(width: 640, height: 640))
        defer { resizeWindow(toContent: defaultContentSize) }
        XCTAssertEqual(window.contentLayoutRect.width, 640, accuracy: 1, "the window did not take the minimum width")
        XCTAssertTrue(capture(as: "min-idle"))

        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.office))))
        XCTAssertTrue(waitUntil(timeout: 3) { self.state == "connecting" }, "region reads \(state)")
        pump(2.4)
        XCTAssertTrue(capture(as: "min-connecting"))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "connected" }, "region reads \(state)")
        XCTAssertTrue(capture(as: "min-connected"))
        click(try XCTUnwrap(view(AccessibilityID.promotedPrimary)))
        XCTAssertTrue(waitUntil(timeout: 5) { self.state == "idle" }, "region reads \(state)")
        pump(0.7)

        click(try XCTUnwrap(view(AccessibilityID.profileConnect, in: card(Fixtures.broken))))
        XCTAssertTrue(waitUntil(timeout: 8) { self.state == "failed" }, "region reads \(state)")
        XCTAssertTrue(capture(as: "min-failed"))
        click(try XCTUnwrap(view(AccessibilityID.promotedSecondary)))
        let diagnostics = try XCTUnwrap(waitForSheet(), "Show Details did not open a sheet")
        XCTAssertLessThanOrEqual(diagnostics.frame.width, window.frame.width, "the Diagnostics sheet is wider than the window")
        XCTAssertTrue(capture(diagnostics, as: "min-diagnostics"))
        click(try XCTUnwrap(view(AccessibilityID.diagnosticsDone, in: diagnostics.contentView)))
        XCTAssertTrue(waitForNoSheet())

        performMenuItem("edit", of: Fixtures.home)
        let configuration = try XCTUnwrap(waitForSheet(), "Edit… did not open a sheet")
        XCTAssertLessThanOrEqual(configuration.frame.width, window.frame.width, "the configuration sheet is wider than the window")
        XCTAssertTrue(capture(configuration, as: "min-configuration"))
        click(try XCTUnwrap(view(AccessibilityID.configurationDone, in: configuration.contentView)))
        XCTAssertTrue(waitForNoSheet())

        delegate.rehearsalReset()
        XCTAssertTrue(waitUntil(timeout: 3) { self.cards.isEmpty && self.view(AccessibilityID.guidance)?.isHidden == false })
        pump(0.3)
        XCTAssertTrue(capture(as: "min-empty"))
    }
}
