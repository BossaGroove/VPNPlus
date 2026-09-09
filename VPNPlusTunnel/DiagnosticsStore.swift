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
import VPNPlusCore
import os

/// Where the record lives between provider processes.
///
/// **The extension keeps it, not the app.** A9's capture requirement 5 says a
/// failure must be examinable later, and the case that matters most is the one
/// D75 exists for: a connection started from System Settings with the app not
/// running. The app cannot record what it did not see.
///
/// One file per profile, so *cleared when the profile is removed* (D122) is
/// one unlink, and so two profiles' records cannot be confused. Root-owned and
/// root-readable only: the app never opens these files, it asks the provider
/// (`ProviderRequest.diagnostics`), which is also the boundary where the reply
/// is typed rather than parsed.
///
/// **On D202** — *no feature leaves persistent system state that a later
/// process must undo.* This leaves files, and answers it two ways: removing a
/// profile removes its file, and removing the last one removes the directory.
/// What is left behind is data the user asked to keep, never state anything
/// has to repair.
struct DiagnosticsStore {
    private static let directory = URL(
        fileURLWithPath: "/Library/Application Support/com.bossagroove.VPNPlus/Diagnostics",
        isDirectory: true)
    private static let log = Logger(
        subsystem: "com.bossagroove.VPNPlus", category: "diagnostics")

    /// The all-zero id an attempt that named no profile is filed under, so a
    /// record is never simply dropped.
    static let unidentified = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func file(for profile: Profile.ID?) -> URL {
        Self.directory.appendingPathComponent("\((profile ?? Self.unidentified).uuidString).json")
    }

    /// What is on disk, or an empty record. A file this build cannot read is
    /// an empty record too: a diagnostics log is never worth failing a
    /// connection over.
    func load(for profile: Profile.ID?) -> DiagnosticsLog {
        guard let data = try? Data(contentsOf: file(for: profile)),
            let log = try? JSONDecoder().decode(DiagnosticsLog.self, from: data),
            log.version == DiagnosticsLog.currentVersion
        else { return DiagnosticsLog(profile: profile) }
        return log
    }

    func save(_ record: DiagnosticsLog, for profile: Profile.ID?) {
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(record)
            let url = file(for: profile)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Degraded, not broken: the record stays in memory for as long as
            // this process lives, and the tunnel is unaffected.
            Self.log.error(
                "could not keep the record: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// D122: goes with the profile's credentials and its last-good record.
    func remove(for profile: Profile.ID) {
        try? FileManager.default.removeItem(at: file(for: profile))
        // The last one takes the directory with it.
        if let left = try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path),
            left.isEmpty
        {
            try? FileManager.default.removeItem(at: Self.directory)
        }
    }
}
