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

/// Merging a profile from disk, and reading what it says about itself — the two
/// things import needs before it can either store a profile or refuse it.
struct ImportTests {
    /// A profile whose certificate lives in a neighbouring file, as issuers
    /// routinely ship them.
    private func writeProfile(inlineCA: Bool, caPresent: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpnplus-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var text = """
        client
        dev tun
        proto udp
        remote vpn.example.invalid 1194
        setenv CLIENT_CERT 0
        auth-user-pass

        """
        if inlineCA {
            text += "<ca>\n\(TestFixtures.certificate)\n</ca>\n"
        } else {
            text += "ca company-ca.crt\n"
            if caPresent {
                try (TestFixtures.certificate + "\n")
                    .write(to: directory.appendingPathComponent("company-ca.crt"), atomically: true, encoding: .utf8)
            }
        }
        let profile = directory.appendingPathComponent("Company SG.ovpn")
        try text.write(to: profile, atomically: true, encoding: .utf8)
        return profile
    }

    private func merge(_ url: URL) -> (text: String, info: vpnplus_merge_info) {
        var info = vpnplus_merge_info()
        let needed = vpnplus_engine_merge(url.path, nil, 0, &info)
        guard needed > 0 else { return ("", info) }
        var buffer = [CChar](repeating: 0, count: needed + 1)
        _ = vpnplus_engine_merge(url.path, &buffer, buffer.count, &info)
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (text, info)
    }

    private func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// 2.2 — the stored text is self-contained, so moving or deleting the
    /// original folder afterwards cannot break the profile.
    @Test func mergingInlinesAReferencedCertificate() throws {
        let url = try writeProfile(inlineCA: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (text, info) = merge(url)
        #expect(info.ok, "\(string(info.status)) \(string(info.message))")
        #expect(info.reference_count == 1)
        #expect(string(info.basename) == "Company SG.ovpn")
        #expect(text.contains("<ca>"), "the certificate was not inlined")
        #expect(text.contains("BEGIN CERTIFICATE"))
        #expect(!text.contains("ca company-ca.crt"), "the reference should be replaced, not kept")

        // And the merged text is a profile the engine accepts.
        let outcome = ValidateTests.validate(text)
        #expect(outcome.verdict == VPNPLUS_VERDICT_ACCEPTED, "\(outcome.message)")
    }

    /// 2.3 — a missing reference names *which* file, so import can offer to
    /// find the folder instead of rejecting the profile.
    @Test func aMissingReferenceIsNamed() throws {
        let url = try writeProfile(inlineCA: false, caPresent: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (_, info) = merge(url)
        #expect(!info.ok)
        #expect(string(info.missing_reference).contains("company-ca.crt"), "\(string(info.message))")
    }

    @Test func mergingReportsAFileItCannotRead() {
        var info = vpnplus_merge_info()
        let needed = vpnplus_engine_merge("/nonexistent/Nowhere.ovpn", nil, 0, &info)
        #expect(needed == 0)
        #expect(!info.ok)
        #expect(!string(info.message).isEmpty)
    }

    /// The buffer contract: too small writes nothing and still reports the size.
    @Test func mergingReportsTheSizeItNeeds() throws {
        let url = try writeProfile(inlineCA: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var info = vpnplus_merge_info()
        let needed = vpnplus_engine_merge(url.path, nil, 0, &info)
        #expect(needed > 0)
        var tooSmall = [CChar](repeating: 0x7f, count: 8)
        _ = vpnplus_engine_merge(url.path, &tooSmall, tooSmall.count, &info)
        #expect(tooSmall.allSatisfy { $0 == 0x7f }, "nothing should be written into a buffer that cannot hold it")
    }

    // MARK: - What a profile says about itself

    private func describe(_ profile: String) -> (info: vpnplus_profile_info, servers: [(String, String)]) {
        final class Servers: @unchecked Sendable { var all: [(String, String)] = [] }
        let collected = Servers()
        var info = vpnplus_profile_info()
        withExtendedLifetime(collected) {
            _ = vpnplus_engine_describe(profile, &info, { context, host, label in
                guard let context, let host else { return }
                Unmanaged<Servers>.fromOpaque(context).takeUnretainedValue().all
                    .append((String(cString: host), label.map { String(cString: $0) } ?? ""))
            }, Unmanaged.passUnretained(collected).toOpaque())
        }
        return (info, collected.all)
    }

    @Test func describingReportsTheServerAndWhatIsAsked() {
        let (info, _) = describe(TestFixtures.minimalProfile)
        #expect(info.ok, "\(string(info.message))")
        #expect(string(info.remote_host) == "vpn.example.invalid")
        #expect(string(info.remote_port) == "1194")
        #expect(string(info.remote_proto).lowercased().contains("udp"), "\(string(info.remote_proto))")
        // auth-user-pass, so credentials are needed and may be saved by default.
        #expect(!info.autologin)
        #expect(info.allow_password_save)
        #expect(!info.external_pki)
        #expect(string(info.fixed_username).isEmpty, "nothing fixes the username here")
    }

    /// 2.16 — alternate servers become a picker, with the issuer's own labels
    /// when it supplied them.
    @Test func alternateServersAreReportedWithTheirLabels() {
        let profile = TestFixtures.minimalProfile + """
        <connection>
        remote sg.example.invalid 1194 udp
        </connection>
        <connection>
        remote hk.example.invalid 443 tcp
        </connection>

        """
        let (info, servers) = describe(profile)
        #expect(info.ok, "\(string(info.message))")
        #expect(info.server_count == UInt(servers.count))
        // The server list is what the issuer advertises; a profile with none
        // reports none rather than inventing one.
        let (plain, plainServers) = describe(TestFixtures.minimalProfile)
        #expect(plain.server_count == 0)
        #expect(plainServers.isEmpty)
    }

    @Test func describingAMalformedProfileFails() {
        let (info, _) = describe("this is not a profile")
        #expect(!info.ok)
    }
}
