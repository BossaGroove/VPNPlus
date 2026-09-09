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

/// The two things B9 got wrong the first time, and the one bit the whole
/// randomised-address feature rests on.
struct NetworkFactsReaderTests {
    /// D91: the locally-administered bit of the first octet. Set means macOS
    /// made the address up.
    @Test func theLocallyAdministeredBitIsTheWholeTest() {
        #expect(NetworkFactsReader.isLocallyAdministered("02:00:5e:00:53:77") == true)
        #expect(NetworkFactsReader.isLocallyAdministered("00:00:5e:00:53:f0") == false)
        // Every second nibble value with the 0x02 bit set, and one without.
        #expect(NetworkFactsReader.isLocallyAdministered("02:00:00:00:00:00") == true)
        #expect(NetworkFactsReader.isLocallyAdministered("00:00:00:00:00:00") == false)
        #expect(NetworkFactsReader.isLocallyAdministered("de:ad:be:ef:00:01") == true)
    }

    @Test func anAddressItCannotReadDecidesNothing() {
        #expect(NetworkFactsReader.isLocallyAdministered("") == nil)
        #expect(NetworkFactsReader.isLocallyAdministered("zz:00") == nil)
    }

    /// **macOS elides trailing zero bytes in a netmask `sockaddr`**: `sa_len`
    /// can be 5, so parsing it as a whole `sockaddr_in` returns nothing and a
    /// `/8` reads as "no subnet" — which looked like an API that does not
    /// work. The bytes are `sa_len`, `sa_family`, two of port, then as much of
    /// the address as is not zero.
    @Test func aNetmaskIsRebuiltFromWhatMacOSActuallyStores() {
        // /24: five bytes, one of them the mask.
        #expect(NetworkFactsReader.mask(fromSockaddr: [5, 2, 0, 0, 255]) == "255.0.0.0")
        // /16 and /24 as macOS stores them.
        #expect(NetworkFactsReader.mask(fromSockaddr: [6, 2, 0, 0, 255, 255]) == "255.255.0.0")
        #expect(
            NetworkFactsReader.mask(fromSockaddr: [7, 2, 0, 0, 255, 255, 255]) == "255.255.255.0")
        // A full sixteen-byte sockaddr still reads correctly.
        #expect(
            NetworkFactsReader.mask(
                fromSockaddr: [16, 2, 0, 0, 255, 255, 254, 0, 0, 0, 0, 0, 0, 0, 0, 0])
                == "255.255.254.0")
    }

    @Test func tooFewBytesIsNoAnswer() {
        #expect(NetworkFactsReader.mask(fromSockaddr: [0, 2]) == nil)
    }

    /// It runs on this Mac, unprivileged, with no prompt and no network call.
    /// The values belong to whichever machine this is, so what is asserted is
    /// the shape: a reading either sees a network or honestly says it does
    /// not.
    @Test func readingThisMacIsCoherent() {
        let facts = NetworkFactsReader.read()
        if facts.hasNetwork {
            #expect(facts.gateway != nil)
            #expect(facts.interfaceKind != .none)
            #expect(facts.interfaceName != nil)
            // The bit is readable wherever there is an address to judge.
            if facts.hardwareAddress != nil { #expect(facts.addressIsRandomised != nil) }
        } else {
            #expect(facts.interfaceKind == .none)
        }
    }
}
