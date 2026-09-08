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

@testable import VPNPlusCore

/// A8's transition table, as tests. If the table and this file disagree, one
/// of them is wrong and it matters which — so every row here cites the rule it
/// comes from.
struct ConnectionTests {
    let singapore = UUID()
    let hongKong = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func phase(_ id: String, _ seconds: Int = 10) -> TunnelPhase {
        TunnelPhase(id: id, deadline: .seconds(seconds))
    }

    // MARK: - Starting and finishing

    @Test func connectingFromRestGoesStraightToAnAttempt() {
        let state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        #expect(state.state == .connecting)
        #expect(state.profile == singapore)
        #expect(state.attempt?.recovery == 0, "a user's own attempt is not a recovery attempt")
    }

    @Test func anAttemptThatSucceedsBecomesASession() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .established, at: start + 6)
        guard case .connected(let session) = state else { return #expect(Bool(false), "\(state)") }
        #expect(session.profile == singapore)
        #expect(session.since == start + 6)
    }

    @Test func retryingAFailureIsAFreshAttempt() {
        let record = FailureRecord(profile: singapore, at: start, reason: .authenticationFailed)
        let state = ConnectionMachine.next(.failed(record), on: .connect(singapore), at: start + 60)
        #expect(state.state == .connecting)
    }

    /// D74: reversible, one click, unmistakable — and nothing to confirm.
    @Test func disconnectingTearsDownAndThenRests() {
        var state = Connection.connected(Session(profile: singapore, since: start))
        state = ConnectionMachine.next(state, on: .disconnect, at: start + 100)
        #expect(state.state == .disconnecting)
        state = ConnectionMachine.next(state, on: .tornDown, at: start + 101)
        #expect(state == .disconnected)
    }

    // MARK: - Switching, which is one operation (D70)

    @Test func switchingProfilesNeverPassesThroughDisconnected() {
        var state = Connection.connected(Session(profile: singapore, since: start))
        state = ConnectionMachine.next(state, on: .connect(hongKong), at: start + 100)

        guard case .disconnecting(let teardown) = state else { return #expect(Bool(false), "\(state)") }
        #expect(teardown.profile == singapore)
        #expect(teardown.switchingTo == hongKong)
        #expect(teardown.isSwitch, "the model carries the intent so the UI can narrate one operation")

        // The second half starts from the teardown, so no surface ever has a
        // Disconnected state to render in between.
        state = ConnectionMachine.next(state, on: .tornDown, at: start + 101)
        #expect(state.state == .connecting)
        #expect(state.profile == hongKong)
    }

    @Test func connectingWhatIsAlreadyConnectedChangesNothing() {
        let connected = Connection.connected(Session(profile: singapore, since: start))
        #expect(ConnectionMachine.next(connected, on: .connect(singapore), at: start + 5) == connected)
    }

    @Test func switchingWhileStillConnectingAlsoSwitches() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .connect(hongKong), at: start + 2)
        #expect(state.attempt == nil)
        #expect(state.state == .disconnecting)
        state = ConnectionMachine.next(state, on: .tornDown, at: start + 3)
        #expect(state.profile == hongKong)
    }

    /// D39: a teardown that will not finish is not a reason to sit there, and
    /// a switch still owes the user the profile they asked for.
    @Test func aTeardownThatOverrunsIsForcedAndASwitchStillCompletes() {
        let plain = Connection.disconnecting(Teardown(profile: singapore, startedAt: start))
        #expect(ConnectionMachine.next(plain, on: .timedOut, at: start + 11) == .disconnected)

        let switching = Connection.disconnecting(
            Teardown(profile: singapore, startedAt: start, switchingTo: hongKong))
        let after = ConnectionMachine.next(switching, on: .timedOut, at: start + 11)
        #expect(after.profile == hongKong)
        #expect(after.state == .connecting)
    }

    // MARK: - Recovery: bounded, counted, visible (D86)

    @Test func aDropStartsCountedRecovery() {
        let connected = Connection.connected(Session(profile: singapore, since: start))
        let state = ConnectionMachine.next(connected, on: .dropped, at: start + 100)
        #expect(state.state == .reconnecting)
        #expect(state.attempt?.recovery == 1)
    }

    @Test func recoveryStopsAtTheBoundAndBecomesFailed() {
        var state = ConnectionMachine.next(
            .connected(Session(profile: singapore, since: start)), on: .dropped, at: start)
        var attempts = 0
        while state.state == .reconnecting, attempts < 20 {
            attempts += 1
            state = ConnectionMachine.next(state, on: .timedOut, at: start + Double(attempts))
        }
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(attempts == Recovery.maxAttempts, "five attempts, then it stops asking")
        #expect(record.recoveryAttempts == Recovery.maxAttempts)
        // A10 M14: running out is its own reason; what the last attempt died
        // of rides along for the details (M6.1).
        #expect(record.reason == .recoveryGaveUp)
        #expect(record.underlying == .timedOut)
    }

    /// A failure the user is waiting to read is not retried behind their back.
    @Test func aUsersOwnFailedAttemptIsNotRetriedAutomatically() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .failed(.authenticationFailed), at: start + 4)
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.reason == .authenticationFailed)
        #expect(record.recoveryAttempts == 0)
    }

    @Test func theBackoffIsTheOneA8NamesAndTheFirstAttemptWaitsToo() {
        #expect(Recovery.backoff(before: 1) == .seconds(2))
        #expect(Recovery.backoff(before: 2) == .seconds(4))
        #expect(Recovery.backoff(before: 3) == .seconds(8))
        #expect(Recovery.backoff(before: 4) == .seconds(16))
        #expect(Recovery.backoff(before: 5) == .seconds(32))
        // A user's own attempt is immediate: nothing has just failed.
        #expect(Recovery.backoff(before: 0) == .zero)
        #expect(!Recovery.mayRetry(after: Recovery.maxAttempts))
    }

    // MARK: - The two clocks (D73)

    @Test func anAttemptCarriesOnlyAnAttemptClockAndASessionOnlyASession() {
        let attempting = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        #expect(attempting.attempt?.elapsed(at: start + 3) == .seconds(3))

        let session = Session(profile: singapore, since: start)
        #expect(session.duration(at: start + 3_600) == .seconds(3_600))
        // And there is no way to ask a connection for the wrong one: the
        // attempt is absent once connected.
        #expect(Connection.connected(session).attempt == nil)
    }

    @Test func aClockNeverRunsBackwards() {
        let attempt = Attempt(profile: singapore, startedAt: start)
        #expect(attempt.elapsed(at: start - 500) == .zero, "a clock change is not negative time")
    }

    // MARK: - Naming a phase only once it is slow (D71)

    @Test func aFastConnectionNamesNothingInternal() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .entered(phase("handshake", 30)), at: start + 0.1)
        #expect(state.attempt?.revealedPhase(at: start + 1) == nil, "1 s in: nothing to say yet")
        #expect(state.attempt?.revealedPhase(at: start + 3)?.id == "handshake")
    }

    /// The reveal delay belongs to the **attempt**, not to each phase.
    /// Measured against each phase, a real connection read backwards: "Signing
    /// in" at +2 s, then the generic "Connecting" at +4 s because the next
    /// phase was 100 ms old. A step being un-named looks like progress lost.
    @Test func aNamedStepIsNeverReplacedByAVaguerOne() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .entered(phase("auth", 20)), at: start + 0.2)
        #expect(state.attempt?.revealedPhase(at: start + 3)?.id == "auth")

        // The next phase begins, and is named at once because the attempt is
        // already being narrated.
        state = ConnectionMachine.next(state, on: .entered(phase("config", 20)), at: start + 3.9)
        #expect(state.attempt?.revealedPhase(at: start + 4)?.id == "config")
    }

    @Test func aPhaseWithNoReportIsNotInvented() {
        let state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        #expect(state.attempt?.phase == nil)
        #expect(state.attempt?.revealedPhase(at: start + 30) == nil)
    }

    // MARK: - Every phase has a deadline, and so does the attempt (3.5, 3.7)

    @Test func aPhaseDeadlinePassesBeforeTheAttemptDeadlineDoes() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .entered(phase("config", 20)), at: start + 5)
        #expect(state.attempt?.expiry(at: start + 20) == nil)
        #expect(state.attempt?.expiry(at: start + 26) == .phase(phase("config", 20)))
    }

    @Test func anAttemptWithNoPhaseStillEnds() {
        let state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        #expect(state.attempt?.expiry(at: start + 59) == nil)
        #expect(state.attempt?.expiry(at: start + 61) == .attempt)
    }

    @Test func noDeadlineIsInfinite() {
        // D97, checked rather than trusted: OpenVPN Connect ships
        // "Continuously Retry" as a menu option.
        for deadline in [
            Deadlines.resolve, Deadlines.contact, Deadlines.auth, Deadlines.config,
            Deadlines.setup, Deadlines.attempt, Deadlines.disconnect, Deadlines.phaseReveal,
        ] {
            #expect(deadline > .zero)
            #expect(deadline < .seconds(600))
        }
    }

    // MARK: - Observed, never assumed (D75, D95)

    @Test func realityOverridesWhateverWeThought() {
        // The OS disconnected our configuration while we thought we were up.
        let connected = Connection.connected(Session(profile: singapore, since: start))
        let observed = ConnectionMachine.next(
            connected, on: .observed(.disconnected, profile: nil), at: start + 100)
        #expect(observed == .disconnected)
    }

    @Test func anAgreeingObservationKeepsTheClockAndThePhase() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .entered(phase("handshake", 30)), at: start + 1)
        let after = ConnectionMachine.next(
            state, on: .observed(.connecting, profile: singapore), at: start + 5)
        #expect(after == state, "re-reading the same truth must not restart the clock")
    }

    /// The wake case, which is J11 — the highest-ranked job in the product.
    @Test func wakingToATunnelThatIsGoneStartsRecoveryRatherThanClaimingConnected() {
        let connected = Connection.connected(Session(profile: singapore, since: start))
        let woke = ConnectionMachine.next(
            connected, on: .observed(.reconnecting, profile: singapore), at: start + 4_000)
        #expect(woke.state == .reconnecting)
        #expect(woke.attempt?.recovery == 1, "a recovery we did not count would be unbounded")
    }

    @Test func aTunnelFoundAlreadyUpCountsFromNowRatherThanFromAGuess() {
        let woke = ConnectionMachine.next(
            .disconnected, on: .observed(.connected, profile: singapore), at: start + 50)
        guard case .connected(let session) = woke else { return #expect(Bool(false), "\(woke)") }
        #expect(session.since == start + 50)
    }

    /// Failed is a disconnected tunnel with a reason, and the system reports
    /// only the first half. An observation must not erase the half the user is
    /// reading.
    @Test func observingDisconnectedDoesNotEraseAFailure() {
        let record = FailureRecord(profile: singapore, at: start, reason: .authenticationFailed)
        let failed = Connection.failed(record)
        #expect(ConnectionMachine.next(failed, on: .observed(.disconnected, profile: nil), at: start + 5) == failed)
        // The user acting is what leaves it (A8 rule 4).
        #expect(ConnectionMachine.next(failed, on: .connect(singapore), at: start + 5).state == .connecting)
    }

    /// An attempt can end faster than anyone can ask about it — 27 ms, when a
    /// profile has no password. The reason survives elsewhere, and the model
    /// has to be able to take it, or Failed is unrenderable.
    @Test func aReasonFoundAfterwardsCanStillBecomeFailed() {
        let record = FailureRecord(profile: singapore, at: start, reason: .credentialsUnavailable)
        #expect(ConnectionMachine.next(.disconnected, on: .recoveredFailure(record), at: start + 1)
            == .failed(record))
        // But never over the top of something live (D226).
        let connected = Connection.connected(Session(profile: singapore, since: start))
        #expect(ConnectionMachine.next(connected, on: .recoveredFailure(record), at: start + 1) == connected)
    }

    /// The teardown that follows a failed attempt is the failure's own
    /// mechanics, not the user dismissing it. A8: Failed is terminal.
    @Test func tearingDownAfterAFailureDoesNotEraseIt() {
        let record = FailureRecord(profile: singapore, at: start, reason: .authenticationFailed)
        var state = Connection.failed(record)
        state = ConnectionMachine.next(state, on: .disconnect, at: start + 1)
        #expect(state == .failed(record))
        state = ConnectionMachine.next(state, on: .tornDown, at: start + 2)
        #expect(state == .failed(record), "the reason outlives the tunnel that failed to come up")
    }

    /// The engine ending on its own while the tunnel is up is a failure, not
    /// the user disconnecting — that goes through `.disconnect`. Commitment 3:
    /// a tunnel that vanishes says so, even when it cannot say why.
    @Test func aSessionWhoseEngineEndsOnItsOwnHasFailed() {
        let state = ConnectionMachine.next(
            .connected(Session(profile: singapore, since: start)), on: .tornDown, at: start + 40)
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.profile == singapore)
        #expect(record.reason == .unknown, "no cause was given, and none is invented")
        #expect(record.at == start + 40)
    }

    @Test func anImpossibleEventChangesNothing() {
        // The model never invents a transition; the caller that saw the
        // impossible event has the context to log it.
        #expect(ConnectionMachine.next(.disconnected, on: .established, at: start) == .disconnected)
        #expect(ConnectionMachine.next(.disconnected, on: .dropped, at: start) == .disconnected)
        let connected = Connection.connected(Session(profile: singapore, since: start))
        #expect(ConnectionMachine.next(connected, on: .established, at: start + 1) == connected)
    }

    // MARK: - The record outlives the state (D96)

    @Test func aFailureRecordCarriesWhatTheMessageWillNeed() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(state, on: .entered(phase("config", 20)), at: start + 2)
        state = ConnectionMachine.next(state, on: .timedOut, at: start + 24)

        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.profile == singapore)
        #expect(record.at == start + 24)
        #expect(record.phase == "config", "which step died is the message")
        #expect(record.elapsed == .seconds(24))
    }

    @Test func aFailureRecordSurvivesEncodingAsStoredMetadata() throws {
        let record = FailureRecord(
            profile: singapore, at: start, reason: .credentialsUnavailable,
            phase: "auth", elapsed: .seconds(12), recoveryAttempts: 3)
        let decoded = try JSONDecoder().decode(
            FailureRecord.self, from: try JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test func aFailureCrossesAsAnErrorAndComesBackTheSame() {
        let error = TunnelFailure.credentialsUnavailable.error("no password", at: start)
        #expect(TunnelFailure(error) == .credentialsUnavailable)
        #expect(TunnelFailure.time(of: error) == start)
        // Anything from elsewhere is nil rather than guessed at.
        #expect(TunnelFailure(NSError(domain: "com.apple.NetworkExtension", code: 2)) == nil)
    }
}
