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

/// The harness (M8.4, step 2's design): tests run **inside the app**, which the
/// scheme launched in rehearsal, and drive its own window with events posted
/// to its own queue. Nothing here can reach the owner's input or focus — and
/// every test proves it: the frontmost application is recorded before and
/// checked after, and the app must never be active.
@MainActor
class RehearsalTestCase: XCTestCase {
    private var frontmostBefore: pid_t?

    override func setUp() async throws {
        continueAfterFailure = false
        XCTAssertTrue(Rehearsal.isActive, "the host was not launched with -UITesting; use the VPNPlusAppTests scheme")
        frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertNotEqual(frontmostBefore, ProcessInfo.processInfo.processIdentifier, "the host is frontmost before the test began")
    }

    override func tearDown() async throws {
        XCTAssertFalse(NSApp.isActive, "the harness activated the app — it must never take focus")
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostBefore,
            "the frontmost application changed during the test — the harness took focus")
    }

    // MARK: The app

    var delegate: AppDelegate { NSApp.delegate as! AppDelegate }
    var controller: MainWindowController { delegate.windowController! }
    var window: NSWindow { controller.window! }

    /// Imports the fixtures through the ordinary import path and marks them
    /// signed in, then waits for their cards.
    func importFixtures(_ profiles: [(name: String, text: String)] = Fixtures.profiles) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPNPlusAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for profile in profiles {
            let url = directory.appendingPathComponent("\(profile.name).ovpn")
            try profile.text.write(to: url, atomically: true, encoding: .utf8)
            controller.importProfile(at: url)
        }
        delegate.markFixturesSignedIn()
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.cards.count == profiles.count },
            "expected \(profiles.count) cards, found \(cards.count)")
    }

    // MARK: Finding

    /// Every view in the window and its sheets with this accessibility identifier.
    func views(_ identifier: String, in root: NSView? = nil) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.accessibilityIdentifier() == identifier { found.append(view) }
            for child in view.subviews { walk(child) }
        }
        if let root {
            walk(root)
        } else {
            for candidate in [window] + (window.sheets) {
                if let content = candidate.contentView { walk(content) }
            }
        }
        return found
    }

    func view(_ identifier: String, in root: NSView? = nil) -> NSView? {
        views(identifier, in: root).first
    }

    var cards: [NSView] { views(AccessibilityID.profileCard) }

    func card(_ name: String) -> NSView? {
        cards.first { $0.accessibilityLabel() == name }
    }

    /// The promoted region's state name: `idle`, `active:connecting`, …
    var state: String {
        (view(AccessibilityID.promotedRegion)?.accessibilityValue() as? String) ?? ""
    }

    // MARK: Driving

    /// A click at the view's centre, as a mouse-down/mouse-up pair **posted to
    /// the app's own event queue** for this window. It travels
    /// `NSWindow.sendEvent → hitTest → the control`, which is where D259
    /// lived, and never reaches the window server.
    func click(_ view: NSView) {
        guard let target = view.window else { return XCTFail("the view is not in a window") }
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        for (kind, delay) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)] {
            guard
                let event = NSEvent.mouseEvent(
                    with: kind, location: centre, modifierFlags: [], timestamp: time + delay,
                    windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: kind == .leftMouseDown ? 1 : 0)
            else { return XCTFail("could not make a mouse event") }
            NSApp.postEvent(event, atStart: false)
        }
        pump(0.1)
    }

    // MARK: Waiting

    /// Runs the main run loop until the condition holds or the time is up, so
    /// the rehearsal tunnel's timers and AppKit's layout get their turns.
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Capturing

    /// The window's own backing store, by window id, from inside the process:
    /// whole even when it is behind everything, and no permission needed for
    /// one's own windows. Attached to the result, and written to
    /// `$VPNPLUS_SHOTS/<language>/<name>.png` when the scheme supplied a path.
    @discardableResult
    func capture(_ target: NSWindow? = nil, as name: String) -> Bool {
        let target = target ?? window
        guard
            let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(target.windowNumber),
                [.boundsIgnoreFraming, .bestResolution])
        else {
            XCTFail("could not capture window \(target.windowNumber)")
            return false
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode the capture")
            return false
        }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let root = ProcessInfo.processInfo.environment["VPNPLUS_SHOTS"], !root.isEmpty else { return true }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write the capture: \(error.localizedDescription)")
            return false
        }
        return true
    }

    /// The language the host is running in — `xcodebuild test -testLanguage`.
    var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
}
