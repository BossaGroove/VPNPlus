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

/// What happened, attempt by attempt — the record the Diagnostics sheet reads
/// (A14, and the Diagnostics artboard's timeline).
///
/// **Typed, not phrased.** The artboard shows sentences — *"Waiting for
/// connection settings"*, *"Gave up waiting for connection settings after 20
/// seconds"* — and this carries neither. The extension writes the record and
/// the extension is **not localized**: sentences belong where the String
/// Catalog is, which is the app (the same reasoning as D221 and
/// `PhaseLabels`). So an entry is a kind and its numbers, and the app says it
/// in the user's language. A departure from M6.2's task row, which asked for
/// the phrase here; the row was written before the localization boundary was
/// looked at.
///
/// Two layers in one stream (D138): entries the sheet renders as our own
/// prose, and the engine's own lines, which the **export** carries and the
/// screen never does. There is one stream because there is one redacted
/// stream and no raw copy anywhere (feature-spec 4.9).
///
/// **Nothing here is a secret.** Every line reaching it has passed the
/// redactor first (D199); this type is the reason that filter exists.
public struct DiagnosticsLog: Codable, Sendable, Equatable {
    /// Bumped when the shape changes: it crosses between two
    /// independently-updated binaries, and it is read back from disk written
    /// by an older one.
    public static let currentVersion = 1
    public var version = DiagnosticsLog.currentVersion
    /// Whose record this is. Nil only for an attempt that named no profile,
    /// which cannot happen since the id travels with the start (D267).
    public var profile: Profile.ID?
    public private(set) var attempts: [DiagnosticsAttempt] = []

    public init(profile: Profile.ID? = nil, attempts: [DiagnosticsAttempt] = []) {
        self.profile = profile
        self.attempts = attempts
    }

    // MARK: - Writing

    /// Starts an attempt, and drops the oldest if there are now too many.
    ///
    /// `recovery` is the model's count (D86): 0 for an attempt the user asked
    /// for, 1… for automatic recovery. The attempt's own number counts from 1
    /// within what is retained, because that is what the sheet's header shows.
    public mutating func begin(
        recovery: Int, at when: Date, facts: NetworkFacts? = nil
    ) {
        var attempt = DiagnosticsAttempt(
            number: (attempts.last?.number ?? 0) + 1, recovery: recovery, startedAt: when,
            facts: facts)
        attempt.entries = [DiagnosticsEntry(at: when, kind: .attemptBegan)]
        attempts.append(attempt)
        if attempts.count > DiagnosticsRetention.attempts {
            attempts.removeFirst(attempts.count - DiagnosticsRetention.attempts)
        }
    }

    /// Adds an entry to the attempt in progress.
    ///
    /// An entry arriving with no attempt open belongs to the one it came out
    /// of — a session that drops was established by the last attempt — so it
    /// appends there rather than being lost. With no attempts at all, one is
    /// opened, because a record that drops its first line is worse than a
    /// record whose first attempt has no beginning.
    public mutating func add(_ kind: DiagnosticsEntry.Kind, identifier: String? = nil, at when: Date) {
        if attempts.isEmpty { begin(recovery: 0, at: when) }
        let index = attempts.count - 1
        guard attempts[index].entries.count < DiagnosticsRetention.entriesPerAttempt else {
            // Bounded, and it says so rather than silently stopping. Once.
            if attempts[index].entries.count == DiagnosticsRetention.entriesPerAttempt {
                attempts[index].entries.append(
                    DiagnosticsEntry(at: when, kind: .truncated))
            }
            return
        }
        attempts[index].entries.append(DiagnosticsEntry(at: when, kind: kind, identifier: identifier))
    }

    /// Closes the attempt in progress. A second call is ignored: the engine
    /// can report a fatal event and then exit, and both would end it.
    public mutating func finish(_ outcome: DiagnosticsAttempt.Outcome, at when: Date) {
        guard let index = attempts.indices.last, attempts[index].outcome == nil else { return }
        attempts[index].outcome = outcome
        attempts[index].endedAt = when
    }

    /// Whether an attempt is open — the provider's test for "does this belong
    /// to something already running".
    public var isAttemptOpen: Bool { attempts.last?.outcome == nil && !attempts.isEmpty }

    // MARK: - Reading

    /// The most recent attempt, which is what a failure message's details
    /// open onto.
    public var latest: DiagnosticsAttempt? { attempts.last }

