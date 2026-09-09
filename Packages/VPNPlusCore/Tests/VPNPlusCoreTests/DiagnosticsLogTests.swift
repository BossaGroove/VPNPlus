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

/// The record: one attempt per attempt, bounded, and two layers in one stream
/// (M6.2, D138, D140).
struct DiagnosticsLogTests {
    let profile = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// The ladder, as the provider writes it.
    private func ladder() -> DiagnosticsLog {
        var log = DiagnosticsLog(profile: profile)
        log.begin(recovery: 0, at: start)
        log.add(.phase("resolve"), identifier: "RESOLVE", at: start + 1)
        log.add(.engine("Contacting 192.0.2.10:443 via TCP"), at: start + 1)
        log.add(.phase("contact"), identifier: "WAIT", at: start + 1)
        log.add(.gaveUp(phase: "contact", seconds: 15), at: start + 16)
        log.add(.failed(.serverUnreachable, waited: 15, requests: nil), at: start + 16)
        log.finish(.failed(.serverUnreachable), at: start + 16)
        return log
    }

    @Test func anAttemptCarriesWhatHappenedInIt() throws {
        let log = ladder()
        #expect(log.attempts.count == 1)
        let attempt = try #require(log.latest)
        #expect(attempt.number == 1)
        #expect(attempt.outcome == .failed(.serverUnreachable))
        #expect(attempt.duration == .seconds(16))
        // Began, resolve, an engine line, contact, gave up, failed.
        #expect(attempt.entries.count == 6)
    }

    /// D138: our prose on screen, the engine's in the export, one stream.
    @Test func theEnginesOwnLinesAreNeverOnScreen() {
        let log = ladder()
        let shown = log.forScreen().flatMap(\.entries)
        #expect(shown.count == 5)
        let anyEngineOnScreen = shown.filter { !$0.kind.isForScreen }
        #expect(anyEngineOnScreen.isEmpty)
        // And the export still has it.
        let kinds = log.attempts.flatMap(\.entries).map(\.kind)
        #expect(kinds.contains(.engine("Contacting 192.0.2.10:443 via TCP")))
    }

    /// The artboard's `All ▾` filter.
    @Test func problemsOnlyKeepsWhatWentWrong() {
        let shown = ladder().forScreen(problemsOnly: true).flatMap(\.entries)
        #expect(shown.count == 2)
        let notProblems = shown.filter { !$0.kind.isProblem }
        #expect(notProblems.isEmpty)
    }

    /// D290: a drop is on screen and a problem; a retried attempt is closed.
    @Test func aDropIsAProblemAndARetriedAttemptIsOver() {
        var log = DiagnosticsLog(profile: profile)
        log.begin(recovery: 0, at: start)
        log.add(.connected, at: start + 5)
        log.add(.dropped, at: start + 40)
        log.add(.tryingAgain(attempt: 1, of: 5, seconds: 4), at: start + 40)
        log.finish(.retried, at: start + 40)
        #expect(DiagnosticsEntry.Kind.dropped.isForScreen)
        #expect(DiagnosticsEntry.Kind.dropped.isProblem)
        #expect(log.latest?.outcome == .retried)
        #expect(!log.isAttemptOpen)
    }

    @Test func attemptsAreNumberedAndTheOldestIsDropped() {
        var log = DiagnosticsLog(profile: profile)
        for index in 0..<(DiagnosticsRetention.attempts + 3) {
            log.begin(recovery: index, at: start + Double(index))
            log.finish(.cancelled, at: start + Double(index))
        }
        #expect(log.attempts.count == DiagnosticsRetention.attempts)
        // Numbering keeps counting: the sheet's header must not renumber an
        // attempt the user has already read.
        #expect(log.attempts.first?.number == 4)
        #expect(log.attempts.last?.number == DiagnosticsRetention.attempts + 3)
    }

    @Test func theEntryCapIsBoundedAndSaysSo() throws {
        var log = DiagnosticsLog(profile: profile)
        log.begin(recovery: 0, at: start)
        for index in 0..<(DiagnosticsRetention.entriesPerAttempt + 50) {
            log.add(.engine("line \(index)"), at: start)
        }
        let entries = try #require(log.latest?.entries)
        #expect(entries.count == DiagnosticsRetention.entriesPerAttempt + 1)
        #expect(entries.last?.kind == .truncated)
        // Once, not once per dropped line.
        let truncated = entries.filter { $0.kind == .truncated }
        #expect(truncated.count == 1)
    }

    /// A session that drops belongs to the attempt that established it, so a
    /// late entry appends rather than vanishing.
    @Test func anEntryAfterTheOutcomeStaysWithItsAttempt() {
        var log = DiagnosticsLog(profile: profile)
        log.begin(recovery: 0, at: start)
        log.finish(.connected, at: start + 5)
        log.add(.networkLost, at: start + 60)
        #expect(log.attempts.count == 1)
        #expect(log.latest?.entries.last?.kind == .networkLost)
        #expect(log.latest?.outcome == .connected, "the outcome is not rewritten")
    }

    @Test func anEntryWithNoAttemptOpensOne() {
        var log = DiagnosticsLog(profile: profile)
        log.add(.disconnected, at: start)
        #expect(log.attempts.count == 1)
        #expect(log.latest?.entries.map(\.kind) == [.attemptBegan, .disconnected])
    }

    /// The engine can report a fatal event and then exit, and both end the
    /// attempt. The first outcome is the true one.
    @Test func theSecondOutcomeIsIgnored() {
        var log = ladder()
        log.finish(.cancelled, at: start + 20)
        #expect(log.latest?.outcome == .failed(.serverUnreachable))
        #expect(log.latest?.endedAt == start + 16)
        #expect(!log.isAttemptOpen)
    }

    @Test func theRecordSurvivesTheDiskRoundTrip() throws {
        let log = ladder()
        let data = try JSONEncoder().encode(log)
        let back = try JSONDecoder().decode(DiagnosticsLog.self, from: data)
        #expect(back == log)
        #expect(back.version == DiagnosticsLog.currentVersion)
        #expect(back.profile == profile)
    }
}
