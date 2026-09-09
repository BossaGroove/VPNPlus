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

/// What this Mac's network looks like from here — the input to *"what changed
/// since it last worked"* (A7, D46).
///
/// **Local signals only** (D89, D90). No public-address lookup, because that
/// means telling a third party the user's address, that they run VPN Plus, and
/// when. No Wi-Fi name, because macOS withholds an SSID without Location
/// Services, and a VPN client asking to use your location is exactly the
/// thing the owner ruled out. The gateway's hardware address replaces the
/// network's name and is better at the job: it tells two networks called
/// `Home` apart, and it exists on Ethernet.
///
/// **The address here is the one in use, never the burned-in one** (D203,
/// feature-spec 4.11 and 4.12). Whether macOS randomised it is one bit, and
/// that bit is the whole requirement: it is what the server sees as
/// `IV_HWADDR` and therefore what a MAC allowlist judges. VPN Plus never goes
/// looking for the real address and never sends one.
public struct NetworkFacts: Codable, Sendable, Equatable {
    /// What a network is reached over. The *kind*, because `en0` is not a
    /// word anybody outside this file should read (D3).
    public enum InterfaceKind: String, Codable, Sendable {
        case wiFi
        case ethernet
        /// Reached, but over something else — Thunderbolt bridge, a tether, a
        /// virtual interface.
        case other
        /// Nothing is reaching anything.
        case none
    }

    /// When these were read. A comparison is only ever as fresh as this.
    public var at: Date
    /// The BSD name of the interface carrying the default route, for the log
    /// and the export. Never a surface (D3).
    public var interfaceName: String?
    public var interfaceKind: InterfaceKind
    /// The default gateway's address, and the hardware address behind it.
    /// Together they identify the network the Mac is actually on.
    public var gateway: String?
    public var gatewayHardwareAddress: String?
    public var subnetMask: String?
    /// The address this Mac presents on that interface — current, not
    /// genuine.
    public var hardwareAddress: String?
    /// Whether that address is locally administered, which is what macOS's
    /// Private Wi-Fi Address produces. Nil when there is no address to judge.
    public var addressIsRandomised: Bool?

    public init(
        at: Date = Date(),
        interfaceName: String? = nil,
        interfaceKind: InterfaceKind = .none,
        gateway: String? = nil,
        gatewayHardwareAddress: String? = nil,
        subnetMask: String? = nil,
        hardwareAddress: String? = nil,
        addressIsRandomised: Bool? = nil
    ) {
        self.at = at
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.gateway = gateway
        self.gatewayHardwareAddress = gatewayHardwareAddress
        self.subnetMask = subnetMask
        self.hardwareAddress = hardwareAddress
        self.addressIsRandomised = addressIsRandomised
    }

    /// Nothing is reaching a network. The provider tests this rather than
    /// concluding "the server is down" (A10 M11).
    public var hasNetwork: Bool { gateway != nil && interfaceKind != .none }

    /// Whether this is the same network as `other`.
    ///
    /// **The gateway's hardware address decides it** (D89): it identifies the
    /// actual router, so it separates two networks that share a name and
    /// works where no name exists. The gateway IP corroborates but cannot
    /// decide alone — every home router in the world is `192.168.1.1`.
    ///
    /// Nil when either side has nothing to compare, which is *unknown* and
    /// never *changed*: a row that claims a change it cannot see is worse
    /// than a row that says it does not know (D85).
    ///
    /// **A caveat carried forward from B9**: an enterprise gateway's address
    /// is often a *virtual* router MAC in the VRRP range, stable across
    /// failover but shared by every device in the pair. Good for identity,
    /// weaker for discrimination — so a match means "the same network as far
    /// as this Mac can tell", which is what the copy says.
    public func isSameNetwork(as other: NetworkFacts) -> Bool? {
        if let mine = gatewayHardwareAddress, let theirs = other.gatewayHardwareAddress {
            return mine.caseInsensitiveCompare(theirs) == .orderedSame
        }
        guard let mine = gateway, let theirs = other.gateway else { return nil }
        return mine == theirs && subnetMask == other.subnetMask
    }

    /// Whether an address is inside this network — J12, the owner's "arrived
    /// home" case: a VPN whose server is on the network the Mac is already on
    /// (A10 M13, D40). IPv4 only, which is what a mask describes.
    public func isOnThisNetwork(_ address: String) -> Bool {
        guard let gateway, let subnetMask,
            let server = Self.ipv4(address), let router = Self.ipv4(gateway),
            let mask = Self.ipv4(subnetMask), mask != 0
        else { return false }
        return server & mask == router & mask
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }
}

/// The *What changed* table (A14, the Diagnostics artboard): the five rows,
/// each one last-good against now.
///
/// **Every row, not only the changed ones.** A7's failure message shows what
/// changed; the sheet shows all five, so an unchanged environment is visible
/// as a fact rather than as an absence — and *"nothing has changed since this
/// last worked"* points at the server rather than at the Mac, which is the
/// most useful sentence in the whole feature.
///
/// Typed, and the app supplies the words (D271).
public struct NetworkComparison: Sendable, Equatable {
    public enum Row: String, Sendable, Equatable, CaseIterable {
        case when
        case interface
        case network
        case addressRandomised
        case profile
    }

    public let lastGood: NetworkFacts?
    public let now: NetworkFacts?
    /// Whether the profile's own file was replaced since the last good
    /// connection — the fifth row, and the one cause that is neither the
    /// network nor the server.
    public let profileReplaced: Bool

    public init(lastGood: NetworkFacts?, now: NetworkFacts?, profileReplaced: Bool = false) {
        self.lastGood = lastGood
        self.now = now
        self.profileReplaced = profileReplaced
    }

    /// Whether the network is the one it last worked on. Nil is unknown.
    public var isSameNetwork: Bool? {
        guard let lastGood, let now else { return nil }
        return now.isSameNetwork(as: lastGood)
    }

    /// Whether a row differs. Unknown is **not** changed (D85).
    public func changed(_ row: Row) -> Bool {
        guard let lastGood, let now else { return false }
        switch row {
        case .when:
            // Time always differs; it is context for the other rows, not a
            // change in its own right.
            return false
        case .interface:
            return lastGood.interfaceKind != now.interfaceKind
        case .network:
            return isSameNetwork == false
        case .addressRandomised:
            guard let then = lastGood.addressIsRandomised, let today = now.addressIsRandomised
            else { return false }
            return then != today
        case .profile:
            return profileReplaced
        }
    }

    public var changedRows: [Row] { Row.allCases.filter(changed) }

    /// Nothing about this Mac is different, so what is left is the server —
    /// the sentence A7 wanted most.
    public var nothingChanged: Bool { lastGood != nil && now != nil && changedRows.isEmpty }

    /// There is nothing to compare with: this profile has never connected, so
    /// the table says so rather than implying the environment is the same.
    public var hasNothingToCompare: Bool { lastGood == nil }
}
