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

/// The words for a failure, in one place.
///
/// A10's message set, one message per code (D103). M6.1 gave every code its
/// title and body from A10's drafts; **M6.4 owns the finished form** — D81's
/// four parts, the *Common causes* and *What changed* blocks, the editorial
/// pass over the server-text events, and A18's six-language check.
///
/// What holds already, and is not provisional:
///
/// - **No code, no engine identifier, ever** (feature-spec 4.1, D105).
/// - **No "Error".** The title says what did not happen.
/// - **The profile is named**, because the user may have several.
/// - **Nothing is invented** (D85). Where the cause is unknown the message
///   says so and offers what is real — the step, and the time it took.
/// - **Server text is quoted and attributed** (D104), never spoken as ours.
/// - **A stall says how long and how many times** (feature-spec 4.10).
enum FailureCopy {
    static func title(_ record: FailureRecord, name: String) -> String {
        switch record.reason {
        case .authenticationFailed: String(localized: "Couldn't sign in to \(name)")
        case .settingsNeverSent: String(localized: "Couldn't finish connecting to \(name)")
        case .serverUnreachable: String(localized: "Couldn't reach the server for \(name)")
        case .serverNotFound: String(localized: "Couldn't find the server for \(name)")
        case .certificateRejected: String(localized: "Couldn't verify the server for \(name)")
        case .certificateExpired: String(localized: "The server's certificate has expired")
        case .clockWrong: String(localized: "Your Mac's date and time look wrong")
        case .noSecureConnection:
            String(localized: "Couldn't agree on a secure connection with \(name)")
        case .serverEnded: String(localized: "The server ended the connection to \(name)")
        case .setupFailed: String(localized: "Couldn't set up the connection on this Mac")
        case .noNetwork: String(localized: "No network connection")
        case .recoveryGaveUp: String(localized: "Lost the connection to \(name)")
        case .keychainDenied: String(localized: "Couldn't read your saved password for \(name)")
        case .idleTimeout: String(localized: "The connection to \(name) timed out")
        case .certificateUnusable: String(localized: "Couldn't use the certificate for \(name)")
        case .unsupportedRequirement:
            String(localized: "This profile needs something VPN Plus doesn't support")
        case .anotherTunnelActive: String(localized: "Another VPN is already connected")
        case .configurationMissing, .credentialsUnavailable, .timedOut, .unknown:
            String(localized: "Couldn't connect to \(name)")
        }
    }

    /// The same title without the profile's name, for a surface that has
    /// already said it on its own line — the menu (D149). Not built by
    /// deleting words from the long one: a sentence with a hole in it is how
    /// translations break.
    static func shortTitle(_ record: FailureRecord) -> String {
        switch record.reason {
        case .authenticationFailed: String(localized: "Couldn't sign in")
        case .serverUnreachable, .serverNotFound: String(localized: "Couldn't reach the server")
        case .recoveryGaveUp: String(localized: "Lost the connection")
        case .serverEnded, .idleTimeout: String(localized: "The server ended it")
        case .noNetwork: String(localized: "No network")
        default: String(localized: "Couldn't connect")
        }
    }

    /// `facts` is what this Mac's network looks like now, when it is known:
    /// one sentence of it can explain a refusal the server will never explain
    /// (feature-spec 4.11).
    static func body(_ record: FailureRecord, name: String, facts: NetworkFacts? = nil) -> String {
        joined(reason(record, name: name), addressHint(record, facts: facts))
    }

    /// **The address hint** (D178, D203, feature-spec 4.11).
    ///
    /// openvpn3 sends this Mac's hardware address to the server as
    /// `IV_HWADDR`, macOS's Private Wi-Fi Address makes that a random one,
    /// and a server that filters by address will not recognise it. That is
    /// the owner's own failure, and the sentence is buildable from one bit
    /// that nobody needs permission to read.
    ///
    /// Only where it could be the cause: a server that refused *after*
    /// accepting the sign-in, or one that never answered at all. Never
    /// attached to a wrong password, which it cannot explain (D85).
    private static func addressHint(_ record: FailureRecord, facts: NetworkFacts?) -> String? {
        guard let facts, facts.addressIsRandomised == true else { return nil }
        switch record.reason {
        case .settingsNeverSent, .serverUnreachable, .timedOut, .unknown: break
        default: return nil
        }
        let wiFi = facts.interfaceKind == .wiFi
        return wiFi
            ? String(
                localized: "One thing worth knowing: macOS is using a private Wi-Fi address on this network, so a VPN that checks hardware addresses won't recognise this Mac. You can turn that off for this network in System Settings, under Wi-Fi.")
            : String(
                localized: "One thing worth knowing: this Mac is presenting a private hardware address on this network, so a VPN that checks hardware addresses won't recognise it.")
    }

