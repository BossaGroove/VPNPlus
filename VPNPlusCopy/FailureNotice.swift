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

/// What a notification says, and when one is owed (D76, D51).
///
/// **Unrecovered outcomes, not transient events.** A drop that recovers by
/// itself is the icon's flicker and nothing more; a connect the user started
/// and watched succeed is the icon's job. What earns a push is the one thing
/// that requires the user and happens where they cannot see it: the tunnel
/// ended in **Failed** while the window was not in front of them. That is the
/// ladder giving up after its five attempts (M14), a server ending a session
/// that was up (M9), and equally a first connect that failed a minute after
/// they switched to something else — silent on screen *and* silent off it is
/// exactly the incumbents' failure mode (A1, D16), and the Failed state needs
/// them whichever way it was reached.
///
/// **State-labelled, never a spinner.** The title is the failure's own (A10),
/// the body its first sentence — what happened — because Notification Center
/// truncates and the second sentence is the window's to say. Nothing is posted
/// for Connecting or Reconnecting: a notification about progress is noise, and
/// noise is how notifications get switched off.
public struct FailureNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var profile: UUID

    /// The notice owed by a transition, or nil when none is.
    ///
    /// `looking` is whether the user can see the window right now — the app
    /// active and the window on screen. The same record twice (a re-render, a
    /// second observation of the same failure) posts once. A failure that
    /// happened **before `since`** — the app's launch — is not news: the app
    /// restores the last failure from disk on launch so the window can show
    /// it (D50), and re-announcing it re-notified a failure the user had
    /// already seen and acted on (2026-09-09, D288).
    public static func owed(
        from previous: Connection, to next: Connection, looking: Bool, since: Date = .distantPast,
        name: (UUID) -> String
    ) -> FailureNotice? {
        guard case .failed(let record) = next, !looking, record.at >= since else { return nil }
        if case .failed(let before) = previous, before == record { return nil }
        return notice(for: record, name: name(record.profile))
    }

    public static func notice(for record: FailureRecord, name: String) -> FailureNotice {
        FailureNotice(
            title: FailureCopy.title(record, name: name),
            body: firstSentence(of: FailureCopy.body(record, name: name)),
            profile: record.profile)
    }

    /// Up to the first full stop that ends a sentence. A body with one sentence
    /// is returned whole; a stop inside a quoted server reason does not end
    /// ours, and the closing quote stays with it.
    static func firstSentence(of text: String) -> String {
        var quoted = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            switch character {
            case "“": quoted += 1
            case "”": quoted = max(0, quoted - 1)
            case "." where quoted == 0:
                if next == text.endIndex || text[next] == " " { return String(text[..<next]) }
            case "." where quoted == 1 && next < text.endIndex && text[next] == "”":
                // The stop that ends the quote ends the sentence with it.
                let close = text.index(after: next)
                if close == text.endIndex || text[close] == " " { return String(text[..<close]) }
            default: break
            }
            index = next
        }
        return text
    }
}
