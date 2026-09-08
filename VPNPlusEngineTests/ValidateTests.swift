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

/// A profile's verdict, its waived directives, and its refusals — the whole of
/// what M3.4 shows the user, pinned here against the engine.
struct ValidateTests {
    /// Everything the engine reported about one profile.
    struct Outcome {
        var verdict: vpnplus_verdict
        var refusal: vpnplus_refusal
        var message: String
        var ignored: [String] = []
        var waivable: [String] = []
        var blocking: [String] = []
    }

    /// Collects the directive callbacks; shared with C, hence the class.
    final class Directives: @unchecked Sendable {
        var ignored: [String] = []
        var waivable: [String] = []
        var blocking: [String] = []
    }

    static func validate(_ profile: String, waiving waive: [String] = []) -> Outcome {
        let collected = Directives()
        var result = vpnplus_validation()
        let callback: vpnplus_directive_callback = { context, name, _, kind in
            guard let context, let name else { return }
            let box = Unmanaged<Directives>.fromOpaque(context).takeUnretainedValue()
            let directive = String(cString: name)
            switch kind {
            case VPNPLUS_DIRECTIVE_IGNORED: box.ignored.append(directive)
            case VPNPLUS_DIRECTIVE_WAIVABLE: box.waivable.append(directive)
            default: box.blocking.append(directive)
            }
        }
        withExtendedLifetime(collected) {
            let context = Unmanaged.passUnretained(collected).toOpaque()
            if waive.isEmpty {
                vpnplus_engine_validate(profile, nil, 0, &result, callback, context)
            } else {
                var pointers = waive.map { UnsafePointer<CChar>(strdup($0)) }
                defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
                pointers.withUnsafeBufferPointer { buffer in
                    vpnplus_engine_validate(profile, buffer.baseAddress, buffer.count, &result, callback, context)
                }
            }
        }
        return Outcome(
            verdict: result.verdict, refusal: result.refusal,
            message: withUnsafeBytes(of: result.message) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
            ignored: collected.ignored, waivable: collected.waivable, blocking: collected.blocking)
    }

    static let minimalProfile = TestFixtures.minimalProfile

    @Test func engineReportsItsVersion() {
        #expect(String(cString: vpnplus_engine_version()) == "3.11.7")
    }

    @Test func minimalProfileIsAccepted() {
        let outcome = Self.validate(Self.minimalProfile)
        #expect(outcome.verdict == VPNPLUS_VERDICT_ACCEPTED, "\(outcome.message) \(outcome.blocking)")
        #expect(outcome.refusal == VPNPLUS_REFUSAL_NONE)
    }

    /// The regression M5.6 was built on: a profile that authenticates with a
    /// username and password and carries no client certificate is the ordinary
    /// shape, and the app refused every one of them.
    ///
    /// openvpn3 requires a `cert` unless told otherwise, and its own way of
    /// being told — `setenv CLIENT_CERT 0` — is a marker real profiles do not
    /// carry. `Self.minimalProfile` no longer carries it either, so this
    /// asserts by name what the rest of the suite now silently depends on.
    @Test func aProfileWithNoClientCertificateIsAccepted() {
        #expect(!Self.minimalProfile.contains("CLIENT_CERT"), "the fixture must not carry the marker")
        let outcome = Self.validate(Self.minimalProfile)
        #expect(outcome.verdict == VPNPLUS_VERDICT_ACCEPTED, "\(outcome.message)")
        #expect(outcome.refusal == VPNPLUS_REFUSAL_NONE)
    }

