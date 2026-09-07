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

/// The whole run path — create, prepare, run on a thread, callbacks, stop —
/// exercised against an address that cannot answer (TEST-NET-1), so it works
/// without a server and ends on its own.
struct RunTests {
    /// Collects what the engine reports; shared with the C callbacks.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        private var logs: [String] = []
        func event(_ name: String) { lock.lock(); events.append(name); lock.unlock() }
        func log(_ text: String) { lock.lock(); logs.append(text); lock.unlock() }
        var eventNames: [String] { lock.lock(); defer { lock.unlock() }; return events }
        var logCount: Int { lock.lock(); defer { lock.unlock() }; return logs.count }
    }

    static let unreachableProfile = TestFixtures.minimalProfile
        .replacingOccurrences(of: "remote vpn.example.invalid 1194", with: "remote 192.0.2.1 1194")

    /// D177, confirmed here: the engine never gives up on its own. Twenty
    /// seconds of retrying against an address that cannot answer ended only
    /// when the test stopped it, and `connect-retry-max` changed nothing. The
    /// provider's phase deadlines are the only thing that ends a stalled
    /// attempt, so this test stops the engine itself and checks that a stop is
    /// clean: run() returns promptly and reports no error.
    @Test func runReportsEventsAndStopsCleanlyWhenTheServerNeverAnswers() throws {
        let recorder = Recorder()
        var callbacks = vpnplus_engine_callbacks()
        callbacks.context = Unmanaged.passUnretained(recorder).toOpaque()
        callbacks.log = { context, text in
            guard let context, let text else { return }
            Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue().log(String(cString: text))
        }
        callbacks.event = { context, name, _, _, _ in
            guard let context, let name else { return }
            Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue().event(String(cString: name))
        }
        callbacks.establish = { _, _ in -1 }
        callbacks.teardown = { _, _ in }

        let engine = try #require(vpnplus_engine_create(&callbacks, "VPNPlusTests/0"))
        defer { vpnplus_engine_destroy(engine) }

        var message = [CChar](repeating: 0, count: 1024)
        let prepared = vpnplus_engine_prepare(engine, Self.unreachableProfile, "user", "pass", nil, &message, message.count)
        #expect(prepared, "prepare: \(String(cString: message))")

        // The deadline a provider would apply, played by the test.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { vpnplus_engine_stop(engine) }

        let started = Date()
        var runMessage = [CChar](repeating: 0, count: 1024)
        let ok = vpnplus_engine_run(engine, &runMessage, runMessage.count)
        let elapsed = Date().timeIntervalSince(started)

        let names = recorder.eventNames
        #expect(ok, "a requested stop is not an error: \(String(cString: runMessage))")
        #expect(elapsed > 3.5 && elapsed < 8, "stop should end run() promptly; took \(elapsed) s")
        #expect(names.contains("RESOLVE") || names.contains("WAIT") || names.contains("CONNECTING"), "events: \(names)")
        #expect(!names.contains("CONNECTED"))
        #expect(recorder.logCount > 0)
    }
}
