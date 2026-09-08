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

/// A9's engine events and stalls, mapped to A10's one-code-per-message
/// vocabulary (D103). **The one place an OpenVPN event name meets a failure
/// code** — the core never sees the names (D183), and the app never sees them
/// either (D105); the provider reads this table and the app words the result.
///
/// The engine's own severity is data, not a decision (D98): `NEED_CREDS`,
/// `DYNAMIC_CHALLENGE`, `PROXY_NEED_CREDS` and `SESSION_EXPIRED` sit in its
/// fatal block and are prompts, which the provider handles before it gets
/// here. Everything the table does not name is `unknown`, honestly (D85).
extension TunnelFailure {
    /// The message for a fatal engine event, by A10's grouping.
    static func forEvent(_ name: String) -> TunnelFailure {
        switch name {
        case "AUTH_FAILED", "SESSION_EXPIRED":
            .authenticationFailed
        case "CONNECTION_TIMEOUT", "TRANSPORT_ERROR", "NETWORK_EOF_ERROR",
            "NETWORK_RECV_ERROR", "NETWORK_SEND_ERROR", "NETWORK_UNAVAILABLE":
            .serverUnreachable
        case "RESOLVE_ERROR":
            .serverNotFound
        case "CERT_VERIFY_FAIL", "TLS_ALERT_UNKNOWN_CA", "TLS_ALERT_BAD_CERTIFICATE",
            "TLS_ALERT_UNSUPPORTED_CERTIFICATE", "TLS_ALERT_CERTIFICATE_REVOKED":
            .certificateRejected
        case "TLS_ALERT_CERTIFICATE_EXPIRED":
            .certificateExpired
        case "TLS_VERSION_MIN", "TLS_ALERT_PROTOCOL_VERSION", "TLS_ALERT_HANDSHAKE_FAILURE",
            "TLS_SIGALG_DISALLOWED_OR_UNSUPPORTED":
            .noSecureConnection
        case "CLIENT_HALT", "CLIENT_SETUP":
            .serverEnded
        case "TUN_SETUP_FAILED", "TUN_IFACE_CREATE", "TUN_HALT", "TUN_IFACE_DISABLED", "TUN_ERROR":
            .setupFailed
        case "INACTIVE_TIMEOUT":
            .idleTimeout
        case "EPKI_ERROR", "EPKI_INVALID_ALIAS":
            .certificateUnusable
        case "UNSUPPORTED_FEATURE", "COMPRESS_ERROR", "RELAY_ERROR", "NTLM_MISSING_CRYPTO":
            .unsupportedRequirement
        case "NEED_CREDS", "DYNAMIC_CHALLENGE", "PROXY_NEED_CREDS":
            // Prompts, not failures (D98). Reaching here means nobody could
            // be asked, which is M21's case.
            .credentialsUnavailable
        default:
            .unknown
        }
    }

    /// The message for a phase that never ended (A9 source 2). Each stall is
    /// a mode with an identity, not an absence of data (D100).
    static func forStall(in phase: OpenVPNPhase) -> TunnelFailure {
        switch phase {
        case .findingServer: .serverNotFound
        case .contactingServer: .serverUnreachable
        case .signingIn: .timedOut
        case .waitingForSettings: .settingsNeverSent
        case .settingUp: .setupFailed
        }
    }

    /// The events whose text is the **server's** words, which A10 may quote
    /// and attribute (D104, M9). The other seven reason-bearing events carry
    /// text too; it goes to the details, never to a surface.
    static let quotableEvents: Set<String> = ["CLIENT_HALT", "CLIENT_SETUP"]
}

extension FailureDetail {
    /// What the provider hands the model for a fatal event: the code, the
    /// server's words where they are the server's, and the engine's own
    /// identifier and text for the log and the export (D138).
    static func forEvent(_ name: String, info: String) -> FailureDetail {
        FailureDetail(
            TunnelFailure.forEvent(name),
            serverText: TunnelFailure.quotableEvents.contains(name) && !info.isEmpty ? info : nil,
            detail: info.isEmpty ? name : "\(name): \(info)")
    }

    /// What the provider hands the model for a stall: the phase's message,
    /// how long it waited, and how many times it asked where that is known.
    static func forStall(in phase: OpenVPNPhase, waited seconds: Int, requests: Int?) -> FailureDetail {
        FailureDetail(
            TunnelFailure.forStall(in: phase),
            waited: .seconds(seconds),
            attempts: requests,
            detail: "The step \(phase.rawValue) did not finish within \(seconds) seconds.")
    }
}