    private static func reason(_ record: FailureRecord, name: String) -> String {
        switch record.reason {
        case .authenticationFailed:
            // A10 M1, both remedies named (D99).
            return String(
                localized: """
                    The server didn't accept your username or password. If they're definitely right, \
                    the account may be disabled or locked — worth asking whoever runs this VPN.
                    """)
        case .credentialsUnavailable:
            // A10 M21, written at M4.5 for the case where a prompt had no
            // window to appear in.
            return String(
                localized: """
                    It needs your password, and VPN Plus wasn't running to ask for it. Connect once from \
                    VPN Plus and let it remember your password — after that, starting \(name) from \
                    System Settings or the menu bar will work on its own.
                    """)
        case .configurationMissing:
            return String(
                localized: """
                    VPN Plus doesn't have that profile's settings any more. Import the profile again.
                    """)
        case .settingsNeverSent:
            // A10 M2 — the owner's own failure. M6.4 adds Common causes.
            return joined(
                String(
                    localized: """
                        The server accepted your sign-in, then never sent the connection settings. \
                        That usually means a policy on the server refused this device.
                        """),
                stall(record))
        case .serverUnreachable:
            return joined(
                String(
                    localized: """
                        The server didn't respond. It may be down, or this network may be blocking \
                        the connection.
                        """),
                stall(record))
        case .serverNotFound:
            return joined(
                String(
                    localized: """
                        The server's address couldn't be looked up. This is usually a problem with the \
                        network you're on rather than with the VPN.
                        """),
                stall(record))
        case .certificateRejected:
            return String(
                localized: """
                    The server's security certificate wasn't accepted. This normally means something \
                    changed on the server, or this profile is out of date. Ask whoever supplied this \
                    profile whether it needs updating.
                    """)
        case .certificateExpired:
            return String(
                localized: """
                    \(name)'s security certificate is out of date. Only the people who run the server \
                    can renew it.
                    """)
        case .clockWrong:
            return String(
                localized: """
                    Connecting to \(name) failed while checking the server's certificate, and this \
                    Mac's clock looks off. That alone can cause this — check Date & Time in System Settings.
                    """)
        case .noSecureConnection:
            return String(
                localized: """
                    This server uses older security settings than VPN Plus accepts. Ask whoever runs \
                    it whether it can be updated.
                    """)
        case .serverEnded:
            // A10 M9: the one place server text reaches the user — quoted,
            // attributed, never in our voice (D104).
            if let said = record.serverText, !said.isEmpty {
                return String(localized: "The server said: “\(said)”")
            }
            return String(localized: "The server closed the connection without saying why.")
        case .setupFailed:
            return joined(
                String(
                    localized: "\(name) connected, but the network settings couldn't be applied."),
                stall(record))
        case .noNetwork:
            return String(
                localized: "This Mac isn't connected to a network, so \(name) can't be reached.")
        case .recoveryGaveUp:
            // A10 M14, with the count (D86).
            return String(
                localized: """
                    The connection dropped and couldn't be restored after \(record.recoveryAttempts) attempts.
                    """)
        case .keychainDenied:
            return String(
                localized: "macOS didn't allow access to the saved password. You can enter it again.")
        case .idleTimeout:
            return String(localized: "The server closes connections that have been idle for a while.")
        case .certificateUnusable:
            return String(
                localized: "The certificate or key this profile needs couldn't be read.")
        case .unsupportedRequirement:
            return String(
                localized: """
                    \(name) asks for a feature that isn't available. It's worth reporting — we'd like \
                    to know which profiles need it.
                    """)
        case .anotherTunnelActive:
            // D204's owed copy, drafted here; A10 signs it off in M6.4.
            if let other = record.foreignTunnel, !other.isEmpty {
                return String(
                    localized: """
                        Another VPN (\(other)) was already carrying this Mac's traffic when \(name) tried \
                        to connect. Disconnect it first, then try again.
                        """)
            }
            return String(
                localized: """
                    Another VPN was already carrying this Mac's traffic when \(name) tried to connect. \
                    Disconnect it first, then try again.
                    """)
        case .timedOut:
            // The step is the message (A10 M2's shape for a stall nothing
            // else names), with how long it waited (4.10).
            if let step = stepWords(record) {
                return joined(
                    String(localized: "It stopped while \(step), and didn't finish in time."),
                    stall(record))
            }
            return joined(String(localized: "It didn't finish in time."), stall(record))
        case .unknown:
            // A10 M20. Never invent a cause (D85); the step and the time are real.
            if let step = stepWords(record) {
                return String(
                    localized: """
                        The connection stopped while \(step), and VPN Plus doesn't have a specific reason \
                        for it. Trying again is worth a go.
                        """)
            }
            return String(
                localized: """
                    VPN Plus doesn't have a specific reason for it. Trying again is worth a go.
                    """)
        }
    }

    // MARK: - Pieces

    /// The phase, in the words the window already uses for it, lowercased to
    /// sit inside a sentence.
    private static func stepWords(_ record: FailureRecord) -> String? {
        record.phase.flatMap(OpenVPNPhase.init(id:))?.asPhase.label.lowercased()
    }

    /// How long a stall was waited for and how many times the server was
    /// asked (feature-spec 4.10, D72). Nothing when the record carries
    /// neither: a sentence about waiting with no number in it says nothing.
    private static func stall(_ record: FailureRecord) -> String? {
        guard let waited = record.waited else { return nil }
        let seconds = Int(waited.components.seconds)
        if let attempts = record.attempts, attempts > 0 {
            return String(localized: "VPN Plus asked \(attempts) times over \(seconds) seconds.")
        }
        return String(localized: "VPN Plus waited \(seconds) seconds.")
    }

    private static func joined(_ first: String, _ second: String?) -> String {
        guard let second else { return first }
        return first + " " + second
    }
}
