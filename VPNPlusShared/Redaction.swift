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

/// The redacting sink (D199, feature-spec 4.8 and 4.9).
///
/// **The sink redacts; the engine is not trusted to.** openvpn3 sanitises
/// exactly one directive — `auth-token` — plus control-channel text, and its
/// `handle_unused_options` *truncates* option contents to 64 characters, which
/// is not redaction (B9). So every line is scrubbed **before it is kept**,
/// there is one stream, and no unredacted copy exists anywhere to leak later.
///
/// **What is removed:** private keys and any other PEM key block, OpenVPN
/// static keys, the bodies of the inline blocks that carry either, and
/// anything that reads as a password, passphrase or token value.
///
/// **What is kept, deliberately:** certificates — public, and a diagnosis
/// often turns on them — hostnames, addresses, the interface's hardware
/// address (D178 wants it recorded), and the **username**. The Diagnostics
/// footer says *"Passwords and keys are removed"* and means precisely that:
/// whoever runs the VPN needs to know which account this was, and A10 M1's
/// entire remedy is about that account.
///
/// Stateful, because a key block spans lines and its body is base64 with
/// nothing in it to recognise: once a block opens, every line is dropped
/// until it closes. A whole block arriving inside one line is handled too.
struct Redactor {
    /// What replaces a block, so the log says something was removed rather
    /// than quietly missing it (D87's "say so" applied to the log itself).
    enum Marker {
        static let privateKey = "[private key removed]"
        static let staticKey = "[static key removed]"
        static let credentials = "[credentials removed]"
        static let value = "[removed]"
        /// A block that never closed: the log resumes rather than ending
        /// there, and the reader is told why it has a hole in it.
        static let unclosed = "[removed — a block in the log never closed]"
    }

    /// PEM and inline-block openings, each with what closes it and what the
    /// log says instead. Certificates are absent on purpose.
    private static let blocks: [(open: String, close: String, marker: String)] = [
        ("-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----", Marker.privateKey),
        ("-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", Marker.privateKey),
        ("-----BEGIN EC PRIVATE KEY-----", "-----END EC PRIVATE KEY-----", Marker.privateKey),
        (
            "-----BEGIN ENCRYPTED PRIVATE KEY-----", "-----END ENCRYPTED PRIVATE KEY-----",
            Marker.privateKey
        ),
        ("-----BEGIN OPENSSH PRIVATE KEY-----", "-----END OPENSSH PRIVATE KEY-----", Marker.privateKey),
        (
            "-----BEGIN OpenVPN Static key V1-----", "-----END OpenVPN Static key V1-----",
            Marker.staticKey
        ),
        ("<key>", "</key>", Marker.privateKey),
        ("<tls-auth>", "</tls-auth>", Marker.staticKey),
        ("<tls-crypt>", "</tls-crypt>", Marker.staticKey),
        ("<tls-crypt-v2>", "</tls-crypt-v2>", Marker.staticKey),
        ("<secret>", "</secret>", Marker.staticKey),
        ("<pkcs12>", "</pkcs12>", Marker.privateKey),
        ("<auth-user-pass>", "</auth-user-pass>", Marker.credentials),
    ]

    /// Keys whose **value** on the same line is a secret, matched
    /// case-insensitively at a word boundary. The key itself stays: "there was
    /// a password here" is diagnostic, and the password is not.
    private static let secretKeys = [
        "password", "passwd", "passphrase", "auth-token", "auth_token", "token",
    ]

    /// The block we are inside, if any.
    private var open: (close: String, marker: String)?
    /// How many lines it has swallowed. **Bounded**, because a block that
    /// never closes would swallow the rest of the log for ever, and a
    /// truncated key block is exactly the shape a bug produces. A 4096-bit
    /// key is about forty lines.
    private var swallowed = 0
    private static let maximumBlockLines = 200

    /// Scrubs one line. Nil means the line is a block's body and is dropped
    /// entirely rather than replaced, so a 40-line key does not become 40
    /// markers.
    mutating func scrub(_ line: String) -> String? {
        if let open {
            // Inside a block: the closing marker ends it and is itself
            // dropped; anything on the same line after it is scrubbed.
            guard let end = line.range(of: open.close, options: .caseInsensitive) else {
                swallowed += 1
                guard swallowed > Self.maximumBlockLines else { return nil }
                // It is not going to close. Give up on it rather than lose
                // everything after it, and say so.
                self.open = nil
                swallowed = 0
                return Marker.unclosed
            }
            self.open = nil
            swallowed = 0
            let rest = String(line[end.upperBound...])
            let scrubbed = rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : scrub(rest)
            return scrubbed
        }

        // A block opening. Everything before it is kept and scrubbed; if the
        // same line also closes the block, the block is gone and the line
        // continues after it.
        for block in Self.blocks {
            guard let start = line.range(of: block.open, options: .caseInsensitive) else { continue }
            let head = Self.values(in: String(line[..<start.lowerBound]))
            if let end = line.range(
                of: block.close, options: .caseInsensitive, range: start.upperBound..<line.endIndex)
            {
                var tail = String(line[end.upperBound...])
                if !tail.trimmingCharacters(in: .whitespaces).isEmpty {
                    tail = " " + Self.values(in: tail).trimmingCharacters(in: .whitespaces)
                } else {
                    tail = ""
                }
                return head + block.marker + tail
            }
            open = (block.close, block.marker)
            swallowed = 0
            return head + block.marker
        }

        return Self.values(in: line)
    }

    /// A whole text at once — a multi-line log call, or the export's own
    /// re-check of something built elsewhere (D87).
    static func scrub(_ text: String) -> String {
        var redactor = Redactor()
        return
            text
            .components(separatedBy: .newlines)
            .compactMap { redactor.scrub($0) }
            .joined(separator: "\n")
    }

    /// Replaces the value after any secret-bearing key on one line.
    ///
    /// **An explicit `=` or `:` is required.** Matching a bare word followed
    /// by a space would eat our own prose — "the session token was refused"
    /// became "the session token [removed]" in the first version — and a
    /// mangled diagnostic is its own defect. The shapes that actually carry a
    /// secret all separate the value: `password=…`, `Password: …`,
    /// `passphrase = …`.
    private static func values(in line: String) -> String {
        var result = line
        for key in secretKeys {
            var from = result.startIndex
            while let found = result.range(of: key, options: .caseInsensitive, range: from..<result.endIndex) {
                from = found.upperBound
                // A word, not a fragment: `passwordless` is not a password and
                // `savePassword` is the name of a setting.
                let beforeIsWord =
                    found.lowerBound > result.startIndex
                    && isWord(result[result.index(before: found.lowerBound)])
                guard !beforeIsWord else { continue }
                // Then a separator, then the value, which goes.
                var index = found.upperBound
                while index < result.endIndex, result[index] == " " || result[index] == "\t" {
                    index = result.index(after: index)
                }
                guard index < result.endIndex, result[index] == "=" || result[index] == ":" else {
                    continue
                }
                index = result.index(after: index)
                while index < result.endIndex, result[index] == " " || result[index] == "\t" {
                    index = result.index(after: index)
                }
                guard index < result.endIndex else { continue }
                result.replaceSubrange(index..<result.endIndex, with: Marker.value)
                from = result.endIndex
            }
        }
        // A pushed `auth-token` and its value on one line. openvpn3 sanitises
        // this itself — into `[auth-token] ...` — and D199 is the rule that we
        // do not depend on that.
        let words = result.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = words.first, first.lowercased() == "auth-token", words.count == 2 {
            result = "auth-token " + Marker.value
        }
        return result
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
