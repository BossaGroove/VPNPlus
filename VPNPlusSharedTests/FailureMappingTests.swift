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

/// The one table where A9's event names meet A10's message codes (M6.1, D270).
/// Written now that something compiles `VPNPlusShared` for tests.
struct FailureMappingTests {
    @Test func anEventBecomesTheMessageItsRemedyBelongsTo() {
        #expect(TunnelFailure.forEvent("AUTH_FAILED") == .authenticationFailed)
        #expect(TunnelFailure.forEvent("CONNECTION_TIMEOUT") == .serverUnreachable)
        #expect(TunnelFailure.forEvent("TLS_ALERT_CERTIFICATE_EXPIRED") == .certificateExpired)
        #expect(TunnelFailure.forEvent("CLIENT_HALT") == .serverEnded)
        #expect(TunnelFailure.forEvent("INACTIVE_TIMEOUT") == .idleTimeout)
        // D103: distinct events sharing a remedy share a message.
        #expect(TunnelFailure.forEvent("COMPRESS_ERROR") == .unsupportedRequirement)
        #expect(TunnelFailure.forEvent("RELAY_ERROR") == .unsupportedRequirement)
    }

    /// D98: the engine's severity is data, not a decision. These four sit in
    /// its fatal block and are requests for input; reaching the table at all
    /// means nobody could be asked, which is M21.
    @Test func thePromptsAreNotCatastrophes() {
        #expect(TunnelFailure.forEvent("NEED_CREDS") == .credentialsUnavailable)
        #expect(TunnelFailure.forEvent("DYNAMIC_CHALLENGE") == .credentialsUnavailable)
        #expect(TunnelFailure.forEvent("PROXY_NEED_CREDS") == .credentialsUnavailable)
    }

    /// D85: an event this build has never heard of is unknown, honestly.
    @Test func anUnknownEventIsUnknown() {
        #expect(TunnelFailure.forEvent("SOME_FUTURE_EVENT") == .unknown)
        #expect(TunnelFailure.forEvent("") == .unknown)
    }

    /// A9 source 2: a stall is a mode with an identity, and the phase is what
    /// gives it one (D100).
    @Test func eachStallIsItsOwnMode() {
        #expect(TunnelFailure.forStall(in: .findingServer) == .serverNotFound)
        #expect(TunnelFailure.forStall(in: .contactingServer) == .serverUnreachable)
        #expect(TunnelFailure.forStall(in: .waitingForSettings) == .settingsNeverSent)
        #expect(TunnelFailure.forStall(in: .settingUp) == .setupFailed)
    }

    /// D104: server text is quoted and attributed, and only where the words
    /// really are the server's.
    @Test func onlyTheServersOwnWordsTravelAsQuotable() {
        let halt = FailureDetail.forEvent("CLIENT_HALT", info: "maintenance window")
        #expect(halt.serverText == "maintenance window")
        #expect(halt.detail == "CLIENT_HALT: maintenance window")

        let refused = FailureDetail.forEvent("AUTH_FAILED", info: "bad username")
        #expect(refused.serverText == nil, "the engine's words are not the server's")
        #expect(refused.detail == "AUTH_FAILED: bad username")
    }

    /// Feature-spec 4.10: how long, and how many times.
    @Test func aStallCarriesItsNumbers() {
        let stall = FailureDetail.forStall(in: .waitingForSettings, waited: 20, requests: 7)
        #expect(stall.reason == .settingsNeverSent)
        #expect(stall.waited == .seconds(20))
        #expect(stall.attempts == 7)
    }
}
