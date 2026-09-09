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

import Foundation

/// The Software Update card's words (A15). Never Sparkle's: the framework's
/// own alerts stay for the update itself, where they are the system's
/// idiom, but the status a *check* leaves behind is ours to word (4.1).
public enum UpdateCopy {
    /// *Last checked today at 09:14*, or never.
    public static func lastChecked(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return String(localized: "Never checked for updates") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(localized: "Last checked \(formatter.string(from: date))")
    }

    public static var checking: String { String(localized: "Checking for updates…") }
    public static func upToDate(version: String) -> String {
        String(localized: "VPN Plus \(version) is the latest version.")
    }
    public static func available(version: String) -> String {
        String(localized: "VPN Plus \(version) is available.")
    }
    /// The update server did not answer, or answered with nothing usable.
    public static var noServer: String {
        String(localized: "No update server answered. Try again later.")
    }
    /// This build cannot check at all — no key to verify updates with.
    public static var unavailable: String {
        String(localized: "This build can't check for updates.")
    }
    public static var betaWarning: String {
        String(localized: "Beta versions may be less stable than regular releases.")
    }
}
