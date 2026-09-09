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

/// The words for the record (A14, the Diagnostics artboard's timeline).
///
/// The extension writes a typed entry and this says it — because the
/// extension is not localized and the String Catalog is here (the same
/// reasoning as `PhaseLabels` and D221). **The engine's vocabulary ends at
/// the export**: nothing this returns contains an event name, and nothing a
/// user reads ever will (feature-spec 4.1, D105, D138).
///
/// M6.5 builds the sheet from these; M6.2 needed them to prove the record
/// arrives in words rather than in codes.
enum DiagnosticsCopy {
    /// One timeline entry, or nil for the entries the screen never shows.
    static func phrase(_ entry: DiagnosticsEntry) -> String? {
        switch entry.kind {
        case .attemptBegan:
            return String(localized: "Started connecting")
        case .phase(let id):
            return TunnelPhase(id: id, deadline: .zero).label
        case .connected:
            return String(localized: "Connected")
        case .dropped:
            return String(localized: "The connection dropped")
        case .gaveUp(let id, let seconds):
            // The artboard's own sentence: "Gave up waiting for connection
            // settings after 20 seconds".
            let step = TunnelPhase(id: id, deadline: .zero).label.lowercased()
            return String(localized: "Gave up \(step) after \(seconds) seconds")
        case .failed(let reason, let waited, let requests):
            var text = shortReason(reason)
            if let requests, let waited {
                text += " "
                text += String(localized: "(asked \(requests) times over \(waited) seconds)")
            } else if let waited {
                text += " "
                text += String(localized: "(after \(waited) seconds)")
            }
            return text
        case .tryingAgain(let attempt, let total, let seconds):
            return String(
                localized: "Trying again in \(seconds) seconds — attempt \(attempt) of \(total)")
        case .networkLost:
            return String(localized: "This Mac lost its network")
        case .networkReturned:
            return String(localized: "The network came back")
        case .teardownRestored:
            // The artboard's line, and the answer to J11 for whoever reads
            // this afterwards.
            return String(localized: "Restored DNS and routes")
        case .disconnected:
            return String(localized: "Disconnected")
        case .truncated:
            return String(localized: "Further lines aren't kept")
        case .engine, .note:
            // The export's layer, not the screen's (D138).
            return nil
        }
    }

    /// The attempt's own header: *"Attempt 2 · 14:32 · succeeded"*.
    static func header(_ attempt: DiagnosticsAttempt, at now: Date = Date()) -> String {
        let time = DateFormatter.localizedString(
            from: attempt.startedAt, dateStyle: .none, timeStyle: .short)
        var text = String(localized: "Attempt \(attempt.number) · \(time)")
        switch attempt.outcome {
        case .connected:
            text += " · " + String(localized: "succeeded")
        case .failed:
            text += " · " + String(localized: "failed")
        case .cancelled:
            text += " · " + String(localized: "stopped")
        case .retried:
            text += " · " + String(localized: "retried")
        case nil:
            text += " · " + String(localized: "running")
        }
        return text
    }

    // MARK: - What changed

    /// One row of the artboard's LAST GOOD / NOW table.
    struct ComparisonRow {
        let label: String
        let lastGood: String
        let now: String
        /// Shown in bold, as the artboard has it.
        let changed: Bool
    }

    /// The five rows, always all five: an unchanged environment is a fact
    /// worth seeing, and *"nothing has changed since this last worked"* is the
    /// sentence that points at the server rather than at the Mac (A7).
    static func comparison(_ comparison: NetworkComparison) -> [ComparisonRow] {
        NetworkComparison.Row.allCases.map { row in
            ComparisonRow(
                label: label(row),
                lastGood: cell(row, comparison.lastGood, in: comparison, isNow: false),
                now: cell(row, comparison.now, in: comparison, isNow: true),
                changed: comparison.changed(row))
        }
    }

    private static func label(_ row: NetworkComparison.Row) -> String {
        switch row {
        case .when: String(localized: "When")
        case .interface: String(localized: "Interface")
        case .network: String(localized: "Network")
        case .addressRandomised: String(localized: "Address randomised by macOS")
        case .profile: String(localized: "Profile")
        }
    }

