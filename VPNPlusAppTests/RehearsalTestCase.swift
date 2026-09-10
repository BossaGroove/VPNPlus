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
/// Remembers whether the app became active while a test ran. The owner may
/// switch between their own apps during a run; what must never happen is
/// *this* app becoming active, even for a moment.
final class ActivationWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var token: (any NSObjectProtocol)?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [self] _ in lock.withLock { flag = true } }
    }

    var activated: Bool { lock.withLock { flag } }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

@MainActor
class RehearsalTestCase: XCTestCase {
    private var watch: ActivationWatch?

    // Synchronous, on the main thread XCTest runs hosted tests on. With the
    // async variants, a failing assertion under `continueAfterFailure = false`
    // took the whole host down — run 5 (2026-09-10) restarted the app after
    // every failed test.
    nonisolated override func setUp() {
        // XCTest calls these from a nonisolated context on the main thread;
        // the test case is main-actor state, so the hop is asserted, not awaited.
        nonisolated(unsafe) let this = self
        MainActor.assumeIsolated { this.setUpOnMain() }
    }

    nonisolated override func tearDown() {
        nonisolated(unsafe) let this = self
        MainActor.assumeIsolated { this.tearDownOnMain() }
    }

    private func setUpOnMain() {
        do {
            continueAfterFailure = false
            XCTAssertTrue(Rehearsal.isActive, "the host was not launched with -UITesting; use the VPNPlusAppTests scheme")
            XCTAssertFalse(NSApp.isActive, "the host is active before the test began")
            delegate.rehearsalReset()
            XCTAssertTrue(waitUntil(timeout: 2) { self.cards.isEmpty && self.window.attachedSheet == nil }, "the app did not reset")
            // The region slides out over the grid for ~400 ms after a reset
            // from a connected state; a click during the slide lands on the
            // fading region, not the card beneath (run 5).
            _ = waitUntil(timeout: 2) { self.state == "idle" }
            pump(0.7)
            watch = ActivationWatch()
            do {
                try prepare()
            } catch {
                XCTFail("preparing the test failed: \(error)")
            }
        }
    }

    /// What a test class needs on screen before each test — fixtures, a
    /// connection — run **after** the reset. (XCTest runs `setUpWithError`
    /// before `setUp`, so a subclass importing there had its cards removed
    /// by the reset that followed; run 7, 2026-09-10.)
    func prepare() throws {}

