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
import Foundation
import VPNPlusCore

/// **UI testing runs the app in rehearsal** (M8.4): the same window, cards,
/// sheets and state machine, with a stand-in for everything that reaches
/// outside the process — the tunnel, the extension, the Keychain, the
/// preferences the owner's copy has written, notifications, Sparkle.
///
/// The test harness launches the app with `-UITesting` and `-UITestFixtures <dir>`:
/// every `.ovpn` in that directory is imported at launch through the ordinary
/// import path, and a file written there afterwards is imported when it lands,
/// which is how a test reaches the replace report without a file picker.
///
/// Nothing here runs in an ordinary launch. `isActive` is read from the
/// process arguments, never from UserDefaults, so the owner's preferences
/// are not consulted before the suite has replaced them.
enum Rehearsal {
    static let isActive: Bool = ProcessInfo.processInfo.arguments.contains("-UITesting")

    /// Where the fixtures are, when the test supplied them.
    static let fixtures: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UITestFixtures"),
            arguments.indices.contains(index + 1)
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    /// A suite of its own, emptied at every launch, so a run starts from the
    /// first-launch state and leaves the owner's settings as they were.
    // UserDefaults is thread-safe; the class predates Sendable.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        let name = "com.bossagroove.VPNPlus.rehearsal"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    /// Profiles in memory and in the suite: nothing reaches the Keychain.
    static let store = StoredProfileStore(
        secrets: MemorySecretStore(), metadata: DefaultsMetadataStore(defaults: defaults))

    /// **A rehearsal never takes the owner's focus.** Every place the app
    /// would activate itself goes through here, and in rehearsal it does
    /// nothing; likewise a window that would come to the front and become
    /// key is ordered to the *back* instead, on screen but behind everything
    /// (owner, 2026-09-10). The suite asserts the frontmost app never changes.
    @MainActor
    static func bringToFront() {
        if !isActive { NSApp.activate(ignoringOtherApps: true) }
    }

    @MainActor
    static func show(_ window: NSWindow?, sender: Any? = nil) {
        if isActive {
            window?.orderBack(sender)
        } else {
            window?.makeKeyAndOrderFront(sender)
        }
    }

    /// No Dock tile and no place in the app switcher while rehearsing.
    static var activationPolicy: NSApplication.ActivationPolicy { isActive ? .accessory : .regular }
}

/// The preferences the app writes, routed through one place so a rehearsal
/// can point them at its own suite (D317). The language list is not here: it
/// has to live in the app's own domain to take effect, and no test changes it.
enum Preferences {
    static var defaults: UserDefaults { Rehearsal.isActive ? Rehearsal.defaults : .standard }
}

/// A secret store that forgets everything at quit.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func secret(for account: String) throws -> Data? {
        lock.withLock { secrets[account] }
    }

    func setSecret(_ data: Data, for account: String) throws {
        lock.withLock { secrets[account] = data }
    }

    func removeSecret(for account: String) throws {
        _ = lock.withLock { secrets.removeValue(forKey: account) }
    }
}

/// The tunnel's stand-in: walks the real state machine on a timer, so every
/// surface renders what a connection renders, with no server and no
/// extension. A profile whose server is in the reserved `.invalid` domain
/// fails while contacting it; every other one connects in three and a half
/// seconds — slower than a real one, so a phase name has time to appear
/// (D235's two-second reveal).
@MainActor
final class RehearsalTunnel {
    var shouldFail: (Profile.ID) -> Bool = { _ in false }
    private var pending: [DispatchWorkItem] = []

    func start(_ id: Profile.ID, drive: @escaping @MainActor (TunnelEvent) -> Void) {
        cancel()
        drive(.connect(id))
        let fails = shouldFail(id)
        after(0.2) { drive(.entered(OpenVPNPhase.findingServer.asPhase)) }
        after(0.8) { drive(.entered(OpenVPNPhase.contactingServer.asPhase)) }
        if fails {
            after(2.6) {
                drive(
                    .ended(
                        FailureDetail(
                            .serverUnreachable, attempts: 1,
                            detail: "rehearsal: the server does not exist")))
            }
        } else {
            after(2.2) { drive(.entered(OpenVPNPhase.signingIn.asPhase)) }
            after(2.8) { drive(.entered(OpenVPNPhase.waitingForSettings.asPhase)) }
            after(3.2) { drive(.entered(OpenVPNPhase.settingUp.asPhase)) }
            after(3.5) { drive(.established) }
        }
    }

    /// What the system does for a real teardown: the provider goes, then the
    /// status is *observed* disconnected — which is the event a switch waits
    /// for, so the second half of a switch starts from the same place.
    func stop(drive: @escaping @MainActor (TunnelEvent) -> Void) {
        cancel()
        drive(.disconnect)
        after(0.4) { drive(.observed(.disconnected, profile: nil)) }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancel() {
        for item in pending { item.cancel() }
        pending.removeAll()
    }
}

/// The fixtures: imported at launch in name order, then watched.
@MainActor
final class RehearsalFixtures {
    private let directory: URL
    private let importFile: (URL) -> Void
    private let afterImport: () -> Void
    private var seen: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(directory: URL, importFile: @escaping (URL) -> Void, afterImport: @escaping () -> Void) {
        self.directory = directory
        self.importFile = importFile
        self.afterImport = afterImport
    }

    func begin() {
        importNew()
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            // Let the writer finish: a test writes the whole file in one call,
            // but the directory event can arrive before the data has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self?.importNew() }
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    private func importNew() {
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "ovpn" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var imported = false
        for file in files {
            let stamp =
                file.lastPathComponent + "@"
                + String(
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate?.timeIntervalSince1970) ?? 0)
            guard !seen.contains(stamp) else { continue }
            seen.insert(stamp)
            importFile(file)
            imported = true
        }
        if imported { afterImport() }
    }
}
