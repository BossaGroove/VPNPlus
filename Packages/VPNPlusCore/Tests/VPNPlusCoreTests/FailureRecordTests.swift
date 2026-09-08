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

/// The failure travels whole (M6.1): one code per A10 message, a payload that
/// survives both channels, and the fuller of two records winning.
struct FailureRecordTests {
    let singapore = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// The raw values are a wire and storage format. A code that moved would
    /// re-label every stored failure on every Mac.
    @Test func codesAreUniqueAndTheOriginalFiveAreUnchanged() {
        let raw = TunnelFailure.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        #expect(TunnelFailure.configurationMissing.rawValue == 1)
        #expect(TunnelFailure.credentialsUnavailable.rawValue == 2)
        #expect(TunnelFailure.authenticationFailed.rawValue == 3)
        #expect(TunnelFailure.timedOut.rawValue == 4)
        #expect(TunnelFailure.unknown.rawValue == 99)
    }

    @Test func aRecordSurvivesTheErrorChannelWhole() throws {
        let record = FailureRecord(
            profile: singapore, at: start, reason: .settingsNeverSent, phase: "config",
            elapsed: .seconds(27), recoveryAttempts: 0, waited: .seconds(20), attempts: 7,
            detail: "The step config did not finish within 20 seconds.")
        let error = record.asError()
        // The older readers still work on the same error.
        #expect(TunnelFailure(error) == .settingsNeverSent)
        #expect(TunnelFailure.time(of: error) == start)
        // And the new one gets everything.
        let back = try #require(FailureRecord(error: error))
        #expect(back == record)
    }

    /// An error written before M6.1 has no record in it; it is still read the
    /// old way rather than rejected.
    @Test func anOlderErrorHasNoRecordAndIsNotAnError() {
        let error = TunnelFailure.timedOut.error("old style", at: start)
        #expect(FailureRecord(error: error) == nil)
        #expect(TunnelFailure(error) == .timedOut)
    }

    /// A stored record from before the payload existed decodes with it absent.
    @Test func anOlderStoredRecordStillDecodes() throws {
        let json = """
            {"profile":"\(singapore.uuidString)","at":1000000,"reason":4,"phase":"contact","recoveryAttempts":2}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(FailureRecord.self, from: Data(json.utf8))
        #expect(record.reason == .timedOut)
        #expect(record.phase == "contact")
        #expect(record.waited == nil && record.attempts == nil && record.serverText == nil)
    }

    @Test func theFullerRecordOfTheSameFailureWins() {
        let thin = FailureRecord(profile: singapore, at: start, reason: .timedOut)
        let full = FailureRecord(
            profile: singapore, at: start + 2, reason: .serverUnreachable, phase: "contact",
            elapsed: .seconds(15), waited: .seconds(15))
        #expect(full.isFuller(than: thin))
        #expect(!thin.isFuller(than: full))
        // A different failure is not the same failure, however full.
        let later = FailureRecord(profile: singapore, at: start + 600, reason: .timedOut)
        #expect(!full.isFuller(than: later))
        let other = FailureRecord(profile: UUID(), at: start, reason: .timedOut)
        #expect(!full.isFuller(than: other))
    }

    // MARK: - Through the machine

    @Test func aShortFailedEventIsTheSameAsTheDetailedOne() {
        let attempt = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        let short = ConnectionMachine.next(attempt, on: .failed(.serverUnreachable), at: start + 15)
        let long = ConnectionMachine.next(
            attempt, on: .ended(FailureDetail(.serverUnreachable)), at: start + 15)
        #expect(short == long)
    }

    @Test func thePayloadReachesTheRecord() {
        var state = ConnectionMachine.next(.disconnected, on: .connect(singapore), at: start)
        state = ConnectionMachine.next(
            state, on: .entered(TunnelPhase(id: "config", deadline: .seconds(20))), at: start + 5)
        state = ConnectionMachine.next(
            state,
            on: .ended(
                FailureDetail(
                    .settingsNeverSent, waited: .seconds(20), attempts: 7,
                    detail: "The step config did not finish within 20 seconds.")),
            at: start + 25)
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.reason == .settingsNeverSent)
        #expect(record.phase == "config")
        #expect(record.waited == .seconds(20))
        #expect(record.attempts == 7)
        #expect(record.elapsed == .seconds(25))
    }

    /// A10 M14: recovery that runs out is its own message, with the count and
    /// the last attempt's own reason kept for the details.
    @Test func recoveryRunningOutIsItsOwnReason() {
        var state = Connection.connected(Session(profile: singapore, since: start))
        state = ConnectionMachine.next(state, on: .dropped, at: start + 60)
        var now = start + 60
        for _ in 1..<Recovery.maxAttempts {
            now += 15
            state = ConnectionMachine.next(state, on: .failed(.serverUnreachable), at: now)
            #expect(state.state == .reconnecting, "\(state)")
        }
        now += 15
        state = ConnectionMachine.next(state, on: .failed(.serverUnreachable), at: now)
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.reason == .recoveryGaveUp)
        #expect(record.underlying == .serverUnreachable)
        #expect(record.recoveryAttempts == Recovery.maxAttempts)
    }

    /// A failure after Connected knows how long the session lasted.
    @Test func aFailureWhileConnectedCarriesTheSessionLength() {
        let state = ConnectionMachine.next(
            .connected(Session(profile: singapore, since: start)),
            on: .ended(FailureDetail(.serverEnded, serverText: "maintenance window")),
            at: start + 300)
        guard case .failed(let record) = state else { return #expect(Bool(false), "\(state)") }
        #expect(record.reason == .serverEnded)
        #expect(record.serverText == "maintenance window")
        #expect(record.elapsed == .seconds(300))
    }
}
