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
import Testing

/// What's New comes from the changelog, and the check's status is in our words.
struct UpdateCopyTests {
    let sample = """
        # Changelog

        Prose about conventions.

        ## Unreleased

        ### Added

        - First thing, with `code` and **bold**.
        - Second thing that
          wraps onto a second line.

        Some closing prose.

        ## 1.2.0 — 2026-10-01

        ### Fixed

        - A fix.
        """

    @Test func theVersionsSectionIsFoundAndFlattened() throws {
        let section = try #require(Changelog.section(for: "1.2.0", in: sample))
        #expect(section.version == "1.2.0")
        #expect(section.bullets == ["A fix."])
    }

    @Test func aDevelopmentBuildFallsBackToUnreleased() throws {
        let section = try #require(Changelog.section(for: "0.0.1", in: sample))
        #expect(section.version == nil)
        #expect(section.bullets == ["First thing, with code and bold.", "Second thing that wraps onto a second line."])
    }

    @Test func nothingMatchingIsNil() {
        #expect(Changelog.section(for: "9.9", in: "# Changelog\n\n## 1.0.0\n\n- x") == nil)
    }

    @Test func theStatusLinesAreWordsNotCodes() throws {
        let identifier = try Regex(#"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b"#)
        for text in [
            UpdateCopy.lastChecked(nil), UpdateCopy.lastChecked(Date(timeIntervalSince1970: 1_000_000)),
            UpdateCopy.checking, UpdateCopy.upToDate(version: "1.0"), UpdateCopy.available(version: "1.1"),
            UpdateCopy.noServer, UpdateCopy.unavailable, UpdateCopy.betaWarning,
        ] {
            #expect(!text.isEmpty && !text.contains(identifier) && !text.contains("Error"), "\(text)")
        }
        #expect(UpdateCopy.lastChecked(nil) == "Never checked for updates")
    }
}
