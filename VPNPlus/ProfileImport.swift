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
import VPNPlusCore
import os

/// Importing a profile: merge it, read what it says, and decide — all before
/// the user ever presses Connect (2.7, D189).
///
/// Nothing here touches AppKit, so the whole decision is one function of a file
/// path, and the copy is one function of the decision.
struct ProfileImport {
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "import")

    /// What a profile carries that VPN Plus does not act on. Disclosed as a
    /// count with the list one click behind it, never buried (D187).
    struct SetAside: Equatable {
        var directives: [String] = []
        var isEmpty: Bool { directives.isEmpty }
    }

    enum Outcome: Equatable {
        /// Ready to store. `setAside` is empty unless the profile carries
        /// directives the engine ignores.
        case ready(configuration: Data, descriptor: ProfileDescriptor, setAside: SetAside)
        /// A referenced file was not alongside the profile. Names it, because
        /// the user has to find it (2.3, A10 M16).
        case missingFile(named: String)
        /// Unrecognised directives. The user may set them aside and import
        /// anyway (D155); pass them back as `waiving`.
        case unrecognised(directives: [String])
        /// A refusal with a stated cause. Never "corrupt file" (2.10, 2.11).
        case refused(Refusal)

        enum Refusal: Equatable {
            case certificateInSeparateFile
            case serverSuppliesTheSettings
            case unsupportedRequirement
            case unreadable
        }
    }

    /// Reads the file at `url`, resolving its references, and decides.
    /// `waiving` carries directives the user has already agreed to set aside.
    func inspect(_ url: URL, waiving: [String] = []) -> Outcome {
        var info = vpnplus_merge_info()
        let needed = vpnplus_engine_merge(url.path, nil, 0, &info)
        guard needed > 0, info.ok else {
            let missing = Self.string(info.missing_reference)
            log.notice("merge failed: \(Self.string(info.status), privacy: .public)")
            if !missing.isEmpty {
                // Only the filename is shown; the path the profile named may
                // include a directory the user does not recognise.
                return .missingFile(named: (missing as NSString).lastPathComponent)
            }
            return .refused(.unreadable)
        }

        var buffer = [CChar](repeating: 0, count: needed + 1)
        guard vpnplus_engine_merge(url.path, &buffer, buffer.count, &info) > 0, info.ok else {
            return .refused(.unreadable)
        }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        let verdict = Self.validate(text, waiving: waiving)
        switch verdict.verdict {
        case VPNPLUS_VERDICT_REFUSED:
            log.notice("refused: \(verdict.refusalName, privacy: .public)")
            switch verdict.refusal {
            case VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE:
                return .refused(.certificateInSeparateFile)
            case VPNPLUS_REFUSAL_SERVER_LOCKED:
                return .refused(.serverSuppliesTheSettings)
            case VPNPLUS_REFUSAL_UNKNOWN_DIRECTIVES:
                return .unrecognised(directives: verdict.waivable)
            case VPNPLUS_REFUSAL_MALFORMED:
                return .refused(.unreadable)
            default:
                return .refused(.unsupportedRequirement)
            }
        default:
            guard let descriptor = Self.describe(text, setAside: verdict.ignored) else {
                return .refused(.unreadable)
            }
            return .ready(
                configuration: Data(text.utf8),
                descriptor: descriptor,
                setAside: SetAside(directives: verdict.ignored))
        }
    }

    // MARK: - The engine, as Swift values

    private struct Verdict {
        var verdict: vpnplus_verdict
        var refusal: vpnplus_refusal
        var message: String
        var ignored: [String]
        var waivable: [String]
        var refusalName: String {
            switch refusal {
            case VPNPLUS_REFUSAL_EXTERNAL_KEY_STORE: "certificate in a separate file"
            case VPNPLUS_REFUSAL_SERVER_LOCKED: "server supplies the settings"
            case VPNPLUS_REFUSAL_UNKNOWN_DIRECTIVES: "unrecognised directives"
            case VPNPLUS_REFUSAL_MALFORMED: "unreadable"
            default: "unsupported requirement"
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        var ignored: [String] = []
        var waivable: [String] = []
    }

    private static func validate(_ text: String, waiving: [String]) -> Verdict {
        let collected = Collected()
        var result = vpnplus_validation()
        let callback: vpnplus_directive_callback = { context, name, _, kind in
            guard let context, let name else { return }
            let box = Unmanaged<Collected>.fromOpaque(context).takeUnretainedValue()
            let directive = String(cString: name)
            switch kind {
            case VPNPLUS_DIRECTIVE_IGNORED: box.ignored.append(directive)
            case VPNPLUS_DIRECTIVE_WAIVABLE: box.waivable.append(directive)
            default: break
            }
        }
        withExtendedLifetime(collected) {
            let context = Unmanaged.passUnretained(collected).toOpaque()
            if waiving.isEmpty {
                vpnplus_engine_validate(text, nil, 0, &result, callback, context)
            } else {
                let pointers = waiving.map { UnsafePointer<CChar>(strdup($0)) }
                defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
                pointers.withUnsafeBufferPointer { buffer in
                    vpnplus_engine_validate(text, buffer.baseAddress, buffer.count, &result, callback, context)
                }
            }
        }
        return Verdict(
            verdict: result.verdict, refusal: result.refusal,
            message: string(result.message), ignored: collected.ignored, waivable: collected.waivable)
    }

    private final class Servers: @unchecked Sendable {
        var all: [ServerChoice] = []
    }

    /// What a stored profile says about itself. Used by import, and by any
    /// surface that needs to compose a profile with its overrides (D188).
    static func describe(_ text: String, setAside: [String]) -> ProfileDescriptor? {
        let servers = Servers()
        var info = vpnplus_profile_info()
        withExtendedLifetime(servers) {
            _ = vpnplus_engine_describe(text, &info, { context, host, label in
                guard let context, let host else { return }
                let hostName = String(cString: host)
                let labelText = label.map { String(cString: $0) } ?? ""
                Unmanaged<Servers>.fromOpaque(context).takeUnretainedValue().all
                    .append(ServerChoice(host: hostName, label: labelText.isEmpty ? hostName : labelText))
            }, Unmanaged.passUnretained(servers).toOpaque())
        }
        guard info.ok else { return nil }

        var credentials: [CredentialRequirement] = []
        if info.autologin {
            credentials = [.none]
        } else {
            let fixed = Self.string(info.fixed_username)
            credentials.append(.usernamePassword(usernameLocked: fixed.isEmpty ? nil : fixed))
            let challenge = Self.string(info.static_challenge)
            if !challenge.isEmpty {
                credentials.append(.challenge(prompt: challenge, echo: info.static_challenge_echo))
            }
        }
        if info.private_key_password_required {
            credentials.append(.privateKeyPassphrase)
        }

        let friendly = Self.string(info.friendly_name)
        let name = friendly.isEmpty ? Self.string(info.profile_name) : friendly
        return ProfileDescriptor(
            displayName: name,
            server: ServerEndpoint(
                host: Self.string(info.remote_host),
                port: Self.string(info.remote_port),
                transport: Self.string(info.remote_proto).lowercased()),
            credentials: credentials,
            allowsPasswordSave: info.allow_password_save,
            alternateServers: servers.all,
            waivedDirectives: setAside)
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
