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

/// *What's New*, read from the bundled `CHANGELOG.md` (A15: read, not set,
/// so it sits last). The changelog is written for users — the header of the
/// file says so — which is what lets the same text serve the release notes,
/// Sparkle's update alert and this card.
public struct Changelog: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        /// The heading's version, or nil for *Unreleased*.
        public var version: String?
        /// Bullet points, one string each, with the markdown taken off.
        public var bullets: [String]
    }

    /// The section for `version`, else the *Unreleased* section a development
    /// build carries, else nil.
    public static func section(for version: String, in markdown: String) -> Section? {
        let sections = parse(markdown)
        return sections.first { $0.version == version } ?? sections.first { $0.version == nil }
    }

    static func parse(_ markdown: String) -> [Section] {
        var sections: [Section] = []
        var current: Section?
        var bullet: String?
        func flushBullet() {
            if let text = bullet, !text.isEmpty { current?.bullets.append(plain(text)) }
            bullet = nil
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") {
                flushBullet()
                if let section = current { sections.append(section) }
                let heading = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let version = heading.lowercased() == "unreleased"
                    ? nil : heading.components(separatedBy: " ").first.map { $0.trimmingCharacters(in: .whitespaces) }
                current = Section(version: version, bullets: [])
            } else if current == nil {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushBullet()
                bullet = String(line.dropFirst(2))
            } else if bullet != nil, !line.isEmpty, !line.hasPrefix("#") {
                // A wrapped bullet continues on the next line.
                bullet! += " " + line
            } else {
                flushBullet()
            }
        }
        flushBullet()
        if let section = current { sections.append(section) }
        return sections
    }

    /// Enough markdown removed for a label: emphasis and code marks.
    static func plain(_ text: String) -> String {
        var out = text
        for mark in ["**", "`", "_"] { out = out.replacingOccurrences(of: mark, with: "") }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
