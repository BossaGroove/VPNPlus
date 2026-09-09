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
import UserNotifications
import VPNPlusCore

/// Posts D76's notification: the tunnel ended in Failed while the user was
/// not looking at the window. See `FailureNotice` for the rule; this is the
/// part that talks to Notification Center.
///
/// **Permission is asked at the first connect**, not at launch. That is the
/// moment the user is present and has just asked for the thing that could
/// later fail out of their sight, so the system's prompt has a reason they
/// can see; a prompt at launch is one more dialog before the app has done
/// anything. Asked once — macOS remembers the answer and will not re-prompt
/// (D143: the setting is the system's).
///
/// **Cleared when it stops being true.** A delivered "lost the connection"
/// is removed when that profile connects again, so Notification Center does
/// not keep announcing a failure the user has already fixed.
@MainActor
final class FailureNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "notify")

    private let tunnel: TunnelController
    private let catalogue: ProfileCatalogue
    private let isLooking: () -> Bool
    private let onOpen: (UUID) -> Void
    private var previous = Connection.disconnected
    /// Failures older than this were restored, not suffered (D288).
    private let launchedAt = Date()
    private var asked = false
    private var center: UNUserNotificationCenter? {
        // The framework needs a bundle to talk for; a test host has none.
        (Bundle.main.bundleIdentifier == nil || Rehearsal.isActive) ? nil : UNUserNotificationCenter.current()
    }

    init(
        tunnel: TunnelController, catalogue: ProfileCatalogue,
        isLooking: @escaping () -> Bool, onOpen: @escaping (UUID) -> Void
    ) {
        self.tunnel = tunnel
        self.catalogue = catalogue
        self.isLooking = isLooking
        self.onOpen = onOpen
        super.init()
        center?.delegate = self
        tunnel.observe { [weak self] connection, _ in
            MainActor.assumeIsolated { self?.observe(connection) }
        }
    }

    private func observe(_ connection: Connection) {
        defer { previous = connection }
        switch connection {
        case .connecting:
            askOnce()
        case .connected(let session):
            center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: session.profile)])
        default:
            break
        }
        if let notice = FailureNotice.owed(
            from: previous, to: connection, looking: isLooking(), since: launchedAt,
            name: { [catalogue] id in
                catalogue.profiles.first { $0.id == id }.map(catalogue.title(of:)) ?? String(localized: "your VPN")
            })
        {
            post(notice)
        }
    }

    func askOnce() {
        guard !asked, let center else { return }
        asked = true
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                Self.log.info("notifications: \(settings.authorizationStatus.rawValue, privacy: .public)")
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Self.log.error("notification permission: \(error.localizedDescription, privacy: .public)")
                } else {
                    Self.log.notice("notification permission \(granted ? "granted" : "declined", privacy: .public)")
                }
            }
        }
    }

    func post(_ notice: FailureNotice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.profile.uuidString
        content.userInfo = ["profile": notice.profile.uuidString]
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: notice.profile), content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Self.log.error("notification: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.log.notice("notified: \(notice.title, privacy: .public)")
            }
        }
    }

    private static func identifier(for profile: UUID) -> String { "failure.\(profile.uuidString)" }

    // MARK: - UNUserNotificationCenterDelegate

    /// Clicking the notification opens the window, where the Failed state
    /// already is (D50). Nothing else is ever done from a notification.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let profile = (response.notification.request.content.userInfo["profile"] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run {
            if let profile { onOpen(profile) }
        }
    }

    /// Delivered while the app is in front after all (the user came back
    /// between the failure and the post): the window says it, and a banner on
    /// top of it would say it twice.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { isLooking() ? [] : [.banner, .list, .sound] }
    }
}
