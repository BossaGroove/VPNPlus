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
import Testing
import VPNPlusCore

/// Every message the user can read, rendered with every payload, and checked
/// for what must never be in one (feature-spec 4.1, D105) and for what A10
/// says each must carry.
struct FailureCopyTests {
    let profile = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)
    let name = "Work"

    /// `AUTH_FAILED`, `GET_CONFIG`, `TLS_ALERT_UNKNOWN_CA` — the shape of every
    /// engine identifier A9 lists.
    static let engineIdentifier = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b"#)

    /// Every code, with every kind of payload a record can carry.
    private var everyRecord: [FailureRecord] {
        var records: [FailureRecord] = []
        for reason in TunnelFailure.allCases {
            records.append(FailureRecord(profile: profile, at: start, reason: reason))
            records.append(
                FailureRecord(
                    profile: profile, at: start, reason: reason, phase: "config",
                    elapsed: .seconds(27), recoveryAttempts: 5, waited: .seconds(20), attempts: 7,
                    serverText: "SESSION: token revoked by admin", detail: "GET_CONFIG: timed out",
                    underlying: .serverUnreachable, foreignTunnel: "utun9"))
            for phase in ["resolve", "contact", "auth", "config", "setup", "something-new"] {
                records.append(
                    FailureRecord(profile: profile, at: start, reason: reason, phase: phase))
            }
        }
        return records
    }

    private func facts(randomised: Bool, kind: NetworkFacts.InterfaceKind = .wiFi, at offset: TimeInterval = 0)
        -> NetworkFacts
    {
        NetworkFacts(
            at: start + offset, interfaceName: "en0", interfaceKind: kind, gateway: "192.168.1.1",
            gatewayHardwareAddress: "00:00:5e:00:53:01", subnetMask: "255.255.255.0",
            hardwareAddress: randomised ? "8a:00:00:00:00:01" : "c0:00:00:00:00:01",
            addressIsRandomised: randomised)
    }

    private func check(_ text: String, _ where_: String) {
        let range = NSRange(text.startIndex..., in: text)
        let found = Self.engineIdentifier.firstMatch(in: text, range: range)
        #expect(found == nil, "an engine identifier reached a surface in \(where_): \(text)")
        #expect(!text.contains("Error"), "the word Error in \(where_): \(text)")
        #expect(!text.isEmpty, "\(where_) is empty")
    }

    // MARK: - 4.1 and D105, for every message

    @Test func noCodeAndNoIdentifierReachesAnySurface() {
        let comparisons: [NetworkComparison?] = [
            nil,
            NetworkComparison(lastGood: nil, now: facts(randomised: false)),
            NetworkComparison(lastGood: facts(randomised: false), now: facts(randomised: true, at: 60)),
            NetworkComparison(
                lastGood: facts(randomised: false, kind: .wiFi),
                now: facts(randomised: false, kind: .ethernet, at: 60), profileReplaced: true),
            NetworkComparison(lastGood: facts(randomised: false), now: facts(randomised: false, at: 60)),
        ]
        for record in everyRecord {
            check(FailureCopy.title(record, name: name), "title of \(record.reason)")
            check(FailureCopy.shortTitle(record), "short title of \(record.reason)")
            for randomised in [nil, false, true] {
                let now = randomised.map { facts(randomised: $0) }
                check(FailureCopy.body(record, name: name, facts: now), "body of \(record.reason)")
                for comparison in comparisons {
                    let message = FailureCopy.message(
                        record, name: name, facts: now, comparison: comparison)
                    check(message.title, "message title of \(record.reason)")
                    check(message.body, "message body of \(record.reason)")
                    for cause in message.causes { check(cause, "a cause of \(record.reason)") }
                    if let changed = message.whatChanged { check(changed, "what changed for \(record.reason)") }
                }
            }
        }
    }

    /// The details the record carries for the export must not leak into the
    /// words: `detail` is the engine's text and never appears.
    @Test func theEnginesOwnDetailNeverAppears() {
        let record = FailureRecord(
            profile: profile, at: start, reason: .unknown, detail: "TLS_ALERT_MISC: handshake failure")
        let message = FailureCopy.message(record, name: name)
        #expect(!message.body.contains("TLS_ALERT_MISC"))
        #expect(!message.body.contains("handshake failure"))
    }

    // MARK: - What A10 says each message carries

    @Test func theProfileIsNamedInEveryTitleThatHasRoomForIt() {
        // Rule 2. A handful of titles are about the Mac or the server rather
        // than the profile, and A10 wrote them without the name on purpose.
        let nameless: Set<TunnelFailure> = [
            .certificateExpired, .clockWrong, .setupFailed, .noNetwork, .unsupportedRequirement,
            .anotherTunnelActive, .componentDidNotStart,
        ]
        for reason in TunnelFailure.allCases where !nameless.contains(reason) {
            let title = FailureCopy.title(FailureRecord(profile: profile, at: start, reason: reason), name: name)
            #expect(title.contains(name), "\(reason) does not name the profile: \(title)")
        }
    }

    /// D104: the server's words, quoted and attributed, and only where they
    /// are the server's — M9, and M1 when the server said why.
    @Test func serverTextIsQuotedAndAttributedWhereItIsTheServers() {
        let halt = FailureRecord(profile: profile, at: start, reason: .serverEnded, serverText: "maintenance until 09:00")
        #expect(FailureCopy.body(halt, name: name).contains("The server said: “maintenance until 09:00”"))

        let silent = FailureRecord(profile: profile, at: start, reason: .serverEnded)
        #expect(FailureCopy.body(silent, name: name).contains("without saying why"))

        let locked = FailureRecord(profile: profile, at: start, reason: .authenticationFailed, serverText: "account locked")
        #expect(FailureCopy.body(locked, name: name).contains("The server said: “account locked”"))

        // Text on a message that does not quote is not quoted.
        let stall = FailureRecord(profile: profile, at: start, reason: .settingsNeverSent, serverText: "irrelevant")
        #expect(!FailureCopy.body(stall, name: name).contains("irrelevant"))
    }

    /// Feature-spec 4.10: a stall says how long and how many times.
    @Test func aStallSaysHowLongAndHowManyTimes() {
        let counted = FailureRecord(
            profile: profile, at: start, reason: .settingsNeverSent, waited: .seconds(20), attempts: 7)
        #expect(FailureCopy.body(counted, name: name).contains("asked 7 times over 20 seconds"))
        let waited = FailureRecord(profile: profile, at: start, reason: .serverUnreachable, waited: .seconds(15))
        #expect(FailureCopy.body(waited, name: name).contains("waited 15 seconds"))
        let bare = FailureRecord(profile: profile, at: start, reason: .serverUnreachable)
        #expect(!FailureCopy.body(bare, name: name).contains("seconds"))
    }

    /// A10 M2's list, and nobody else's (D102).
    @Test func onlyTheStallHasCommonCauses() {
        for reason in TunnelFailure.allCases {
            let message = FailureCopy.message(FailureRecord(profile: profile, at: start, reason: reason), name: name)
            #expect((reason == .settingsNeverSent) == !message.causes.isEmpty, "\(reason)")
        }
    }

    /// D178, 4.11: the address hint where it could be the cause, never on a
    /// rejected password (D85).
    @Test func theAddressHintAppearsOnlyWhereItCouldBeTheCause() {
        let randomised = facts(randomised: true)
        let carries: Set<TunnelFailure> = [.settingsNeverSent, .serverUnreachable, .timedOut, .unknown]
        for reason in TunnelFailure.allCases {
            let body = FailureCopy.body(FailureRecord(profile: profile, at: start, reason: reason), name: name, facts: randomised)
            #expect(body.contains("private Wi-Fi address") == carries.contains(reason), "\(reason)")
        }
        // And never without the bit set.
        let plain = FailureCopy.body(
            FailureRecord(profile: profile, at: start, reason: .settingsNeverSent), name: name,
            facts: facts(randomised: false))
        #expect(!plain.contains("private"))
    }

    // MARK: - What changed since it last worked (A7, D46)

    @Test func nothingToCompareWithSaysNothing() {
        let record = FailureRecord(profile: profile, at: start, reason: .settingsNeverSent)
        let never = NetworkComparison(lastGood: nil, now: facts(randomised: false))
        #expect(FailureCopy.message(record, name: name, comparison: never).whatChanged == nil)
        #expect(FailureCopy.message(record, name: name, comparison: nil).whatChanged == nil)
    }

    /// The sentence A7 wanted most.
    @Test func anUnchangedMacPointsAtTheServer() {
        let record = FailureRecord(profile: profile, at: start, reason: .settingsNeverSent)
        let same = NetworkComparison(lastGood: facts(randomised: false), now: facts(randomised: false, at: 60))
        let changed = FailureCopy.message(record, name: name, comparison: same).whatChanged
        #expect(changed?.contains("Nothing about this Mac has changed") == true)
        #expect(changed?.contains("points at the server") == true)
    }

    /// A7's worked example: Wi-Fi then, Ethernet now.
    @Test func aChangedInterfaceIsNamedBothWays() {
        let record = FailureRecord(profile: profile, at: start, reason: .settingsNeverSent)
        let comparison = NetworkComparison(
            lastGood: facts(randomised: false, kind: .wiFi), now: facts(randomised: false, kind: .ethernet, at: 60))
        let changed = FailureCopy.message(record, name: name, comparison: comparison).whatChanged
        #expect(changed?.contains("on Wi-Fi") == true)
        #expect(changed?.contains("You're on Ethernet now") == true)
    }

    /// The same fact is not said twice: when the comparison says the address
    /// changed, the hint does not repeat it.
    @Test func theAddressChangeIsSaidOnce() {
        let record = FailureRecord(profile: profile, at: start, reason: .settingsNeverSent)
        let now = facts(randomised: true, at: 60)
        let comparison = NetworkComparison(lastGood: facts(randomised: false), now: now)
        let message = FailureCopy.message(record, name: name, facts: now, comparison: comparison)
        #expect(message.whatChanged?.contains("private address") == true)
        #expect(!message.body.contains("One thing worth knowing"))
    }

    /// The environment is not compared for a rejected password: nothing about
    /// the network explains one (D85).
    @Test func aRejectedPasswordDoesNotCompareTheNetwork() {
        let record = FailureRecord(profile: profile, at: start, reason: .authenticationFailed)
        let comparison = NetworkComparison(lastGood: facts(randomised: false), now: facts(randomised: false, kind: .ethernet, at: 60))
        #expect(FailureCopy.message(record, name: name, comparison: comparison).whatChanged == nil)
    }

    // MARK: - Actions

    /// D50: the details are always one click away; only the clock adds a
    /// remedy that lives elsewhere.
    @Test func theDetailsAreAlwaysOfferedAndOnlyTheClockAddsARemedy() {
        for reason in TunnelFailure.allCases {
            let message = FailureCopy.message(FailureRecord(profile: profile, at: start, reason: reason), name: name)
            #expect(message.actions.first == .showDetails, "\(reason)")
            #expect(message.actions.contains(.openDateAndTime) == (reason == .clockWrong), "\(reason)")
        }
    }

    /// A10 M14: the count, and what the last try died of.
    @Test func givingUpSaysHowManyTimesAndWhy() {
        let record = FailureRecord(
            profile: profile, at: start, reason: .recoveryGaveUp, recoveryAttempts: 5, underlying: .serverUnreachable)
        let body = FailureCopy.body(record, name: name)
        #expect(body.contains("after 5 attempts"))
        #expect(body.contains("stopped responding"))
    }

    // MARK: - The other words

    @Test func phaseLabelsAndRecordPhrasesCarryNoIdentifier() {
        for id in ["resolve", "contact", "auth", "config", "setup", "unknown-phase"] {
            check(TunnelPhase(id: id, deadline: .zero).label, "phase label \(id)")
        }
        let kinds: [DiagnosticsEntry.Kind] = [
            .attemptBegan, .phase("config"), .connected, .gaveUp(phase: "contact", seconds: 15),
            .failed(.serverUnreachable, waited: 15, requests: nil),
            .failed(.settingsNeverSent, waited: 20, requests: 7),
            .tryingAgain(attempt: 2, of: 5, seconds: 4), .networkLost, .networkReturned,
            .teardownRestored, .disconnected, .truncated,
        ]
        for kind in kinds {
            if let phrase = DiagnosticsCopy.phrase(DiagnosticsEntry(at: start, kind: kind)) {
                check(phrase, "phrase for \(kind)")
            }
        }
        for reason in TunnelFailure.allCases {
            let entry = DiagnosticsEntry(at: start, kind: .failed(reason, waited: nil, requests: nil))
            if let phrase = DiagnosticsCopy.phrase(entry) { check(phrase, "failed phrase \(reason)") }
        }
        // The engine's own lines are for the export, never the screen (D138).
        #expect(DiagnosticsCopy.phrase(DiagnosticsEntry(at: start, kind: .engine("Contacting 192.0.2.1"))) == nil)
        #expect(DiagnosticsCopy.phrase(DiagnosticsEntry(at: start, kind: .note("AUTH_FAILED: x"))) == nil)
    }
}
