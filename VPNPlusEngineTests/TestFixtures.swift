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

    /// "setenv CLIENT_CERT 0" is how openvpn3 is told that a profile carries no
    /// client certificate on purpose; without it, building the client options
    /// throws "option 'cert' not found".
    static let minimalProfile = """
client
dev tun
proto udp
remote vpn.example.invalid 1194
setenv CLIENT_CERT 0
<ca>
\(certificate)
</ca>
auth-user-pass

"""
}
