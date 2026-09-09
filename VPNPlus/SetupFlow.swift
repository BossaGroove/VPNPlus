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
import OSLog
import VPNPlusCore

/// A5's setup sequence as one object: **explain, ask, wait, resume** — and
/// the connect intent held across all of it (D60).
///
/// **Deferred to the first Connect** (D59). At launch the flow only *asks
/// macOS what is already installed*; if the extension is approved it is
/// re-activated silently (an update replaces in place, C2a) and the user
/// sees nothing. If it is not, nothing happens until they press Connect,
/// and then the first thing they see is our explanation, not the OS prompt
/// (D65). Approval landing resumes the connect they asked for; they never
/// click Connect twice.
///
/// **Re-approval is remembered locally** (D66): macOS cannot tell a first
/// run from an approval that went away, so the flow writes *this Mac
/// approved us once* the first time it lands and reads it back when approval
/// is missing again.
@MainActor
final class SetupFlow {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "setup")
    static let approvedOnceKey = "setup.approvedOnce"

    let installer: ExtensionInstaller
    var onChange: (() -> Void)?
    /// Approval landed with a connect held: this is where it resumes.
    var onReady: ((Profile) -> Void)?

    /// The profile the user asked for before setup got in the way.
    private(set) var pending: Profile?
    private var explaining = false

    init(installer: ExtensionInstaller) {
        self.installer = installer
        installer.onChange = { [weak self] status in self?.installerChanged(status) }
    }

    var isReady: Bool { installer.status == .active }

    /// Before a connect (D309): confirm the extension is enabled right now,
    /// then either proceed or hold the intent and explain.
    func confirm(for profile: Profile, then proceed: @escaping () -> Void) {
        installer.confirmEnabled { [weak self] enabled in
            guard let self else { return }
            if enabled {
                proceed()
            } else {
                Self.log.notice("setup: the extension is not enabled; explaining instead of connecting")
                self.begin(for: profile)
            }
        }
    }

    var approvedOnce: Bool {
        get { Preferences.defaults.bool(forKey: Self.approvedOnceKey) }
        set { Preferences.defaults.set(newValue, forKey: Self.approvedOnceKey) }
    }

    /// What the window derives from (D93).
    var state: SetupState {
        if explaining { return .explaining(again: approvedOnce) }
        switch installer.status {
        case .idle, .probing, .active, .requesting: return .ready
        case .needsApproval: return .waitingForApproval
        case .failed(let reason): return .blocked(reason)
        }
    }

    /// Launch: find out, without asking anyone anything.
    func probe() { installer.probe() }

    /// Connect was pressed and setup is not done: hold the intent and explain.
    func begin(for profile: Profile) {
        pending = profile
        explaining = true
        Self.log.notice("setup: explaining before the prompt (again: \(self.approvedOnce, privacy: .public))")
        onChange?()
    }

    /// *Continue*: now macOS may ask.
    func continueSetup() {
        explaining = false
        installer.activate()
        onChange?()
    }

    /// *Not now*: Blocked, with the intent dropped — they said not now.
    func notNow() {
        explaining = false
        pending = nil
        installer.decline()
        onChange?()
    }

    /// Blocked's *Continue setup*: back to the explanation, not straight to
    /// the prompt (D69 via D65).
    func resume() {
        explaining = true
        onChange?()
    }

    /// The pane the approval lives on. A0 C2 found the OS's own prompt merely
    /// dismissible, leaving "little chance that the user will be able to find
    /// the correct place" — so the window takes them there.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installerChanged(_ status: ExtensionInstaller.Status) {
        switch status {
        case .needsApproval:
            // "System Settings should be open" — make it so (D153).
            openSystemSettings()
        case .active:
            if !approvedOnce { approvedOnce = true }
            if let profile = pending {
                pending = nil
                Self.log.notice("setup: approval landed; resuming the connect the user asked for")
                onChange?()
                onReady?(profile)
                return
            }
        default:
            break
        }
        onChange?()
    }
}
