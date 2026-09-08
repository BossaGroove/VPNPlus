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

/// Profile text these tests share. The certificate is a throwaway self-signed
/// one generated for the fixture: it signs nothing anywhere, and the profile
/// only needs a parseable <ca> block.
enum TestFixtures {
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

    /// A profile that authenticates with a username and password alone, which
    /// is the ordinary shape and carries no client certificate.
    ///
    /// It deliberately does **not** carry the `CLIENT_CERT` marker. This
    /// fixture used to, because without it openvpn3 throws
    /// "option 'cert' not found" — and that marker, added here to make the
    /// tests pass, is why the app refused every real password-only profile
    /// until M5.6. Real profiles do not carry it, so neither does this one,
    /// and the whole suite exercises the boundary that decides it instead.
    static let minimalProfile = """
client
dev tun
proto udp
remote vpn.example.invalid 1194
<ca>
\(certificate)
</ca>
auth-user-pass

"""
}