    private func tearDownOnMain() {
        watch?.stop()
        XCTAssertFalse(watch?.activated ?? true, "the harness activated the app during the test — it must never take focus")
        XCTAssertFalse(NSApp.isActive, "the harness left the app active — it must never take focus")
        // The outside view. Once (M8.5 step 1, German run) the workspace named
        // this process frontmost while the app was not active and had never
        // become active — the two in-process signals are the guard; this is
        // noted, and fails only when the app agrees it is active.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmost == ProcessInfo.processInfo.processIdentifier {
            print("GUARD NOTE: the workspace names the host frontmost after the test; NSApp.isActive = \(NSApp.isActive)")
            XCTAssertFalse(NSApp.isActive, "the host is frontmost and active after the test — the harness took focus")
        }
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
        layoutNow()
        XCTAssertTrue(
            waitUntil(timeout: 5) { self.cards.count == profiles.count },
            "expected \(profiles.count) cards, found \(cards.count): \(cardLabels); store holds \(delegate.catalogue.profiles.map(\.title))")
    }

    var cardLabels: [String] { cards.map { ($0.accessibilityLabel() ?? "?") + "=" + (($0.accessibilityValue() as? String) ?? "?") } }

    /// Auto Layout is lazy: a card exists the instant it is imported, with a
    /// zero frame until the next layout pass — so a click "at its centre"
    /// landed at the grid's origin, and a hit test there found the grid (runs
    /// 7–8, 2026-09-10). Every measurement and every click runs layout first.
    func layoutNow() {
        for candidate in [window] + window.sheets {
            candidate.contentView?.layoutSubtreeIfNeeded()
            candidate.layoutIfNeeded()
        }
        pump(0.05)
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

    /// The promoted region's state name: `idle`, `connecting`, `connected`, `failed`, …
    var state: String {
        (view(AccessibilityID.promotedRegion)?.accessibilityValue() as? String) ?? ""
    }

    // MARK: Driving

    /// A click at the view's centre. First the question every click asks —
    /// what a click *there* would land on — asserted, because that is where
    /// D259 lived. Then the delivery: a control takes its own click
    /// (`performClick`; a switch flips and sends its action); anything else
    /// takes the mouse pair through the window. The pair reached the cards'
    /// Connect buttons in every run and never a sheet's controls or the
    /// region's Disconnect (sweep run 2, 2026-09-10), all enabled, visible and
    /// correctly hit-tested — cause not established, so the harness does not
    /// depend on it for controls.
    func click(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        layoutNow()
        XCTAssertFalse(view.frame.isEmpty, "\(type(of: view)) has no size: it is not laid out or not on screen", file: file, line: line)
        // What a person does before clicking something below the fold: the
        // configuration sheet caps its scroll view, and a control under the
        // cap is clipped, so a hit test there finds nothing (run 9).
        view.scrollToVisible(view.bounds)
        layoutNow()
        // The question every click asks first — what a click *there* lands on —
        // because that is where D259 lived. Asked for up to a second: a
        // constraint animation moves the *model* frames while it runs, so a
        // hit test during the region's 400 ms slide-in lands on the moving
        // stack (M8.5 step 1, 2026-09-10) — a person waits for the movement
        // to stop, and so does this.
        var landing = hit(at: view)
        func landed() -> Bool { landing === view || landing.map { $0.isDescendant(of: view) } == true }
        _ = waitUntil(timeout: 1.0) {
            self.layoutNow()
            landing = self.hit(at: view)
            return landed()
        }
        if !landed() {
            var chain: [String] = []
            var v: NSView? = view
            while let current = v {
                chain.append("\(type(of: current)) frame \(current.frame) hidden \(current.isHidden) alpha \(current.alphaValue)")
                v = current.superview
            }
            let siblings = (landing?.subviews ?? []).map { "\(type(of: $0)) \($0.frame) hidden \($0.isHidden)" }
            print("CLICK MISS\n\(hitReport(for: view))\nchain:\n\(chain.joined(separator: "\n"))\nlanding's subviews:\n\(siblings.joined(separator: "\n"))\nEND CLICK MISS")
        }
        XCTAssertTrue(
            landed(),
            "a click at the view's centre lands on \(landing.map { String(describing: type(of: $0)) } ?? "nothing"), not on \(type(of: view))",
            file: file, line: line)
        if view is NSControl {
            clickControlDirectly(view, file: file, line: line)
        } else {
            clickThroughWindow(view)
        }
    }

    /// The control's own click: `performClick` for a button, and for a switch
    /// the state flipped and the action sent, which is what its click does.
    func clickControlDirectly(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        switch view {
        case let toggle as NSSwitch:
            toggle.state = toggle.state == .on ? .off : .on
            if let action = toggle.action { NSApp.sendAction(action, to: toggle.target, from: toggle) }
        case let control as NSControl:
            control.performClick(nil)
        default:
            XCTFail("no direct click for \(type(of: view))", file: file, line: line)
        }
        pump(0.1)
    }

    /// The same pair **posted** to the app's queue instead. Kept for the
    /// record: for an inactive app the pair goes nowhere (runs 1–4), so
    /// nothing uses it.
    func postClick(_ view: NSView) {
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

    /// The same pair, delivered the other way round: the mouse-up is posted to
    /// the queue first, then the mouse-down is handed straight to the window,
    /// whose `sendEvent → hitTest → control` runs the button's tracking loop,
    /// which finds the waiting mouse-up. This skips whatever `NSApplication`
    /// does with a click meant for an inactive app, which is where run 3
    /// (2026-09-10) showed a posted pair going nowhere.
    func clickThroughWindow(_ view: NSView) {
        guard let target = view.window else { return XCTFail("the view is not in a window") }
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: centre, modifierFlags: [], timestamp: time,
                windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: centre, modifierFlags: [], timestamp: time + 0.05,
                windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { return XCTFail("could not make a mouse event") }
        NSApp.postEvent(up, atStart: true)
        target.sendEvent(down)
        pump(0.1)
    }

    /// What a click at the view's centre would land on — D259's question,
    /// asked of the window directly. `hitTest` takes a point in the
    /// receiver's *superview's* coordinates, so the window point is converted
    /// into the content view's superview (the window's frame view) first.
    func hit(at view: NSView) -> NSView? {
        guard let content = view.window?.contentView, let frame = content.superview else { return nil }
        let inWindow = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return content.hitTest(frame.convert(inWindow, from: nil))
    }

    /// Every way of asking, for the spike to compare against what a delivered
    /// click actually reached (runs 4–8: the helper said "grid", the click
    /// said "button").
    func hitReport(for view: NSView) -> String {
        guard let target = view.window, let content = target.contentView else { return "no window" }
        let centre = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inWindow = view.convert(centre, to: nil)
        func name(_ v: NSView?) -> String { v.map { String(describing: type(of: $0)) } ?? "nil" }
        var lines = [
            "view \(type(of: view)) bounds \(view.bounds) frame \(view.frame) flippedSuper \(view.superview?.isFlipped ?? false)",
            "inWindow \(inWindow); window frame \(target.frame); content frame \(content.frame) flipped \(content.isFlipped)",
            "content.hitTest(inWindow) → \(name(content.hitTest(inWindow)))",
            "content.hitTest(content.convert(inWindow, from: nil)) → \(name(content.hitTest(content.convert(inWindow, from: nil))))",
        ]
        if let frame = content.superview {
            lines.append("frame.hitTest(inWindow) → \(name(frame.hitTest(inWindow)))")
            lines.append("content.hitTest(frame.convert(inWindow, from: nil)) → \(name(content.hitTest(frame.convert(inWindow, from: nil))))")
        }
        if let parent = view.superview {
            let inParentSuper = parent.superview.map { $0.convert(inWindow, from: nil) } ?? inWindow
            lines.append("parent(\(type(of: parent))).hitTest(point in its superview) → \(name(parent.hitTest(inParentSuper)))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sheets and menus

    /// The card's menu item with this key (`card.menu.edit`, …), performed
    /// through the menu — the same target and action a click on it fires.
    func performMenuItem(_ key: String, of name: String) {
        guard let card = card(name) as? ProfileCardView else { return XCTFail("no card called \(name); cards: \(cardLabels)") }
        let menu = card.menuForTesting()
        guard let index = menu.items.firstIndex(where: { $0.accessibilityIdentifier() == AccessibilityID.cardMenuPrefix + key })
        else { return XCTFail("no \(key) item in the card menu") }
        menu.performActionForItem(at: index)
        pump(0.1)
    }

    /// The sheet attached to the main window, once it is there.
    func waitForSheet(timeout: TimeInterval = 5) -> NSWindow? {
        _ = waitUntil(timeout: timeout) { self.window.attachedSheet != nil }
        return window.attachedSheet
    }

    func waitForNoSheet(timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout: timeout) { self.window.attachedSheet == nil }
    }

    // MARK: Menus and windows

    /// A key equivalent, offered to the main menu the way AppKit offers one
    /// before any view sees it — ⌘, for Settings, ⌘D for Diagnostics.
    @discardableResult
    func pressKeyEquivalent(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 0)
        else { return false }
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        pump(0.1)
        return handled
    }

    /// The Settings window, once it is on screen.
    func waitForSettingsWindow(timeout: TimeInterval = 5) -> NSWindow? {
        var found: NSWindow?
        _ = waitUntil(timeout: timeout) {
            found = NSApp.windows.first { $0.accessibilityIdentifier() == AccessibilityID.settingsWindow && $0.isVisible }
            return found != nil
        }
        return found
    }

    /// The cards from left to right, by title.
    var cardOrder: [String] {
        layoutNow()
        return cards.sorted { $0.frame.minX < $1.frame.minX }.compactMap { $0.accessibilityLabel() }
    }

    // MARK: The window's size

    /// The main window at a content size, in-process — no System Events. The
    /// window clamps to its own minimum, so asking for less than 640 × 640
    /// yields 640 × 640 (D315).
    func resizeWindow(toContent size: NSSize) {
        window.setContentSize(size)
        layoutNow()
        pump(0.3)
    }

    var defaultContentSize: NSSize { NSSize(width: 760, height: 560) }

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
        // The backing store lags the model by a display cycle: a capture taken
        // the instant the state changed showed the frame before it (run 3).
        pump(0.3)
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
