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

/// When a notification is owed, and what it says (D76, D51).
struct FailureNoticeTests {
    let profile = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)
    func name(_: UUID) -> String { "Work" }

    private func failed(_ reason: TunnelFailure = .recoveryGaveUp, attempts: Int? = 5) -> Connection {
        .failed(FailureRecord(profile: profile, at: start, reason: reason, attempts: attempts))
    }

    @Test func aFailureNobodyIsLookingAtIsNotified() throws {
        let notice = try #require(
            FailureNotice.owed(from: .disconnected, to: failed(), looking: false, name: name))
        #expect(notice.title == "Lost the connection to Work")
        #expect(notice.profile == profile)
        #expect(!notice.body.isEmpty)
        #expect(notice.body.hasSuffix("."))
    }

    @Test func aFailureOnScreenIsTheWindowsToSay() {
        #expect(FailureNotice.owed(from: .disconnected, to: failed(), looking: true, name: name) == nil)
    }

    @Test func progressIsNeverNotified() {
        let attempt = Attempt(profile: profile, startedAt: start, phase: nil, phaseEnteredAt: start)
        for state in [Connection.connecting(attempt), .reconnecting(attempt), .disconnected,
                      .connected(Session(profile: profile, since: start))] {
            #expect(FailureNotice.owed(from: .disconnected, to: state, looking: false, name: name) == nil)
        }
    }

    @Test func theSameFailureIsNotifiedOnce() {
        let state = failed()
        #expect(FailureNotice.owed(from: state, to: state, looking: false, name: name) == nil)
        // A different failure of the same profile is news again.
        #expect(FailureNotice.owed(from: state, to: failed(.serverEnded, attempts: nil), looking: false, name: name) != nil)
    }

    @Test func theBodyIsTheFirstSentenceOnly() {
        #expect(FailureNotice.firstSentence(of: "One thing. Then another.") == "One thing.")
        #expect(FailureNotice.firstSentence(of: "Only one thing") == "Only one thing")
        #expect(FailureNotice.firstSentence(of: "The server said: “No. Go away.” Then it left.") == "The server said: “No. Go away.”")
        #expect(FailureNotice.firstSentence(of: "Asked 7 times over 20 s. Then gave up.") == "Asked 7 times over 20 s.")
    }

    @Test func everyReasonMakesANoticeWithNoIdentifier() throws {
        let identifier = try Regex(#"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b"#)
        for reason in TunnelFailure.allCases {
            let notice = FailureNotice.notice(
                for: FailureRecord(profile: profile, at: start, reason: reason), name: "Work")
            #expect(!notice.title.isEmpty && !notice.body.isEmpty, "\(reason)")
            #expect(!notice.title.contains(identifier) && !notice.body.contains(identifier), "\(reason)")
        }
    }
}
