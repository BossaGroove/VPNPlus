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

/// Starts this app again once this process has gone.
///
/// Launch Services will not start a second instance of a bundle that is
/// already running, so a relaunch cannot simply `open` itself: a detached
/// shell waits for our pid to disappear, then opens the bundle — the moved
/// copy after *Move to Applications* (D62), or this one after a language
/// change (D145). The caller terminates the app after scheduling.
enum Relaunch {
    static func schedule(opening bundle: URL = Bundle.main.bundleURL) throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        let quoted = bundle.path.replacingOccurrences(of: "'", with: "'\\''")
        shell.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open '\(quoted)'",
        ]
        try shell.run()
    }
}
