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

/// A certificate file the user chose for one profile (D134), read into the two
/// PEM blocks the engine needs.
///
/// **It insists on both the certificate and its key, in one file.** That is a
/// rule rather than a limitation, and it comes from what happens otherwise:
/// once the extension owns a profile the app cannot read it again (D218), so
/// the app does not know whether the profile carries a key of its own. Accept a
/// certificate alone and the likely outcome is a connection that fails inside
/// the engine with `option 'key' not found` — a control that leads nowhere,
/// which is the anti-pattern A13a names. Refusing at the file picker, by name,
/// is the honest half of the same information.
public enum ClientCertificateFile {
    public struct Identity {
        /// Every CERTIFICATE block, in file order: a chain is normal.
        public let certificate: Data
        public let privateKey: Data
    }

    public enum Refusal: Error, Equatable {
        /// A `.p12` or `.pfx`. openvpn3 built against OpenSSL has no pkcs12
        /// path at all (D239), so this can never work and is said outright
        /// rather than failing at connect time.
        case keystoreNotSupported
        case noCertificate
        /// A certificate, but no key beside it.
        case noPrivateKey
        case unreadable
    }

    public static func read(_ url: URL) -> Result<Identity, Refusal> {
        let suffix = url.pathExtension.lowercased()
        if suffix == "p12" || suffix == "pfx" { return .failure(.keystoreNotSupported) }
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return .failure(.unreadable) }
        return read(text)
    }

    /// The same decision, on text. Separate so the rules can be tested without
    /// a filesystem — the rules are the part that has to be right.
    public static func read(_ text: String) -> Result<Identity, Refusal> {
        let certificates = blocks(in: text, labelled: "CERTIFICATE")
        guard !certificates.isEmpty else {
            // A DER file reaches here too: real, and unreadable *as PEM*,
            // which is the only form the engine is given.
            return .failure(text.contains("-----BEGIN") ? .noCertificate : .unreadable)
        }
        let keys = blocks(in: text, labelled: "PRIVATE KEY")
        guard let key = keys.first else { return .failure(.noPrivateKey) }
        return .success(
            Identity(
                certificate: Data(certificates.joined(separator: "\n").utf8),
                privateKey: Data(key.utf8)))
    }

    /// The PEM blocks whose label ends in `labelled`, so `RSA PRIVATE KEY` and
    /// `EC PRIVATE KEY` are found by asking for `PRIVATE KEY`.
    private static func blocks(in text: String, labelled labelSuffix: String) -> [String] {
        var found: [String] = []
        var current: [String] = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-----BEGIN "), trimmed.hasSuffix("-----") {
                let label = String(
                    trimmed.dropFirst("-----BEGIN ".count).dropLast("-----".count))
                inside = label.hasSuffix(labelSuffix)
                if inside { current = [trimmed] }
                continue
            }
            if inside, trimmed.hasPrefix("-----END ") {
                current.append(trimmed)
                found.append(current.joined(separator: "\n"))
                current = []
                inside = false
                continue
            }
            if inside, !trimmed.isEmpty { current.append(trimmed) }
        }
        return found
    }
}
