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

/// What the user is told when a profile will not import, and what they can do
/// about it (A10). One message per outcome, written to A10's rules: no code, no
/// engine identifier, the profile named, second person, no blame, and never the
/// word "Error" — the title says what did not happen.
///
/// **Shaped by the ImportError artboard** (M5.10): the body states the fact,
/// the button does the one thing that can be done about it, and the
/// alternative is a footnote under the button rather than a second sentence
/// competing with the first.
///
/// Localized as it lands rather than retrofitted, as the project requires.
struct ImportMessage {
    let title: String
    let body: String
    /// The alternative, under the buttons.
    var footnote: String? = nil
    /// Names in the body: the profile file, set in bold, and the file it
    /// refers to, set as code.
    var bold: [String] = []
    var code: [String] = []
    /// Whether something needs the user (a warning sign) or this is news of
    /// something already done.
    var warns: Bool = true
    /// The button that does something about it, when there is one.
    let action: Action?

    enum Action: Equatable {
        /// Find the file the profile refers to (A10 M16).
        case chooseFile(named: String)
        /// Import it with the listed directives set aside (D155, D187).
        case importAnyway(setting: [String])
        /// A list one click behind a count (D187): the link that unfolds it,
        /// and the lines. It carries its own lines, so no caller has to work
        /// out separately what the details of a message it was handed are.
        case showDetails(link: String, lines: [String])
    }

    static func forOutcome(_ outcome: ProfileImport.Outcome, filename: String) -> ImportMessage? {
        switch outcome {
        case .ready(_, _, let setAside):
            guard !setAside.isEmpty else { return nil }
            // 2.8 and D187: a count, with the list one click behind it. Plural
            // rules belong to the catalog, not to string surgery here.
            return ImportMessage(
                title: String(localized: "Imported \(filename)"),
                body: String(localized: """
                    VPN Plus doesn't use \(setAside.directives.count) of the settings in this profile. \
                    It will still connect the way the profile describes.
                    """),
                bold: [filename],
                warns: false,
                action: .showDetails(
                    link: String(localized: "Show which"), lines: setAside.directives))

        case .missingFile(let named):
            return ImportMessage(
                title: String(localized: "This profile needs a file that isn't here"),
                body: String(localized: "\(filename) refers to \(named), which wasn't alongside it."),
                footnote: String(localized: """
                    Or ask whoever gave you this profile for a version with the certificate included.
                    """),
                bold: [filename],
                code: [named],
                action: .chooseFile(named: named))

        case .unrecognised(let directives):
            return ImportMessage(
                title: String(localized: "VPN Plus doesn't recognise everything in this profile"),
                body: String(localized: """
                    \(filename) uses \(directives.count) settings VPN Plus doesn't know about. \
                    You can import it with those set aside, and it will connect without them.
                    """),
                footnote: String(localized: "Or ask whoever gave it to you whether they matter."),
                bold: [filename],
                action: .importAnyway(setting: directives))

        case .refused(.certificateInSeparateFile):
            // 2.10: named cause and next action, never reported as corruption.
            return ImportMessage(
                title: String(localized: "This profile keeps its certificate somewhere VPN Plus can't read"),
                body: String(localized: """
                    \(filename) expects its certificate and key in a separate file that \
                    VPN Plus doesn't open yet.
                    """),
                footnote: String(localized: """
                    Ask whoever gave you this profile for a version with the certificate included.
                    """),
                bold: [filename],
                action: nil)

        case .refused(.serverSuppliesTheSettings):
            // 2.11: the user has the wrong file, said plainly.
            return ImportMessage(
                title: String(localized: "This profile isn't complete"),
                body: String(localized: """
                    \(filename) expects to be given the rest of its settings by your \
                    server after you sign in, which VPN Plus doesn't do yet.
                    """),
                footnote: String(localized: """
                    Ask whoever gave it to you for a profile that already includes the server's settings.
                    """),
                bold: [filename],
                action: nil)

        case .refused(.unsupportedRequirement(let detail)):
            return ImportMessage(
                title: String(localized: "This profile needs something VPN Plus doesn't support"),
                body: String(localized: """
                    \(filename) asks for a feature that isn't available. It's worth \
                    reporting — we'd like to know which profiles need it.
                    """),
                bold: [filename],
                // The engine's own words, behind the link, for the report the
                // sentence above asks for. Nothing else knows them (D240).
                action: detail.isEmpty
                    ? nil
                    : .showDetails(link: String(localized: "Show details"), lines: [detail]))

        case .refused(.unreadable):
            return ImportMessage(
                title: String(localized: "This file isn't a profile VPN Plus can read"),
                body: String(localized: """
                    \(filename) couldn't be read as a VPN profile. If it came in an \
                    archive or an email, check that it arrived complete.
                    """),
                bold: [filename],
                action: nil)
        }
    }
}
