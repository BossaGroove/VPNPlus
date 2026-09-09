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

/// A failure, in the four parts A7 designed and A10 wrote (D81): **what
/// happened**, **what it probably means**, **what to try**, and **what changed
/// since it last worked**. The region renders the parts; the menu takes the
/// short title; nothing else composes a sentence about a failure.
struct FailureMessage: Equatable {
    /// What did not happen, naming the profile (copy rule 2).
    var title: String
    /// What happened and what it probably means, as prose.
    var body: String
    /// *Common causes* — only where A10 wrote a list, because a list that
    /// exists for symmetry is noise (D102).
    var causes: [String] = []
    /// *What changed since it last worked* (D46, A7) — only when there is a
    /// last time to compare with.
    var whatChanged: String?
    /// What to do besides trying again, in order. D80's fourth tier — the
    /// details — is always reachable from a failure (D50: the route in is
    /// permanent), so `.showDetails` is always first; a remedy that lives
    /// elsewhere follows it.
    var actions: [SecondaryAction] = [.showDetails]

    enum SecondaryAction: Equatable {
        /// The Diagnostics sheet (A14, M6.5).
        case showDetails
        /// A10 M7: the remedy lives in System Settings.
        case openDateAndTime
    }
}

/// The words for a failure, in one place.
///
/// A10's message set, one message per code (D103), in D81's four parts. What
/// holds here and is not provisional:
///
/// - **No code, no engine identifier, ever** (feature-spec 4.1, D105) — and
///   `FailureCopyTests` renders every code with every payload to prove it.
/// - **No "Error".** The title says what did not happen.
/// - **The profile is named**, because the user may have several.
/// - **Nothing is invented** (D85). Where the cause is unknown the message
///   says so and offers what is real — the step, and the time it took.
/// - **Server text is quoted and attributed** (D104), never spoken as ours.
/// - **A stall says how long and how many times** (feature-spec 4.10).
/// - **Where two causes have different remedies, both are named** (D99).
enum FailureCopy {
    // MARK: - The message

