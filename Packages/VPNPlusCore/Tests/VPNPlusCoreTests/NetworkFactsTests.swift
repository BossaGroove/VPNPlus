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

/// The differential diagnosis (A7, D46, D89): what identifies a network, what
/// counts as a change, and what the app must never claim.
struct NetworkFactsTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func facts(
        gateway: String? = "192.168.1.1",
        mac: String? = "00:00:5e:00:53:01",
        mask: String? = "255.255.255.0",
        kind: NetworkFacts.InterfaceKind = .wiFi,
        randomised: Bool? = false,
        at offset: TimeInterval = 0
    ) -> NetworkFacts {
        NetworkFacts(
            at: start + offset, interfaceName: "en0", interfaceKind: kind, gateway: gateway,
            gatewayHardwareAddress: mac, subnetMask: mask, hardwareAddress: "8a:11:22:33:44:55",
            addressIsRandomised: randomised)
    }

    // MARK: - Which network is this

    /// D89: the gateway's hardware address identifies the router, so it tells
    /// apart two networks that share an address space — which every home
    /// router on `192.168.1.1` does.
    @Test func theRoutersAddressDecidesWhichNetworkThisIs() {
        let home = facts(mac: "00:00:5e:00:53:01")
        let café = facts(mac: "de:ad:be:ef:00:01")
        #expect(home.isSameNetwork(as: home) == true)
        #expect(home.isSameNetwork(as: café) == false)
        // Same router, different address space: still the same router.
        #expect(home.isSameNetwork(as: facts(gateway: "10.0.0.1", mac: "00:00:5e:00:53:01")) == true)
    }

    @Test func withoutARouterAddressTheAddressSpaceCorroborates() {
        let mine = facts(mac: nil)
        #expect(mine.isSameNetwork(as: facts(mac: nil)) == true)
        #expect(mine.isSameNetwork(as: facts(gateway: "10.0.0.1", mac: nil)) == false)
    }

    /// D85: unknown is unknown, never "changed".
    @Test func nothingToCompareIsNotAChange() {
        let blind = NetworkFacts(at: start)
        #expect(blind.isSameNetwork(as: facts()) == nil)
        #expect(facts().isSameNetwork(as: blind) == nil)
    }

    @Test func noGatewayMeansNoNetwork() {
        #expect(facts().hasNetwork)
        #expect(!NetworkFacts(at: start).hasNetwork)
        #expect(!facts(gateway: nil, kind: .none).hasNetwork)
    }

    // MARK: - J12, the owner's "arrived home" case

    @Test func aServerInsideThisSubnetIsOnThisNetwork() {
        let home = facts(gateway: "192.168.1.1", mask: "255.255.255.0")
        #expect(home.isOnThisNetwork("192.168.1.50"))
        #expect(home.isOnThisNetwork("192.168.1.1"))
        #expect(!home.isOnThisNetwork("192.168.2.50"))
        #expect(!home.isOnThisNetwork("203.0.113.18"))
    }

    /// A wider mask, and the netmask that macOS elides to five bytes.
    @Test func theMaskIsRespected() {
        let wide = facts(gateway: "10.0.0.1", mask: "255.0.0.0")
        #expect(wide.isOnThisNetwork("10.99.99.99"))
        #expect(!wide.isOnThisNetwork("198.51.100.1"))
    }

    @Test func aHostnameOrAMissingMaskDecidesNothing() {
        #expect(!facts(mask: nil).isOnThisNetwork("192.168.1.50"))
        #expect(!facts().isOnThisNetwork("vpn.example.invalid"))
        #expect(!facts().isOnThisNetwork(""))
    }

    // MARK: - The table

    @Test func everyRowIsPresentAndOnlyRealChangesAreMarked() {
        let comparison = NetworkComparison(
            lastGood: facts(kind: .wiFi), now: facts(kind: .ethernet, at: 3600))
        #expect(NetworkComparison.Row.allCases.count == 5)
        #expect(comparison.changed(.interface))
        #expect(!comparison.changed(.network), "the same router, over a cable")
        #expect(!comparison.changed(.addressRandomised))
        #expect(!comparison.changed(.profile))
        // Time is context for the other rows, not a change of its own.
        #expect(!comparison.changed(.when))
        #expect(comparison.changedRows == [.interface])
    }

    /// The sentence A7 wanted most: nothing here changed, so look at the
    /// server.
    @Test func anUnchangedEnvironmentSaysSo() {
        let comparison = NetworkComparison(lastGood: facts(), now: facts(at: 60))
        #expect(comparison.nothingChanged)
        #expect(comparison.changedRows.isEmpty)
    }

    @Test func theOwnersOwnCasesShowUpAsRows() {
        // The MAC allowlist case: macOS turned a private address on.
        let randomised = NetworkComparison(
            lastGood: facts(randomised: false), now: facts(randomised: true, at: 60))
        #expect(randomised.changedRows == [.addressRandomised])

        // The other network case, on the same interface kind.
        let elsewhere = NetworkComparison(
            lastGood: facts(), now: facts(mac: "de:ad:be:ef:00:01", at: 60))
        #expect(elsewhere.changedRows == [.network])
    }

    @Test func aReplacedProfileIsItsOwnRow() {
        let comparison = NetworkComparison(
            lastGood: facts(), now: facts(at: 60), profileReplaced: true)
        #expect(comparison.changedRows == [.profile])
        #expect(!comparison.nothingChanged)
    }

    @Test func aProfileThatNeverConnectedHasNothingToCompare() {
        let comparison = NetworkComparison(lastGood: nil, now: facts())
        #expect(comparison.hasNothingToCompare)
        #expect(!comparison.nothingChanged, "no comparison is not a clean bill of health")
        #expect(comparison.changedRows.isEmpty)
    }

    @Test func theFactsSurviveTheStore() throws {
        let encoded = try JSONEncoder().encode(facts())
        #expect(try JSONDecoder().decode(NetworkFacts.self, from: encoded) == facts())
    }
}
