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
import Sparkle

/// Sparkle, held at arm's length (A15's Software Update block).
///
/// The framework runs the update itself — download, verification, the
/// install-on-quit dialogue — in its own idiom. What this wraps is the
/// **check**: started from our button, reported in our words (`UpdateCopy`),
/// with the outcome left on the card rather than in an alert, and the two
/// switches and the beta channel bound to the updater's own settings.
///
/// A build without a public key cannot verify updates, and Sparkle refuses to
/// start; that is `unavailable`, said as a sentence. The key is M9's.
@MainActor
final class Updater: NSObject {
    private nonisolated static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "update")
    nonisolated static let includesBetasKey = "update.includeBetas"

    enum State: Equatable {
        case unavailable
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String)
        case failed
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?

    /// Starts the updater. Failure is a state, not an alert.
    func start() {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            self.userDriver = driver
            state = .idle
            Self.log.notice("updater started; feed \(updater.feedURL?.absoluteString ?? "none", privacy: .public)")
        } catch {
            Self.log.error("updater refused to start: \(error.localizedDescription, privacy: .public)")
            state = .unavailable
        }
    }

    var isAvailable: Bool { updater != nil }
    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }
    var includesBetas: Bool {
        get { Preferences.defaults.bool(forKey: Self.includesBetasKey) }
        set { Preferences.defaults.set(newValue, forKey: Self.includesBetasKey) }
    }

    /// *Check for Updates Now*: a silent check, reported on the card.
    func checkNow() {
        guard let updater else {
            state = .unavailable
            return
        }
        guard !updater.sessionInProgress else { return }
        state = .checking
        updater.checkForUpdateInformation()
    }

    /// An update was found by the silent check: hand over to Sparkle's own
    /// flow, which shows the release notes and installs.
    func install() {
        updater?.checkForUpdates()
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Preferences.defaults.bool(forKey: Updater.includesBetasKey) ? ["beta"] : []
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { self.state = .available(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        MainActor.assumeIsolated { self.state = .upToDate(version: version) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let ns = error as NSError
        Updater.log.error("update check failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
        MainActor.assumeIsolated {
            // A user-initiated check that found nothing reports through
            // `updaterDidNotFindUpdate`; anything that aborts is the server
            // not answering, or answering with nothing we can use.
            if case .checking = self.state { self.state = .failed }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            if case .checking = self.state { self.state = error == nil ? .idle : .failed }
        }
    }
}
