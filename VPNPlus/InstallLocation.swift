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

/// feature-spec 1.6 / D62 — macOS refuses to activate a system extension
/// contained in an app outside `/Applications`. Checked at launch so the user
/// never meets it as a mysterious activation failure at connect time.
enum InstallLocation {
    case correct
    case elsewhere(URL)

    static var current: InstallLocation {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent().standardizedFileURL
        return parent.path == "/Applications" ? .correct : .elsewhere(bundle)
    }

    var isCorrect: Bool {
        if case .correct = self { return true }
        return false
    }

    /// Plain language, a cause and a next action — never a code (D2).
    var explanation: String? {
        guard case .elsewhere(let url) = self else { return nil }
        return """
            VPN Plus needs to be in your Applications folder before it can set             up its network component. It is currently in             \(url.deletingLastPathComponent().path).
            """
    }
}
