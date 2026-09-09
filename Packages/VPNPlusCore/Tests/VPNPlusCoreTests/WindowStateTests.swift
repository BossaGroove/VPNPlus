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

/// The second layer (D93). It is derived, and these tests are what "derived"
/// means: there is no combination of facts for which the window has to be told
/// separately what to show.
struct WindowStateTests {
    let profile = UUID()
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func derive(
        _ connection: Connection = .disconnected,
        profiles: Bool = true,
        setup: SetupState = .ready
    ) -> WindowState {
        WindowState.derive(connection: connection, hasProfiles: profiles, setup: setup)
    }

    /// D62: checked at launch, said before anything else — even before Empty.
    @Test func theWrongLocationOutranksEverything() {
        #expect(WindowState.derive(connection: .disconnected, hasProfiles: false, setup: .ready, misplaced: true) == .wrongLocation)
        #expect(WindowState.derive(connection: .disconnected, hasProfiles: true, setup: .blocked(nil), misplaced: true) == .wrongLocation)
        #expect(WindowState.derive(connection: .disconnected, hasProfiles: true, setup: .ready, misplaced: false) == .idle)
    }

    @Test func noProfilesIsTheEmptyScreen() {
        #expect(derive(profiles: false) == .empty)
    }

    /// A5: the empty screen says nothing about permissions, because setup is
    /// deferred to the first Connect (D59). An empty library has nothing to be
    /// blocked about.
    @Test func anEmptyLibraryIsNotAskedAboutApproval() {
        #expect(derive(profiles: false, setup: .waitingForApproval) == .empty)
        #expect(derive(profiles: false, setup: .blocked(nil)) == .empty)
        #expect(derive(profiles: false, setup: .explaining(again: false)) == .empty)
    }

    /// D65: the explanation is its own window state, before anything is asked
    /// of macOS; D66's re-approval travels with it.
    @Test func theExplanationComesBeforeThePromptAndKnowsARepeat() {
        #expect(derive(setup: .explaining(again: false)) == .setupExplain(again: false))
        #expect(derive(setup: .explaining(again: true)) == .setupExplain(again: true))
        // A live tunnel outranks it, like every setup state.
        let live = Connection.connected(Session(profile: profile, since: now))
        #expect(derive(live, setup: .explaining(again: false)) == .active)
    }

    @Test func profilesAndNothingRunningIsTheGrid() {
        #expect(derive() == .idle)
    }

    @Test func everyRunningStateIsTheSameWindowState() {
        let running: [Connection] = [
            .connecting(Attempt(profile: profile, startedAt: now)),
            .connected(Session(profile: profile, since: now)),
            .disconnecting(Teardown(profile: profile, startedAt: now)),
            .reconnecting(Attempt(profile: profile, startedAt: now, recovery: 1)),
        ]
        for connection in running {
            #expect(derive(connection) == .active, "\(connection.state)")
        }
    }

    @Test func failedIsItsOwnWindowState() {
        let record = FailureRecord(profile: profile, at: now, reason: .authenticationFailed)
        #expect(derive(.failed(record)) == .failed)
    }

    @Test func approvalOutstandingShowsWhatIsBeingWaitedOn() {
        #expect(derive(setup: .waitingForApproval) == .setup)
        #expect(derive(setup: .blocked(nil)) == .blocked)
    }

    /// The precedence that matters most, and the reason it is written down: a
    /// window saying "no profiles yet" while carrying the user's traffic is a
    /// lie, and the promoted region is the only place that can offer
    /// Disconnect.
    @Test func aLiveTunnelOutranksEveryReasonToShowSomethingElse() {
        let live = Connection.connected(Session(profile: profile, since: now))
        #expect(derive(live, profiles: false) == .active)
        #expect(derive(live, profiles: false, setup: .blocked(nil)) == .active)
        #expect(derive(live, setup: .waitingForApproval) == .active)
    }

    /// Six tunnel states, six window states, and one function between them: no
    /// combination is undefined, which is what stops a surface inventing one.
    @Test func everyCombinationHasAnAnswer() {
        let connections: [Connection] = [
            .disconnected,
            .connecting(Attempt(profile: profile, startedAt: now)),
            .connected(Session(profile: profile, since: now)),
            .disconnecting(Teardown(profile: profile, startedAt: now)),
            .reconnecting(Attempt(profile: profile, startedAt: now, recovery: 1)),
            .failed(FailureRecord(profile: profile, at: now, reason: .unknown)),
        ]
        var seen: Set<TunnelState> = []
        for connection in connections {
            seen.insert(connection.state)
            for profiles in [true, false] {
                for setup in [SetupState.ready, .waitingForApproval, .blocked(nil), .explaining(again: false)] {
                    _ = WindowState.derive(connection: connection, hasProfiles: profiles, setup: setup)
                }
            }
        }
        #expect(seen.count == TunnelState.allCases.count, "a state with no case above is untested")
    }
}
