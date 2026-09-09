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
import ServiceManagement

/// The settings the app actually has (A15, D142): each one a decision two
/// legitimate users would make differently, stored where the system stores
/// such things, and applied live where the system allows it.
@MainActor
enum AppSettings {
    /// Posted after any change, so the surfaces that read a setting re-read it.
    static let didChange = Notification.Name("com.bossagroove.VPNPlus.settings.didChange")

    // MARK: Language (D145)

    /// The six languages, and *System*. Each named in itself, the way macOS
    /// names languages in its own picker, so a user who has landed in the
    /// wrong one can still find their own.
    enum Language: String, CaseIterable {
        case system = ""
        case english = "en"
        case japanese = "ja"
        case traditionalChinese = "zh-Hant"
        case simplifiedChinese = "zh-Hans"
        case german = "de"
        case french = "fr"

        var title: String {
            switch self {
            case .system: String(localized: "System")
            case .english: "English"
            case .japanese: "日本語"
            case .traditionalChinese: "繁體中文"
            case .simplifiedChinese: "简体中文"
            case .german: "Deutsch"
            case .french: "Français"
            }
        }
    }

    /// Per-app language override, which is what macOS's own per-app language
    /// setting writes; ours is the same key, so the two never disagree (D143).
    static var language: Language {
        get {
            // The app's **own** domain, not `array(forKey:)`: standard defaults
            // inherit the global language list, so without this a Mac set to
            // Japanese read as an override the user never made (found on the
            // owner's Mac, 2026-09-09).
            guard let identifier = Bundle.main.bundleIdentifier,
                let own = UserDefaults.standard.persistentDomain(forName: identifier),
                let codes = own["AppleLanguages"] as? [String],
                let first = codes.first
            else { return .system }
            return Language.allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Launch at login

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item. Throws the system's error;
    /// the caller puts the switch back and says so.
    static func setLaunchesAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Dock icon

    static let showsDockIconKey = "dock.showIcon"

    static var showsDockIcon: Bool {
        get { UserDefaults.standard.object(forKey: showsDockIconKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showsDockIconKey)
            applyDockPolicy()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Live: the icon appears or disappears as the switch moves. An accessory
    /// app keeps its windows and its status item and loses the Dock tile and
    /// the menu bar's left half — which is what someone who lives in the menu
    /// bar asked for.
    static func applyDockPolicy() {
        let wanted: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: Menu bar

    static var showsProfileNameInMenuBar: Bool {
        get { UserDefaults.standard.bool(forKey: StatusItemController.showProfileNameKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: StatusItemController.showProfileNameKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Version

    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
