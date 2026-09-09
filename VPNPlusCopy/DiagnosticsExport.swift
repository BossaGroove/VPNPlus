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

/// *Copy diagnostics* and *Export…* — the record as text for somebody else
/// to read (A14 §3, D87).
///
/// **Both layers** (D138): our phrases, each followed by the engine's
/// identifier in brackets, and the engine's own lines beneath them — the
/// part a support engineer reads and the screen never shows. Then the
/// comparison and the message, so the text stands on its own in an email.
///
/// **Scrubbed twice.** Every line entered the record through the redactor
/// (D199); the whole text goes through it again here, because a `.ovpn` can
/// carry an inline private key and one leak is unrecoverable. The footer says
/// so — somebody sending this to their IT department deserves to know what
/// they are sending.
enum DiagnosticsExport {
    static func text(
        profileName: String,
        record: DiagnosticsLog,
        comparison: NetworkComparison?,
        message: FailureMessage?,
        at now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append(String(localized: "VPN Plus diagnostics — \(profileName)"))
        lines.append(DateFormatter.localizedString(from: now, dateStyle: .long, timeStyle: .short))
        lines.append("")

        if let message {
            lines.append(message.title)
            lines.append(message.body)
            if !message.causes.isEmpty {
                lines.append(String(localized: "Common causes"))
                lines.append(contentsOf: message.causes.map { "  · " + $0 })
            }
            if let changed = message.whatChanged {
                lines.append(String(localized: "What changed since it last worked"))
                lines.append("  " + changed)
            }
            lines.append("")
        }

        if let comparison {
            lines.append(String(localized: "What changed"))
            for row in DiagnosticsCopy.comparison(comparison) {
                let mark = row.changed ? " *" : ""
                lines.append("  \(row.label): \(row.lastGood) → \(row.now)\(mark)")
            }
            lines.append("")
        }

        if record.attempts.isEmpty {
            lines.append(String(localized: "No connection attempts recorded yet."))
        }
        for attempt in record.attempts {
            lines.append(DiagnosticsCopy.header(attempt))
            if let facts = attempt.facts {
                let randomised: String =
                    switch facts.addressIsRandomised {
                    case true?: String(localized: "yes")
                    case false?: String(localized: "no")
                    case nil: String(localized: "unknown")
                    }
                lines.append(
                    "  " + String(localized: "Network: \(DiagnosticsCopy.words(facts.interfaceKind)), gateway \(facts.gateway ?? String(localized: "none")), address randomised: \(randomised)")
                )
            }
            for entry in attempt.entries {
                let time = Self.time(entry.at)
                switch entry.kind {
                case .engine(let text):
                    lines.append("  \(time)    › \(text)")
                case .note(let text):
                    lines.append("  \(time)    • \(text)")
                default:
                    guard let phrase = DiagnosticsCopy.phrase(entry) else { continue }
                    let identifier = entry.identifier.map { "  [\($0)]" } ?? ""
                    lines.append("  \(time)  \(phrase)\(identifier)")
                }
            }
            lines.append("")
        }

        lines.append(String(localized: "Passwords and keys are removed."))
        // The second pass (D87). The first was at the sink; this is the one
        // the footer promises.
        return ascii(Redactor.scrub(lines.joined(separator: "\n")))
    }

    /// The file the export is offered as: the profile, and when, in UTC, in
    /// ISO 8601's basic form — `VPN Plus diagnostics - Work -
    /// 20260909T034110Z.txt` (owner, 2026-09-09; no colons, which macOS
    /// shows as `/`). The profile's name goes in **as the user wrote it** —
    /// the owner's call: a name in 日本語 stays legible in the Finder rather
    /// than becoming underscores. Only `/`, which no filename can hold, is
    /// replaced.
    static func filename(profileName: String, at now: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = profileName.replacingOccurrences(of: "/", with: "-")
        return "VPN Plus diagnostics - \(name) - \(stamp.string(from: now)).txt"
    }

    /// **ASCII only** (D291). The export is read by tools as often as by
    /// people — pasted into tickets, grepped, diffed — and typography is where
    /// those trip: an em dash that is not a hyphen, quotes that are not
    /// quotes. Punctuation is mapped to its plain equivalent; anything else
    /// outside ASCII becomes `unknown`.
    static func ascii(_ text: String, unknown: String = "?") -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if let plain = Self.plain[scalar] {
                out += plain
            } else {
                out += unknown
            }
        }
        return out
    }

    private static let plain: [Unicode.Scalar: String] = [
        "\u{2014}": "-",  // em dash
        "\u{2013}": "-",  // en dash
        "\u{2012}": "-",  // figure dash
        "\u{2010}": "-",  // hyphen
        "\u{2011}": "-",  // non-breaking hyphen
        "\u{2212}": "-",  // minus
        "\u{2026}": "...",
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
        "\u{2192}": "->",
        "\u{2190}": "<-",
        "\u{00B7}": "-",  // middle dot, the header's separator
        "\u{2022}": "*",  // bullet
        "\u{2023}": "*",
        "\u{203A}": ">",  // the engine-line marker
        "\u{2039}": "<",
        "\u{00A0}": " ",  // no-break space
        "\u{2009}": " ", "\u{200A}": " ", "\u{2002}": " ", "\u{2003}": " ",
        "\u{00D7}": "x",
        "\u{00B0}": " deg",
        "\u{00AB}": "\"", "\u{00BB}": "\"",
    ]

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
