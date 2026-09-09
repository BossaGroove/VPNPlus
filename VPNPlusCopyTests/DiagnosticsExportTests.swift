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

/// What leaves the app as text: both layers, and no secret (A14 §3, D87, D138).
struct DiagnosticsExportTests {
    let profile = UUID()
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func record() -> DiagnosticsLog {
        var log = DiagnosticsLog(profile: profile)
        log.begin(recovery: 0, at: start)
        log.add(.phase("config"), identifier: "GET_CONFIG", at: start + 4)
        log.add(.engine("Sending PUSH_REQUEST to server..."), at: start + 4)
        // A line that should never have been logged, and which the sink would
        // already have caught — the export re-checks anyway.
        log.add(.engine("password=hunter2 leaked here"), at: start + 5)
        log.add(.gaveUp(phase: "config", seconds: 20), at: start + 24)
        log.add(.failed(.settingsNeverSent, waited: 20, requests: 7), at: start + 24)
        log.finish(.failed(.settingsNeverSent), at: start + 24)
        return log
    }

    @Test func bothLayersAreInTheExportAndOnlyOneIsOnScreen() {
        let text = DiagnosticsExport.text(
            profileName: "Work", record: record(), comparison: nil, message: nil, at: start)
        // Our phrase, with the identifier the screen never shows.
        #expect(text.contains("Waiting for connection settings  [GET_CONFIG]"))
        // The engine's own line.
        #expect(text.contains("› Sending PUSH_REQUEST to server..."))
        // The artboard's own sentence.
        #expect(text.contains("Gave up waiting for connection settings after 20 seconds"))
        // The footer's promise.
        #expect(text.hasSuffix("Passwords and keys are removed."))
    }

    @Test func aSecretDoesNotLeaveTheApp() {
        let text = DiagnosticsExport.text(
            profileName: "Work", record: record(), comparison: nil, message: nil, at: start)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("password=[removed]"))
    }

    @Test func theMessageAndTheComparisonStandOnTheirOwn() {
        let facts = NetworkFacts(
            at: start - 7200, interfaceKind: .wiFi, gateway: "192.168.1.1",
            gatewayHardwareAddress: "00:00:5e:00:53:01", subnetMask: "255.255.255.0",
            addressIsRandomised: false)
        var now = facts
        now.at = start
        now.interfaceKind = .ethernet
        let comparison = NetworkComparison(lastGood: facts, now: now)
        let failure = FailureRecord(
            profile: profile, at: start + 24, reason: .settingsNeverSent, phase: "config",
            waited: .seconds(20), attempts: 7)
        let message = FailureCopy.message(failure, name: "Work", comparison: comparison)
        let text = DiagnosticsExport.text(
            profileName: "Work", record: record(), comparison: comparison, message: message, at: start)
        #expect(text.contains("Couldn't finish connecting to Work"))
        #expect(text.contains("Common causes"))
        #expect(text.contains("Interface: Wi-Fi → Ethernet *"))
        #expect(text.contains("You're on Ethernet now"))
    }

    /// D290: what the owner's export got wrong, read as a stranger.
    @Test func theExportSpeaksInWordsNotCodes() {
        var log = DiagnosticsLog(profile: profile)
        log.begin(
            recovery: 0, at: start,
            facts: NetworkFacts(
                at: start, interfaceKind: .wiFi, gateway: "192.0.2.1",
                gatewayHardwareAddress: "00:00:5e:00:53:01", subnetMask: "255.255.255.0",
                addressIsRandomised: false))
        log.add(.connected, at: start + 5)
        log.add(.dropped, at: start + 40)
        log.add(.tryingAgain(attempt: 1, of: 5, seconds: 4), at: start + 40)
        log.finish(.retried, at: start + 40)
        let text = DiagnosticsExport.text(
            profileName: "Work", record: log, comparison: nil, message: nil, at: start)
        #expect(text.contains("Network: Wi-Fi, gateway 192.0.2.1, address randomised: no"))
        #expect(!text.contains("wiFi"))
        #expect(text.contains("The connection dropped"))
        #expect(text.contains("· retried"))
    }

    @Test func anEmptyRecordSaysSo() {
        let text = DiagnosticsExport.text(
            profileName: "Work", record: DiagnosticsLog(profile: profile), comparison: nil,
            message: nil, at: start)
        #expect(text.contains("No connection attempts recorded yet."))
    }
}
