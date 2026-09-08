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

/// D134's file rules. What matters here is that each refusal is *its own*
/// refusal: the sheet says something different for each, and "invalid file"
/// is not one of the answers (2.10).
struct ClientCertificateFileTests {
    private func pem(_ label: String, _ body: String = "AAAA") -> String {
        "-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----"
    }

    @Test func aCertificateAndKeyInOneFileIsAccepted() throws {
        let text = pem("CERTIFICATE", "Y2VydA==") + "\n" + pem("PRIVATE KEY", "a2V5")
        let identity = try ClientCertificateFile.read(text).get()
        #expect(String(decoding: identity.certificate, as: UTF8.self).contains("Y2VydA=="))
        #expect(String(decoding: identity.privateKey, as: UTF8.self).contains("a2V5"))
        // The key must not travel inside the certificate: they are two
        // secrets, stored under two accounts.
        #expect(!String(decoding: identity.certificate, as: UTF8.self).contains("PRIVATE KEY"))
    }

    /// A chain is normal, and all of it is kept: openvpn3 is handed `cert`
    /// with intermediates, exactly as an inline block would carry them.
    @Test func everyCertificateInAChainIsKept() throws {
        let text = [pem("CERTIFICATE", "bGVhZg=="), pem("CERTIFICATE", "aW50ZXI="),
                    pem("PRIVATE KEY")].joined(separator: "\n")
        let identity = try ClientCertificateFile.read(text).get()
        let certificate = String(decoding: identity.certificate, as: UTF8.self)
        #expect(certificate.contains("bGVhZg=="))
        #expect(certificate.contains("aW50ZXI="))
    }

    /// `RSA PRIVATE KEY` and `EC PRIVATE KEY` are the same thing to us, which
    /// is why the label is matched by suffix.
    @Test func anRSAOrECKeyIsStillAKey() throws {
        for label in ["RSA PRIVATE KEY", "EC PRIVATE KEY", "ENCRYPTED PRIVATE KEY"] {
            let text = pem("CERTIFICATE") + "\n" + pem(label)
            #expect(throws: Never.self) { try ClientCertificateFile.read(text).get() }
        }
    }

    @Test func aCertificateWithNoKeyIsRefusedForThatReason() {
        let outcome = ClientCertificateFile.read(pem("CERTIFICATE"))
        #expect(outcome == .failure(.noPrivateKey))
    }

    @Test func aKeyWithNoCertificateIsRefusedForThatReason() {
        let outcome = ClientCertificateFile.read(pem("PRIVATE KEY"))
        #expect(outcome == .failure(.noCertificate))
    }

    /// Not "invalid file": nothing in it looks like PEM at all, and the user
    /// is told that rather than being told their certificate is broken.
    @Test func somethingThatIsNotPEMIsRefusedAsSuch() {
        #expect(ClientCertificateFile.read("just some text") == .failure(.unreadable))
        #expect(ClientCertificateFile.read("") == .failure(.unreadable))
    }
}

extension Result: @retroactive Equatable
where Success == ClientCertificateFile.Identity, Failure == ClientCertificateFile.Refusal {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.failure(l), .failure(r)): l == r
        case let (.success(l), .success(r)):
            l.certificate == r.certificate && l.privateKey == r.privateKey
        default: false
        }
    }
}
