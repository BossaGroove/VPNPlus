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
        return Redactor.scrub(lines.joined(separator: "\n"))
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
