// VPN Plus — a native macOS VPN client.
// Copyright (C) 2026 VPN Plus contributors
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

import Testing

@testable import VPNPlusCore

@Test func terminalAndTransientStatesAreDisjoint() {
    for state in TunnelState.allCases {
        #expect(!(state.isTerminal && state.isTransient))
    }
}

@Test func failedIsTheOnlyTerminalState() {
    #expect(TunnelState.allCases.filter(\.isTerminal) == [.failed])
}

/// feature-spec 3.5 — no state waits indefinitely, and 3.6 keeps the deadlines
/// in one place. These assert the shape, not the values; the values are C4's.
@Test func everyPhaseDeadlineFitsInsideTheAttemptDeadline() {
    let phases = [
        Deadlines.resolve, Deadlines.contact, Deadlines.auth,
        Deadlines.config, Deadlines.setup,
    ]
    for phase in phases {
        #expect(phase <= Deadlines.attempt)
    }
    #expect(Deadlines.phaseReveal < Deadlines.resolve)
}
