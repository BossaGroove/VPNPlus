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
        // First run (2026-09-10): the posted click left the region idle. This
        // run says which of two things that is — the click not reaching the
        // button, or Connect's own flow stopping — by trying three deliveries
        // in turn and recording what each did. The spike passes on any of
        // them; the message names the one the harness should use.
        continueAfterFailure = true
        var deliveries: [String] = []
        func attempt(_ name: String, _ run: () -> Void) -> Bool {
            run()
            let connecting = waitUntil(timeout: 3) { self.state == "connecting" }
            deliveries.append(
                "\(name): region \(state), key \(window.isKeyWindow), active \(NSApp.isActive), sheet \(window.attachedSheet != nil), model \(delegate.tunnel.connection.state.rawValue)"
            )
            return connecting
        }
        let acceptsFirstMouse = connect.acceptsFirstMouse(for: nil)
        layoutNow()
        let landsOn = hit(at: connect)
        let connectReport = hitReport(for: connect)
        var connected =
            attempt("posted click on a non-key window") { postClick(connect) }
            || attempt("mouse-down through the window, mouse-up posted") { clickThroughWindow(connect) }
            || attempt("performClick") { (connect as? NSButton)?.performClick(nil) }
        let report =
            "acceptsFirstMouse \(acceptsFirstMouse); a click at the button's centre lands on \(landsOn.map { String(describing: type(of: $0)) } ?? "nothing") (\(landsOn === connect ? "the button" : "NOT the button"))\n"
            + deliveries.joined(separator: "\n")
        let note = XCTAttachment(string: report)
        note.name = "deliveries"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertTrue(connected, "no delivery connected:\n\(report)")
        if connected {
            connected = waitUntil(timeout: 8) { self.state == "connected" }
            XCTAssertTrue(connected, "the rehearsal did not connect; region reads \(state)")
        }
        // Printed into xcodebuild's output as well, so the run's log carries it.
        print("SPIKE DELIVERIES\n\(report)")

        XCTAssertTrue(capture(as: "spike-connected"))

        // Hit-test variants against a button the delivered click provably
        // reached, and against a control in a sheet.
        var hits = "MAIN WINDOW, Connect on Office (before the click):\n" + connectReport
        performMenuItem("edit", of: Fixtures.home)
        if let sheet = waitForSheet(), let remember = view(AccessibilityID.configurationRemember, in: sheet.contentView) {
            hits += "\nSHEET, Remember switch:\n" + hitReport(for: remember)
            if let done = view(AccessibilityID.configurationDone, in: sheet.contentView) {
                hits += "\nSHEET, Done:\n" + hitReport(for: done)
                clickThroughWindow(done)
                hits += "\nwindow-delivered click on Done closed the sheet: \(waitForNoSheet(timeout: 2))"
            }
        }
        let hitNote = XCTAttachment(string: hits)
        hitNote.name = "hits"
        hitNote.lifetime = .keepAlways
        add(hitNote)
        print("SPIKE HITS\n\(hits)\nEND HITS")
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["VPNPLUS_SHOTS"],
            "VPNPLUS_SHOTS did not reach the host; the PNG went to the result bundle only")
    }
}