    /// Only what the sheet renders (D138): our own entries, not the engine's
    /// own prose. `problemsOnly` is the artboard's `All ▾` filter.
    public func forScreen(problemsOnly: Bool = false) -> [DiagnosticsAttempt] {
        attempts.map { attempt in
            var copy = attempt
            copy.entries = attempt.entries.filter {
                $0.kind.isForScreen && (!problemsOnly || $0.kind.isProblem)
            }
            return copy
        }
    }
}

/// One attempt, with what came of it.
public struct DiagnosticsAttempt: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case connected
        case failed(TunnelFailure)
        /// The user stopped it, or a switch replaced it.
        case cancelled
    }

    /// 1-based, within what is retained — the number the sheet shows.
    public var number: Int
    /// The model's recovery count (D86). 0 for an attempt somebody asked for.
    public var recovery: Int
    public var startedAt: Date
    public var endedAt: Date?
    /// Nil while it is still running.
    public var outcome: Outcome?
    public var entries: [DiagnosticsEntry] = []
    /// What the network looked like when this attempt started, read **before**
    /// the tunnel changed any routing (D201) — which is the only moment the
    /// answer describes the physical network. A9's capture requirement 2.
    public var facts: NetworkFacts?

    public init(
        number: Int, recovery: Int, startedAt: Date, endedAt: Date? = nil,
        outcome: Outcome? = nil, entries: [DiagnosticsEntry] = [], facts: NetworkFacts? = nil
    ) {
        self.number = number
        self.recovery = recovery
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.entries = entries
        self.facts = facts
    }

    /// How long it ran, when it is over.
    public var duration: Duration? {
        guard let endedAt else { return nil }
        return .seconds(endedAt.timeIntervalSince(startedAt))
    }
}

/// One line of the record.
public struct DiagnosticsEntry: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case attemptBegan
        /// A phase, by id. The app has the words (`PhaseLabels`).
        case phase(String)
        case connected
        /// A phase deadline fired: the artboard's *"Gave up waiting for
        /// connection settings after 20 seconds"*.
        case gaveUp(phase: String, seconds: Int)
        /// The attempt ended badly, with what the provider knew — the same
        /// numbers the failure message carries (feature-spec 4.10).
        case failed(TunnelFailure, waited: Int?, requests: Int?)
        /// Recovery, counted and bounded and about to wait (D86).
        case tryingAgain(attempt: Int, of: Int, seconds: Int)
        case networkLost
        case networkReturned
        /// The artboard's *"Restored DNS and routes"*.
        case teardownRestored
        case disconnected
        /// The engine's own prose, redacted. **Export only** (D138).
        case engine(String)
        /// Ours, redacted, for the export: something worth keeping that has no
        /// kind of its own.
        case note(String)
        /// The entry cap was reached, said out loud rather than silently.
        case truncated

        /// Whether the sheet shows it. The engine's vocabulary ends at the
        /// export (feature-spec 4.1, D105, D138).
        public var isForScreen: Bool {
            switch self {
            case .engine, .note: false
            default: true
            }
        }

        /// The artboard's *Problems only* filter.
        public var isProblem: Bool {
            switch self {
            case .gaveUp, .failed, .networkLost: true
            default: false
            }
        }
    }

    public var at: Date
    public var kind: Kind
    /// The engine's own identifier for the event this came from — `GET_CONFIG`,
    /// `AUTH_FAILED`. It travels with the entry and appears in the **export**,
    /// where a support engineer reads it. On screen, never (D138).
    public var identifier: String?

    public init(at: Date, kind: Kind, identifier: String? = nil) {
        self.at = at
        self.kind = kind
        self.identifier = identifier
    }
}

/// Retention, as constants and never as settings.
///
/// A2 found Tunnelblick's *"Maximum log display size: 100 KB"* in its
/// Preferences — a display buffer, in kilobytes, as a user-facing choice.
/// That is where 321 preferences begin. Nobody is asked about these (D140).
public enum DiagnosticsRetention {
    /// Per profile. Enough to hold a whole five-attempt recovery ladder with
    /// the attempt before it, which is exactly the comparison a stall needs.
    public static let attempts = 10
    /// Per attempt. A connection logs about fifty lines, so this bounds a
    /// pathological one without truncating a real one.
    public static let entriesPerAttempt = 400
}
