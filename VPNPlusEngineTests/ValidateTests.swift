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

import Testing

/// D189: import validation runs the connect-time parse with no network. These
/// tests pin that the shim rejects what eval_config alone would accept, and
/// accepts a minimal working profile.
struct ValidateTests {
    /// A throwaway self-signed certificate generated for these tests. It
    /// signs nothing anywhere; the profile only needs a parseable <ca>.
    /// `setenv CLIENT_CERT 0` is openvpn3's way of saying the profile carries
    /// no client certificate on purpose.
    static let fixtureCA = """
-----BEGIN CERTIFICATE-----
MIIBmjCCAUGgAwIBAgIUc926p5YeVBn0yj1FxYcB8mkyo1gwCgYIKoZIzj0EAwIw
IzEhMB8GA1UEAwwYVlBOIFBsdXMgdGVzdCBmaXh0dXJlIENBMB4XDTI2MDkwNzAx
NTY1MloXDTM2MDkwNDAxNTY1MlowIzEhMB8GA1UEAwwYVlBOIFBsdXMgdGVzdCBm
aXh0dXJlIENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAExjwoFwyXY8PMXWPk
Kodcx/C13HXXK0dZkYraadCwNQGysCb9oVa8akiD14Y3MU5sudKPwGQHKyYm3+Ld
0rLFw6NTMFEwHQYDVR0OBBYEFPzG3VMUp91jKgCK1k+nbR9VUJ7kMB8GA1UdIwQY
MBaAFPzG3VMUp91jKgCK1k+nbR9VUJ7kMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZI
zj0EAwIDRwAwRAIgIcqfnlJlA5ltAiT2NutHyjKCZ8R8pk1mCbuQi7oNrU0CIFZT
OzsLkWVH4Zz5/upT5zYFDjE8zt5xdq8A45u4WK+P
-----END CERTIFICATE-----
"""

    static let minimalProfile = """
client
dev tun
proto udp
remote vpn.example.invalid 1194
setenv CLIENT_CERT 0
<ca>
\(fixtureCA)
</ca>
auth-user-pass

"""

    private func validate(_ profile: String) -> (ok: Bool, message: String) {
        var buffer = [CChar](repeating: 0, count: 1024)
        let ok = vpnplus_engine_validate(profile, &buffer, buffer.count)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return (ok, String(decoding: bytes, as: UTF8.self))
    }

    @Test func engineReportsItsVersion() {
        #expect(String(cString: vpnplus_engine_version()) == "3.11.7")
    }

    @Test func minimalProfileIsAccepted() {
        let result = validate(Self.minimalProfile)
        #expect(result.ok, "rejected: \(result.message)")
    }

    @Test func staticKeyModeIsRejectedWithAReason() {
        // B7: passes eval_config clean, thrown only when ClientOptions is built.
        let result = validate(Self.minimalProfile + "secret static.key\n")
        #expect(!result.ok)
        #expect(result.message.lowercased().contains("static key"), "\(result.message)")
    }

    @Test func unknownDirectiveIsRejected() {
        let result = validate(Self.minimalProfile + "bikeshed-color green\n")
        #expect(!result.ok)
        #expect(!result.message.isEmpty)
    }

    @Test func serverModeIsRejected() {
        let result = validate(Self.minimalProfile + "mode server\n")
        #expect(!result.ok)
    }

    @Test func emptyProfileIsRejected() {
        #expect(!validate("").ok)
    }
}