    /// The other half, and the reason the decision is not simply "no cert, no
    /// certificate needed": openvpn3 reports external PKI for a profile
    /// missing *either* a cert or a key, so a certificate whose key lives in a
    /// keystore looks identical to a password-only profile from that flag
    /// alone. It has to stay refused, and by the right name.
    @Test func aCertificateWithoutItsKeyIsStillRefused() {
        let outcome = Self.validate(
            Self.minimalProfile + "<cert>\n\(TestFixtures.certificate)\n</cert>\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED, "a key kept elsewhere must not connect anyway")
        #expect(outcome.refusal == VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE, "\(outcome.message)")
        #expect(outcome.blocking.contains("key"), "\(outcome.blocking)")
    }

    /// A profile that declares external PKI is refused for that reason, and is
    /// never mistaken for one that simply has nothing to send. The declaration
    /// is an Access Server meta line, the only form openvpn3 reads it in —
    /// `setenv EXTERNAL_PKI 1` is not it.
    @Test func aProfileThatDeclaresExternalPKIIsRefused() {
        let outcome = Self.validate(Self.minimalProfile + "# OVPN_ACCESS_SERVER_EXTERNAL_PKI=1\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED, "\(outcome.message)")
        #expect(outcome.refusal == VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE, "\(outcome.message)")
    }

    /// The three directives the owner's real company profile carries. They are
    /// harmless, and D187 says they are disclosed rather than buried.
    @Test func directivesTheEngineIgnoresAreDisclosedButDoNotRefuse() {
        let outcome = Self.validate(Self.minimalProfile + "resolv-retry infinite\npersist-key\npersist-tun\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_ACCEPTED_WITH_WAIVERS, "\(outcome.message)")
        #expect(outcome.ignored.sorted() == ["persist-key", "persist-tun", "resolv-retry"], "\(outcome.ignored)")
        #expect(outcome.blocking.isEmpty)
    }

    @Test func staticKeyModeIsRefusedAsUnsupported() {
        // B7: passes eval_config clean; thrown only when ClientOptions is built.
        let outcome = Self.validate(Self.minimalProfile + "secret static.key\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED)
        #expect(outcome.refusal == VPNPLUS_REFUSAL_UNSUPPORTED_FEATURE, "\(outcome.message)")
        #expect(outcome.message.lowercased().contains("static key"), "\(outcome.message)")
    }

    @Test func serverModeIsRefused() {
        let outcome = Self.validate(Self.minimalProfile + "mode server\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED)
        #expect(outcome.refusal == VPNPLUS_REFUSAL_UNSUPPORTED_FEATURE, "\(outcome.message)")
    }

    @Test func aServerLockedProfileSaysSo() {
        let outcome = Self.validate(Self.minimalProfile + "setenv GENERIC_CONFIG\n")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED)
        #expect(outcome.refusal == VPNPLUS_REFUSAL_SERVER_LOCKED, "\(outcome.message)")
    }

    @Test func emptyProfileIsMalformed() {
        let outcome = Self.validate("")
        #expect(outcome.verdict == VPNPLUS_VERDICT_REFUSED)
        #expect(outcome.refusal == VPNPLUS_REFUSAL_MALFORMED)
    }

    /// D155's "import anyway": an unrecognised directive refuses the profile,
    /// is reported as waivable, and once waived the profile is accepted with
    /// that directive disclosed.
    @Test func anUnknownDirectiveIsRefusedThenWaivable() {
        let profile = Self.minimalProfile + "bikeshed-color green\n"
        let refused = Self.validate(profile)
        #expect(refused.verdict == VPNPLUS_VERDICT_REFUSED)
        #expect(refused.refusal == VPNPLUS_REFUSAL_UNKNOWN_DIRECTIVES, "\(refused.message)")
        #expect(refused.waivable == ["bikeshed-color"], "\(refused.waivable)")

        let waived = Self.validate(profile, waiving: ["bikeshed-color"])
        #expect(waived.verdict == VPNPLUS_VERDICT_ACCEPTED_WITH_WAIVERS, "\(waived.message)")
        #expect(waived.ignored.contains("bikeshed-color"), "\(waived.ignored)")
    }

    /// 2.10 and 2.9: the client identity itself is never waivable, and the
    /// refusal names the cause rather than reporting a corrupt file.
    @Test func aKeyStoreProfileIsRefusedAndCannotBeWaived() {
        let profile = Self.minimalProfile + "pkcs12 identity.p12\n"
        let refused = Self.validate(profile)
        #expect(refused.refusal == VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE, "\(refused.message)")
        #expect(refused.blocking.contains("pkcs12"), "\(refused.blocking)")
        #expect(!refused.waivable.contains("pkcs12"))

        // Asking to waive it anyway must change nothing: the rule lives in the
        // engine boundary, so no caller can bypass it.
        let attempted = Self.validate(profile, waiving: ["pkcs12"])
        #expect(attempted.verdict == VPNPLUS_VERDICT_REFUSED, "waiving pkcs12 must not import the profile")
        #expect(attempted.refusal == VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE, "\(attempted.message)")
    }
}
