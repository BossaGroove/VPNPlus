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
import Security
import os

/// M4.1 SPIKE ONLY — removed once the answer is recorded. Must not ship.
///
/// B8's largest open question, unanswered since Stage B: **can this process —
/// root, outside any user session — store and read back a secret, with
/// non-deprecated API and no prompt?** Everything else in M4 is built on the
/// answer, and the fallback if it is no (root-owned file) is more work and a
/// different design, so it is measured before anything depends on it.
///
/// Three candidates, in the order we would prefer them, each reported with the
/// exact `OSStatus` so a failure is diagnosable rather than just a failure.
enum SecretStoreSpike {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "spike")
    private static let service = "com.bossagroove.VPNPlus.spike"
    private static let account = "m41"

    static func run() {
        log.notice("spike M4.1: can root store a secret? uid=\(getuid(), privacy: .public) session=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "none", privacy: .public)")
        candidate1FileKeychain()
        candidate2DataProtectionKeychain()
        candidate3RootOwnedFile()
        log.notice("spike M4.1: done")
    }

    private static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(status) (\(text))"
    }

    /// The keychain a root daemon would ordinarily use. Modern `SecItem*` API,
    /// no `SecKeychain*` calls — the deprecation B8 worried about is in the
    /// *keychain-management* API, not in item access, so this may just work.
    private static func candidate1FileKeychain() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Read first: an item found here was written by an earlier provider
        // process, which is the property that actually matters.
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var existing: CFTypeRef?
        let readStatus = SecItemCopyMatching(read as CFDictionary, &existing)
        if readStatus == errSecSuccess, let data = existing as? Data {
            log.notice("spike 1 file keychain: found an item from an earlier process: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        } else {
            log.notice("spike 1 file keychain: no earlier item (\(describe(readStatus), privacy: .public))")
        }

        let value = Data("written \(Date().description(with: .current))".utf8)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = value
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        log.notice("spike 1 file keychain: add -> \(describe(addStatus), privacy: .public)")
        guard addStatus == errSecSuccess else { return }

        var back: CFTypeRef?
        let backStatus = SecItemCopyMatching(read as CFDictionary, &back)
        let matched = (back as? Data) == value
        log.notice("spike 1 file keychain: read back -> \(describe(backStatus), privacy: .public) matched=\(matched, privacy: .public)")
        // Left in place on purpose: the next provider process reports whether
        // it survived, which is the whole question.
    }

    /// The data-protection keychain, which is what Apple points new code at.
    /// It needs an access-group entitlement we do not currently claim, so the
    /// expected answer is a missing-entitlement status — measured rather than
    /// assumed, because claiming one is cheap if it works.
    private static func candidate2DataProtectionKeychain() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account + ".dp",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data("dp".utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        log.notice("spike 2 data-protection keychain: add -> \(describe(status), privacy: .public)")
        if status == errSecSuccess {
            SecItemDelete(query as CFDictionary)
        }
    }

    /// The fallback B8 named: a root-owned file that only root can reach. If
    /// candidate 1 works this is dead weight; if it does not, this is the
    /// design, and it is worth knowing now that the directory can be made.
    private static func candidate3RootOwnedFile() {
        let directory = URL(fileURLWithPath: "/Library/Application Support/com.bossagroove.VPNPlus")
        let file = directory.appendingPathComponent("spike.bin")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data("root only".utf8).write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let owner = attributes[.ownerAccountName] as? String ?? "?"
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let back = try Data(contentsOf: file)
            log.notice("spike 3 root-owned file: wrote and read \(back.count, privacy: .public) bytes, owner=\(owner, privacy: .public) mode=\(String(mode, radix: 8), privacy: .public)")
            try FileManager.default.removeItem(at: file)
        } catch {
            log.error("spike 3 root-owned file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
