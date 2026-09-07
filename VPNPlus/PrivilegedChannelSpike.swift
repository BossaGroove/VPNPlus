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
import os

/// M4.2 SPIKE ONLY — removed at M4.6. Must not ship.
///
/// Three questions the channel has to answer before M4.3 is built on it, and
/// none of them can be answered by reading:
///
/// 1. Does the app reach the extension's Mach service **while no tunnel is
///    running**? A password has to be storable before the first connection
///    (D75), so an on-demand launch is not a nicety.
/// 2. Does the pinned requirement actually hold — and, more importantly, does
///    a **wrong** one get refused? A check that only ever passes is not a check.
/// 3. Do the input rules bite: an unknown kind, an empty value, an oversized one.
enum PrivilegedChannelSpike {
    private static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "spike")

    static func run() async {
        let profile = UUID()
        log.notice("spike M4.2: channel, profile \(profile.uuidString, privacy: .public)")

        let client = PrivilegedClient()

        // 1 — the ordinary case, with no tunnel running.
        do {
            try await client.setSecret(Data("a-test-password".utf8), kind: .password, for: profile)
            log.notice("spike 1 store while idle: OK")
        } catch {
            log.error("spike 1 store while idle: FAILED \(error.localizedDescription, privacy: .public)")
        }

        // 1b — the same call, retried for half a minute, so it can span a
        // tunnel start driven from outside. This separates "the name or the
        // pinning is wrong" from "nothing is listening".
        var reached = false
        for attempt in 1...30 where !reached {
            do {
                try await client.setSecret(Data("a-test-password".utf8), kind: .password, for: profile)
                log.notice("spike 1b reached the service on attempt \(attempt, privacy: .public)")
                reached = true
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if !reached {
            log.error("spike 1b never reached the service in 30 attempts")
        }

        // 2 — the rules. Each of these must be refused.
        await expectRefusal("unknown kind") {
            try await client.setSecretRaw(Data("x".utf8), kind: 99, for: profile)
        }
        await expectRefusal("empty value") {
            try await client.setSecretRaw(Data(), kind: SecretKind.password.rawValue, for: profile)
        }
        await expectRefusal("oversized value") {
            try await client.setSecretRaw(
                Data(repeating: 0x41, count: SecretKind.password.sizeLimit + 1),
                kind: SecretKind.password.rawValue, for: profile)
        }

        // 3 — the wrong identity must be refused. Asking for a requirement the
        // extension cannot satisfy stands in for an attacker's listener.
        await expectRefusal("a requirement the extension does not meet") {
            try await client.setSecret(
                Data("x".utf8), kind: .password, for: profile,
                pinning: "identifier \"com.example.not-ours\" and anchor apple generic")
        }

        // 4 — deleting is idempotent, and takes the real secret with it.
        do {
            try await client.deleteSecrets(for: profile)
            try await client.deleteSecrets(for: profile)
            log.notice("spike 4 delete twice: OK (idempotent)")
        } catch {
            log.error("spike 4 delete twice: FAILED \(error.localizedDescription, privacy: .public)")
        }

        log.notice("spike M4.2: done")
    }

    private static func expectRefusal(_ what: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            log.error("spike REJECTION MISSING: \(what, privacy: .public) was accepted")
        } catch {
            log.notice("spike refused \(what, privacy: .public): OK")
        }
    }
}