    private static let missing = "—"

    private static func cell(
        _ row: NetworkComparison.Row, _ facts: NetworkFacts?, in comparison: NetworkComparison,
        isNow: Bool
    ) -> String {
        guard let facts else {
            // Never connected, so there is nothing on the left to compare —
            // said rather than left blank.
            return isNow ? missing : String(localized: "Never connected")
        }
        switch row {
        case .when:
            // The right-hand column is *now*; a timestamp there would be
            // noise, and the artboard leaves it empty.
            guard !isNow else { return missing }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: facts.at, relativeTo: Date())
        case .interface:
            return words(facts.interfaceKind)
        case .network:
            // The left-hand column identifies the network by its router; the
            // right-hand one is **relational**, because without Location
            // Services we cannot name a network and would not ask to (D90).
            if isNow {
                switch comparison.isSameNetwork {
                case true: return String(localized: "the same network")
                case false: return String(localized: "a different network")
                case nil: return router(facts)
                }
            }
            return router(facts)
        case .addressRandomised:
            switch facts.addressIsRandomised {
            case true: return String(localized: "Yes")
            case false: return String(localized: "No")
            case nil: return String(localized: "Not recorded")
            }
        case .profile:
            guard comparison.profileReplaced else { return String(localized: "unchanged") }
            return isNow ? String(localized: "replaced since then") : String(localized: "unchanged")
        }
    }

    static func words(_ kind: NetworkFacts.InterfaceKind) -> String {
        switch kind {
        // The kind, never `en0` (D3).
        case .wiFi: String(localized: "Wi-Fi")
        case .ethernet: String(localized: "Ethernet")
        case .other: String(localized: "Another connection")
        case .none: String(localized: "No network")
        }
    }

    /// *"gateway a8:…:fd"* — the artboard's own shape. Shortened on purpose:
    /// it is enough to tell two networks apart, and a screenshot of it
    /// identifies the router less than the whole address would. The export
    /// carries the full value.
    private static func router(_ facts: NetworkFacts) -> String {
        if let mac = facts.gatewayHardwareAddress {
            let parts = mac.split(separator: ":")
            if let first = parts.first, let last = parts.last, parts.count > 2 {
                return String(localized: "gateway \(first)…\(last)")
            }
            return String(localized: "gateway \(mac)")
        }
        if let gateway = facts.gateway { return String(localized: "gateway \(gateway)") }
        return missing
    }

    /// A reason in a handful of words, for a timeline rather than a message.
    /// The message itself is `FailureCopy`'s, and says what to do about it.
    private static func shortReason(_ reason: TunnelFailure) -> String {
        switch reason {
        case .authenticationFailed: String(localized: "The server refused the sign-in")
        case .credentialsUnavailable: String(localized: "Nothing to sign in with")
        case .configurationMissing: String(localized: "No settings for this profile")
        case .settingsNeverSent: String(localized: "The server sent no connection settings")
        case .serverUnreachable: String(localized: "The server didn't respond")
        case .serverNotFound: String(localized: "The server's address didn't resolve")
        case .certificateRejected: String(localized: "The server's certificate wasn't accepted")
        case .certificateExpired: String(localized: "The server's certificate has expired")
        case .clockWrong: String(localized: "This Mac's clock looks wrong")
        case .noSecureConnection: String(localized: "No agreed secure connection")
        case .serverEnded: String(localized: "The server ended it")
        case .setupFailed: String(localized: "The settings couldn't be applied")
        case .noNetwork: String(localized: "No network")
        case .recoveryGaveUp: String(localized: "Gave up reconnecting")
        case .keychainDenied: String(localized: "The Keychain refused")
        case .idleTimeout: String(localized: "Idle too long")
        case .certificateUnusable: String(localized: "The certificate couldn't be used")
        case .unsupportedRequirement: String(localized: "Needs something unsupported")
        case .anotherTunnelActive: String(localized: "Another VPN had the network")
        case .timedOut: String(localized: "Ran out of time")
        case .unknown: String(localized: "Stopped, with no reason given")
        }
    }
}
