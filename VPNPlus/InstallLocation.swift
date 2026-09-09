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

    /// Whether the app can put itself in `/Applications` from here: the
    /// folder must be writable, and if a copy is already there it must be
    /// replaceable. A read-only disk image is fine — the move is a copy.
    static var canMove: Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: "/Applications") else { return false }
        let target = destination.path
        return !fm.fileExists(atPath: target) || fm.isWritableFile(atPath: target)
    }

    static var destination: URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    }

    /// **Move to Applications** (D62): copy this bundle to `/Applications`,
    /// start the copy once this process has gone, and quit. A copy already
    /// there goes to the Trash first rather than being overwritten in place —
    /// a half-replaced bundle is worse than either whole one. From a disk
    /// image the "move" is a copy and the image is left as it was.
    ///
    /// Launch Services will not start a second instance of a bundle that is
    /// running, so the relaunch waits for this process to exit: a detached
    /// shell polls the pid, then opens the new copy.
    static func moveAndRelaunch() throws {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let target = destination
        if fm.fileExists(atPath: target.path) {
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: target)
        // A *move*, where the source is somewhere a move makes sense: the
        // Downloads copy goes to the Trash so there are not two of us. A disk
        // image is left alone — it is read-only, and it is theirs.
        if !source.path.hasPrefix("/Volumes/"), fm.isWritableFile(atPath: source.deletingLastPathComponent().path) {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }

        try Relaunch.schedule(opening: target)
    }

    /// Plain language, a cause and a next action — never a code (D2).
    var explanation: String? {
        guard case .elsewhere(let url) = self else { return nil }
        return """
            VPN Plus needs to be in your Applications folder before it can set             up its network component. It is currently in             \(url.deletingLastPathComponent().path).
            """
    }
}