    /// The whole message. `facts` is this Mac's network now; `comparison` is
    /// now against the last time this profile worked, when it ever has.
    static func message(
        _ record: FailureRecord, name: String, facts: NetworkFacts? = nil,
        comparison: NetworkComparison? = nil
    ) -> FailureMessage {
        var message = FailureMessage(title: title(record, name: name), body: reason(record, name: name))
        if case .settingsNeverSent = record.reason {
            // A10 M2, the owner's own failure: the two causes the server will
            // never explain.
            message.causes = [
                String(localized: "This account is already connected from another device on your network"),
                String(localized: "The server only permits specific devices, and this Mac wasn't recognised"),
            ]
        }
        if compares(record.reason), let comparison {
            message.whatChanged = whatChanged(comparison)
        }
        // The address hint is one sentence of the same comparison; when the
        // comparison already says the address changed, it is not said twice.
        let alreadySaid = message.whatChanged != nil && comparison?.changed(.addressRandomised) == true
        if !alreadySaid, let hint = addressHint(record, facts: facts) {
            message.body = joined(message.body, hint)
        }
        if case .clockWrong = record.reason { message.actions.append(.openDateAndTime) }
        return message
    }

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
        case .componentDidNotStart: String(localized: "VPN Plus's network component didn't start")
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
        case .clockWrong: String(localized: "Check the date and time")
        default: String(localized: "Couldn't connect")
        }
    }

    /// The body alone — what happened, what it probably means, and the
    /// address hint where it applies. `message(…)` is the whole thing.
    static func body(_ record: FailureRecord, name: String, facts: NetworkFacts? = nil) -> String {
        joined(reason(record, name: name), addressHint(record, facts: facts))
    }

    // MARK: - What happened, and what it probably means

    private static func reason(_ record: FailureRecord, name: String) -> String {
        switch record.reason {
        case .authenticationFailed:
            // A10 M1, both remedies named (D99). Where the server said why —
            // an account locked, a session revoked — its words change what
            // the user does next, so they are quoted (D102, D104).
            let ours = String(
                localized: """
                    The server didn't accept your username or password. If they're definitely right, \
                    the account may be disabled or locked — worth asking whoever runs this VPN.
                    """)
            return joined(ours, quoted(record))
        case .credentialsUnavailable:
            // A10 M21, for the case where a prompt had no window to appear in.
            return String(
                localized: """
                    It needs your password, and VPN Plus wasn't running to ask for it. Connect once from \
                    VPN Plus and let it remember your password — after that, starting \(name) from \
                    System Settings or the menu bar will work on its own.
                    """)
        case .configurationMissing:
            return String(
                localized: "VPN Plus doesn't have that profile's settings any more. Import the profile again.")
        case .settingsNeverSent:
            // A10 M2 — the owner's own failure. Its causes are a list.
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
            // A10 M7, the case nobody thinks of (D101). Same engine event as
            // M5 and M6, different remedy, therefore a different message.
            return String(
                localized: """
                    Connecting to \(name) failed while checking the server's certificate, and this \
                    Mac's clock is behind a time it has already recorded. That alone can cause this.
                    """)
        case .noSecureConnection:
            return String(
                localized: """
                    This server uses older security settings than VPN Plus accepts. Ask whoever runs \
                    it whether it can be updated.
                    """)
        case .serverEnded:
            // A10 M9: the one message that is mostly the server's words —
            // quoted, attributed, never in our voice (D104).
            return quoted(record)
                ?? String(localized: "The server closed the connection without saying why.")
        case .setupFailed:
            return joined(
                String(
                    localized: "\(name) connected, but the network settings couldn't be applied on this Mac."),
                stall(record))
        case .noNetwork:
            return String(
                localized: "This Mac isn't connected to a network, so \(name) can't be reached.")
        case .recoveryGaveUp:
            // A10 M14, with the count (D86), and what the last try died of.
            let count = String(
                localized: """
                    The connection dropped and couldn't be restored after \(record.recoveryAttempts) attempts.
                    """)
            return joined(count, lastTry(record))
        case .keychainDenied:
            return String(
                localized: "macOS didn't allow access to the saved password. You can enter it again.")
        case .idleTimeout:
            return String(localized: "The server closes connections that have been idle for a while.")
        case .certificateUnusable:
            return String(localized: "The certificate or key this profile needs couldn't be read.")
        case .unsupportedRequirement:
            return String(
                localized: """
                    \(name) asks for a feature that isn't available. It's worth reporting — we'd like \
                    to know which profiles need it.
                    """)
        case .componentDidNotStart:
            // D310. Not the server's fault and not the profile's: the part of
            // VPN Plus that carries traffic never came up. A retry usually
            // works — the app has already tried once — and a restart is the
            // honest next step after that.
            return String(localized: "The connection couldn't begin because the part of VPN Plus that carries traffic didn't start on this Mac. VPN Plus tried twice. Try again, and if it keeps happening, restart your Mac.")
        case .anotherTunnelActive:
            // D204's owed copy.
            if let other = record.foreignTunnel, !other.isEmpty {
                return String(
                    localized: """
                        Another VPN (\(other)) was already carrying this Mac's traffic when \(name) tried \
                        to connect, so \(name) couldn't take over. Disconnect the other one first.
                        """)
            }
            return String(
                localized: """
                    Another VPN was already carrying this Mac's traffic when \(name) tried to connect, \
                    so \(name) couldn't take over. Disconnect the other one first.
                    """)
        case .timedOut:
            // A stall nothing else names: the step, and how long (4.10).
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
                localized: "VPN Plus doesn't have a specific reason for it. Trying again is worth a go.")
        }
    }

    // MARK: - What changed since it last worked (D46, A7)

    /// The failures where the environment could be the cause. A rejected
    /// password is not one of them.
    private static func compares(_ reason: TunnelFailure) -> Bool {
        switch reason {
        case .settingsNeverSent, .serverUnreachable, .serverNotFound, .timedOut, .unknown,
            .recoveryGaveUp:
            true
        default:
            false
        }
    }

    /// The comparison as a paragraph, or nil when there is no last time.
    ///
    /// Whole sentences, one per change, each self-contained (D106). And the
    /// sentence A7 wanted most: when nothing about this Mac changed, say so —
    /// it points at the server rather than at the Mac.
    static func whatChanged(_ comparison: NetworkComparison) -> String? {
        guard let lastGood = comparison.lastGood else { return nil }
        let when = RelativeDateTimeFormatter().localizedString(for: lastGood.at, relativeTo: Date())
        guard let now = comparison.now else {
            return String(localized: "It last connected \(when).")
        }
        if comparison.nothingChanged {
            return String(
                localized: """
                    Nothing about this Mac has changed since it last connected, \(when) — the same \
                    network, the same connection, the same address. That points at the server rather \
                    than at this Mac.
                    """)
        }
        var sentences: [String] = []
        for row in comparison.changedRows {
            switch row {
            case .interface:
                // A7's worked example, and the owner's MAC-filter case.
                sentences.append(
                    String(
                        localized: """
                            It last connected \(when) on \(interfaceWords(lastGood.interfaceKind)). You're on \
                            \(interfaceWords(now.interfaceKind)) now — a different network interface, which \
                            some servers treat as a different device.
                            """))
            case .network:
                sentences.append(
                    String(
                        localized: """
                            It last connected \(when) from a different network. Some servers only accept \
                            this Mac from the network they know it on.
                            """))
            case .addressRandomised:
                if now.addressIsRandomised == true {
                    sentences.append(
                        String(
                            localized: """
                                Since it last connected, macOS has started using a private address for this \
                                Mac on this network, so a server that checks hardware addresses won't \
                                recognise it. You can turn that off for this network in System Settings.
                                """))
                } else {
                    sentences.append(
                        String(
                            localized: """
                                When it last connected, macOS was using a private address for this Mac; it \
                                is using the real one now, which a server that checks addresses may not know.
                                """))
                }
            case .profile:
                sentences.append(
                    String(
                        localized: """
                            This profile's file was replaced since it last connected. If the new file \
                            changed the server or the sign-in, that is the first thing to check.
                            """))
            case .when:
                break
            }
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func interfaceWords(_ kind: NetworkFacts.InterfaceKind) -> String {
        switch kind {
        case .wiFi: String(localized: "Wi-Fi")
        case .ethernet: String(localized: "Ethernet")
        case .other: String(localized: "another kind of connection")
        case .none: String(localized: "no network")
        }
    }

    // MARK: - Pieces

    /// **The address hint** (D178, D203, feature-spec 4.11). openvpn3 sends
    /// this Mac's hardware address to the server as its identity, macOS's
    /// Private Wi-Fi Address makes that a random one, and a server that
    /// filters by address will not recognise it. Only where it could be the
    /// cause: never attached to a rejected password, which it cannot explain
    /// (D85).
    private static func addressHint(_ record: FailureRecord, facts: NetworkFacts?) -> String? {
        guard let facts, facts.addressIsRandomised == true else { return nil }
        switch record.reason {
        case .settingsNeverSent, .serverUnreachable, .timedOut, .unknown: break
        default: return nil
        }
        return facts.interfaceKind == .wiFi
            ? String(
                localized: "One thing worth knowing: macOS is using a private Wi-Fi address on this network, so a VPN that checks hardware addresses won't recognise this Mac. You can turn that off for this network in System Settings, under Wi-Fi.")
            : String(
                localized: "One thing worth knowing: this Mac is presenting a private hardware address on this network, so a VPN that checks hardware addresses won't recognise it.")
    }

    /// The server's own words, quoted and attributed (D104). Nil when it said
    /// nothing, and never our own text dressed as the server's.
    private static func quoted(_ record: FailureRecord) -> String? {
        guard let said = record.serverText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !said.isEmpty
        else { return nil }
        return String(localized: "The server said: “\(said)”")
    }

    /// What the last recovery attempt died of, in a clause (M14's second
    /// sentence), when it is more specific than "it failed".
    private static func lastTry(_ record: FailureRecord) -> String? {
        switch record.underlying {
        case .serverUnreachable?: String(localized: "The server stopped responding.")
        case .serverNotFound?: String(localized: "The server's address stopped resolving.")
        case .noNetwork?: String(localized: "This Mac lost its network.")
        case .authenticationFailed?: String(localized: "The server refused the sign-in on reconnecting.")
        default: nil
        }
    }

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
