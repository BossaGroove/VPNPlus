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

/// The sink redacts, and the engine is not trusted to (D199, feature-spec 4.8).
///
/// The fixture is a profile of the shape that makes this necessary: an inline
/// private key and an inline `auth-user-pass` block, either of which is
/// unrecoverable once leaked.
struct RedactionTests {
    static let profile = """
        client
        dev tun
        remote vpn.example.invalid 1194
        auth-user-pass
        <ca>
        -----BEGIN CERTIFICATE-----
        MIIBkTCB+wIBADANBgkqhkiG9w0BAQQFADASMRAwDgYDVQQDEwdleGFtcGxl
        -----END CERTIFICATE-----
        </ca>
        <key>
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDPRIVATEKEY
        -----END PRIVATE KEY-----
        </key>
        <auth-user-pass>
        alex
        hunter2
        </auth-user-pass>
        """

    @Test func aProfileLosesItsKeyAndItsPasswordAndKeepsTheRest() {
        let scrubbed = Redactor.scrub(Self.profile)
        // The two things that must never survive.
        #expect(!scrubbed.contains("MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDPRIVATEKEY"))
        #expect(!scrubbed.contains("hunter2"))
        // Said out loud rather than silently missing (D87 applied to the log).
        #expect(scrubbed.contains(Redactor.Marker.privateKey))
        #expect(scrubbed.contains(Redactor.Marker.credentials))
        // A certificate is public, and a diagnosis often turns on it.
        #expect(scrubbed.contains("-----BEGIN CERTIFICATE-----"))
        #expect(scrubbed.contains("MIIBkTCB+wIBADANBgkqhkiG9w0BAQQFADASMRAwDgYDVQQDEwdleGFtcGxl"))
        // And the diagnosis itself survives.
        #expect(scrubbed.contains("remote vpn.example.invalid 1194"))
        #expect(scrubbed.contains("auth-user-pass"))
    }

    /// The engine hands us one line at a time, and a key's body has nothing in
    /// it to recognise — so the state is the whole mechanism.
    @Test func aKeyArrivingLineByLineIsDroppedUntilItCloses() {
        var redactor = Redactor()
        #expect(redactor.scrub("Frame=512/2112/512") == "Frame=512/2112/512")
        #expect(redactor.scrub("-----BEGIN RSA PRIVATE KEY-----") == Redactor.Marker.privateKey)
        #expect(redactor.scrub("MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEA") == nil)
        #expect(redactor.scrub("AoIBAQDPRIVATEKEYMATERIALHERE") == nil)
        #expect(redactor.scrub("-----END RSA PRIVATE KEY-----") == nil)
        // And the stream carries on.
        #expect(redactor.scrub("Session is ACTIVE") == "Session is ACTIVE")
    }

    @Test func aWholeBlockInsideOneLineIsRemovedInPlace() {
        var redactor = Redactor()
        let line = "stored profile: <key>MIIEvSECRET</key> and the rest"
        let scrubbed = redactor.scrub(line)
        #expect(scrubbed == "stored profile: \(Redactor.Marker.privateKey) and the rest")
        #expect(scrubbed?.contains("MIIEvSECRET") == false)
    }

    @Test func aStaticKeyIsRemovedToo() {
        let text = """
            <tls-crypt>
            -----BEGIN OpenVPN Static key V1-----
            6acef03f62675b4b1bbd03e53b187727
            -----END OpenVPN Static key V1-----
            </tls-crypt>
            """
        let scrubbed = Redactor.scrub(text)
        #expect(!scrubbed.contains("6acef03f62675b4b1bbd03e53b187727"))
        #expect(scrubbed.contains(Redactor.Marker.staticKey))
    }

    // MARK: - Values on one line

    @Test func aValueAfterASeparatorGoes() {
        #expect(Redactor.scrub("password=hunter2") == "password=[removed]")
        #expect(Redactor.scrub("Password: hunter2") == "Password: [removed]")
        #expect(Redactor.scrub("passphrase = swordfish") == "passphrase = [removed]")
    }

    /// The first version matched a bare word and ate our own prose. A mangled
    /// diagnostic is its own defect, so a separator is required.
    @Test func ourOwnProseIsLeftAlone() {
        let lines = [
            "the session token was refused; trying the password behind it",
            "signing in with the saved password",
            "Creds: Username/Password",
            "this profile needs sign-in details and there are none to offer",
        ]
        for line in lines {
            #expect(Redactor.scrub(line) == line)
        }
    }

    /// What the engine logs about a connection, which is the diagnosis: the
    /// account, the server, the address it sent. The footer says *passwords
    /// and keys*, and means exactly that.
    @Test func theDiagnosisSurvives() {
        let lines = [
            "event CONNECTED alex@192.0.2.10:443 (192.0.2.10) via /TCP on tun/10.8.0.2/",
            "IV_HWADDR=00:00:5e:00:53:f0",
            "Contacting 192.0.2.10:443 via TCP",
            "PROTOCOL OPTIONS: cipher AES-256-GCM, peer-id 0",
        ]
        for line in lines {
            #expect(Redactor.scrub(line) == line)
        }
    }

    @Test func aPushedTokenGoes() {
        #expect(Redactor.scrub("auth-token SESSIONTOKENVALUE") == "auth-token [removed]")
        // openvpn3 sanitises this one itself; D199 is the rule that we do not
        // depend on that, and its own output must survive unharmed.
        #expect(Redactor.scrub("0 [auth-token] ...") == "0 [auth-token] ...")
    }

    /// A truncated key block must not cost the rest of the log.
    @Test func aBlockThatNeverClosesGivesUpRatherThanSwallowingEverything() {
        var redactor = Redactor()
        #expect(redactor.scrub("<key>") == Redactor.Marker.privateKey)
        var lines: [String?] = []
        for index in 0..<260 { lines.append(redactor.scrub("MIIEv\(index)")) }
        // Swallowed while it might still have been a key…
        #expect(lines[0..<200].allSatisfy { $0 == nil })
        // …then it gives up and says why…
        #expect(lines[200] == Redactor.Marker.unclosed)
        // …and the log carries on, which is the whole point of the bound.
        #expect(lines[201] == "MIIEv201")
        #expect(redactor.scrub("Session is ACTIVE") == "Session is ACTIVE")
    }

    /// Scrubbing something already scrubbed changes nothing — the export
    /// re-checks what the sink already filtered (D87).
    @Test func scrubbingIsIdempotent() {
        let once = Redactor.scrub(Self.profile)
        #expect(Redactor.scrub(once) == once)
    }
}
