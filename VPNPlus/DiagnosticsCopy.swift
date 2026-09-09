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
        case nil:
            text += " · " + String(localized: "running")
        }
        return text
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
