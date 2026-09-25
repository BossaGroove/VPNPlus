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

/// The profiles the suite imports. Ordinary username-and-password profiles
/// (the shape every real one has), against a test certificate authority that
/// signs nothing anywhere. The one whose server is in the reserved `.invalid`
/// domain is the one the rehearsal fails.
enum Fixtures {
    static let office = "Rehearsal Office"
    static let home = "Rehearsal Home"
    static let broken = "Rehearsal Broken"

    /// Imported in this order, which is the cards' order.
    static let profiles: [(name: String, text: String)] = [
        (broken, profile(remote: "broken.rehearsal.invalid 1194", proto: "udp")),
        (home, profile(remote: "home.rehearsal.example 443", proto: "tcp")),
        (office, profile(remote: "office.rehearsal.example 1194", proto: "udp")),
    ]

    /// The README's screenshots (R2b): names a reader would give their own
    /// profiles, on reserved domains. Frankfurt's server is the `.invalid`
    /// one, so it is the one that fails.
    static let tokyo = "Tokyo"
    static let frankfurt = "Frankfurt"
    static let showcase: [(name: String, text: String)] = [
        ("Home", profile(remote: "home.vpn.example 443", proto: "tcp")),
        ("Office", profile(remote: "office.vpn.example 1194", proto: "udp")),
        (tokyo, profile(remote: "tokyo.vpn.example 1194", proto: "udp")),
        (frankfurt, profile(remote: "frankfurt.vpn.invalid 1194", proto: "udp")),
    ]

    /// The office profile again, reissued on another port — the replace
    /// report's "before → after" row.
    static let officeReissued = profile(remote: "office.rehearsal.example 443", proto: "udp")

    static func profile(remote: String, proto: String) -> String {
        """
        client
        dev tun
        proto \(proto)
        remote \(remote)
        <ca>
        \(certificate)
        </ca>
        auth-user-pass

        """
    }

    /// The same throwaway CA the engine tests use: a self-signed certificate
    /// for "VPN Plus test fixture CA", trusted by nothing.
    static let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIBmzCCAUGgAwIBAgIUDeu1/zNDfcHjlQXR3ljTtUVN+JEwCgYIKoZIzj0EAwIw
        IzEhMB8GA1UEAwwYVlBOIFBsdXMgdGVzdCBmaXh0dXJlIENBMB4XDTI2MDkwNzA3
        MTAyMFoXDTM2MDkwNDA3MTAyMFowIzEhMB8GA1UEAwwYVlBOIFBsdXMgdGVzdCBm
        aXh0dXJlIENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMJubOtuepsojGVjv
        Y2ov91DcgBRhuKSxP9nzxE2RYUkccuEUTT2tFxcnDTAgU41Dl62SNWe991Yit7Xg
        XnT/IaNTMFEwHQYDVR0OBBYEFD9GUUsdoUrb9lAPBk65tri5kbMKMB8GA1UdIwQY
        MBaAFD9GUUsdoUrb9lAPBk65tri5kbMKMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZI
        zj0EAwIDSAAwRQIgPfMdYXcUXI1KJvocGvc9BsXJK0WiSxdtDsH8vSfERlsCIQDQ
        bIVRcNiCqljdADj/zczMXV3EtxvnjxtlHNh8h9c50A==
        -----END CERTIFICATE-----
        """
}
