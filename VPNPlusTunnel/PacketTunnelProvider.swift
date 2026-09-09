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
import Network
import NetworkExtension
import VPNPlusCore
import os

/// The provider: it owns one engine per connection and turns what the engine
/// asks for into what NetworkExtension applies. It never edits routes or DNS
/// itself — the OS applies the settings and the OS removes them (B1, B14, C4).
///
/// The completion-handler overrides are not a style choice: under Swift 6
/// strict concurrency the `async` forms cannot be overridden here, because
/// `[String: NSObject]?` is not Sendable and the superclass method is
/// nonisolated.
// @unchecked Sendable, and what makes that sound: **one session at a time**.
// The engine's callbacks arrive on its connect thread; the shared flags are
// behind the lock below; and the per-session credential state is only ever
// written by the session that owns it. A replacement session is not started
// until `runFinished` says the previous engine's thread has returned, which is
// the handoff that keeps two of them from ever overlapping.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "provider")
    private let engineLog = Logger(subsystem: "com.bossagroove.VPNPlus", category: "engine")

    private var engine: Engine?
    private var runThread: Thread?
    // NEProvider.defaultPath is deprecated (macOS 15) in favour of the Network
    // framework's path monitor, which watches the physical path here.
    private let pathMonitor = NWPathMonitor()
    private var lastPathDescription = ""
    /// The engine is paused because the network went away (below). The
    /// path's return must restart it, and by then the model is Reconnecting
    /// rather than Connected — so "connected" alone cannot be the test.
    private nonisolated(unsafe) var pausedForNetwork = false
    /// Signalled when the current engine's run() returns. One per session:
    /// a shared semaphore accumulates a count and stops being a barrier.
    private var runFinished: DispatchSemaphore?
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The start completion handler is not Sendable by type; it is called
    /// exactly once, under the lock's discipline, which is what makes the box sound.
    private final class Completion: @unchecked Sendable {
        let call: (Error?) -> Void
        init(_ call: @escaping (Error?) -> Void) { self.call = call }
    }

    private struct State: Sendable {
        var startCompletion: Completion?
        /// **The** state, as A8 models it and as the app is told it (M5.1).
        /// Everything user-visible is read from here, so there is no second
        /// answer to "what is happening" for the two to disagree about.
        var connection = Connection.disconnected
        /// Mechanics, not states: neither is anything a user is shown.
        var stopping = false
        /// The engine is being replaced by a fresh one; its ending must not
        /// end the tunnel.
        var restarting = false
        /// The attempt's end is already in the model — `failAttempt` put it
        /// there — so the engine exit that follows is mechanics, not a second
        /// failure. Without this the same failure was applied twice: once
        /// from the event and once from `runEnded`, which on the recovery
        /// ladder counted one failure as two attempts.
        var attemptEnded = false
        /// The phases this attempt has entered so far. A phase's clock is
        /// armed the **first** time it is entered: the engine gives up on one
        /// server and moves to the next every two seconds, announcing RESOLVE
        /// and WAIT again each time, and re-arming on every announcement kept
        /// "contacting the server" alive for ever (the M5.6 ladder test,
        /// 2026-09-09: attempt 1 of 5 never ended while five servers refused
        /// it in turn).
        var phasesEntered: Set<OpenVPNPhase> = []
        /// `PUSH_REQUEST`s sent in this attempt — the engine's 3 s cadence made
        /// countable, so a config stall can say how many times it asked
        /// (feature-spec 4.10).
        var pushRequests = 0
        /// The Keychain refused to hand over the configuration, which is a
        /// different failure from there being none (A10 M15).
        var keychainRefused = false

        var isConnected: Bool { connection.state == .connected }
    }

    /// The profile a connection that named none is reported under. The app
    /// never starts one without an id — it puts the id in
    /// `providerConfiguration` — so this exists to keep a report coherent
    /// rather than to be matched to anything.
    private static let unidentified = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// What this session offers the server, and in which order.
    ///
    /// Three sources, ranked. The **session token** first, because it is the
    /// freshest credential and the only one that can re-establish a session
    /// the server asked more than a password for. The **saved password**
    /// second. The **start options** last, for a session the user asked us not
    /// to remember — that copy is the only one and it dies with the session,
    /// which is what "don't remember it" has to mean.
    private struct SignIn: Sendable {
        /// Where the credential came from, which the log names and which
        /// decides how a refusal is read.
        ///
        /// The engine cannot be told that a password is really a token —
        /// `ProvideCreds` has no field for it — so this is the only place that
        /// knows, and the only reason a refusal can be read as "expired"
        /// rather than "wrong" (D220).
        enum Source: String, Sendable {
            case none = "nothing"
            case token = "the session token the server issued"
            case saved = "the saved password"
            case supplied = "the password supplied for this session only"
        }

        var username = ""
        var password = ""
        var source = Source.none
        var isToken: Bool { source == .token }
        var isEmpty: Bool { password.isEmpty }
    }

    /// The configuration and the credentials this session is using.
    ///
    /// Held for the life of the session because a transition starts a **fresh**
    /// engine (D211) and it needs them again.
    private var profile = ""
    private var identifier: UUID?
    /// What the user asked us to keep, read from our own store.
    private var saved: StoredCredentials?
    /// What the server issued, kept in memory for the session whether or not
    /// it is also stored.
    private var token: StoredSessionToken?
    /// What the app handed over for this session only.
    private var supplied: StoredCredentials?
    private var current = SignIn()
    /// A refused token is dropped and the password tried once. Never twice:
    /// two rejections in a row are a rejection, not a stale token.
    private var tokenRefused = false
    private var serverOverride = Engine.ServerOverride()
    private var identity = Engine.ClientIdentity()
    private let secrets = ExtensionSecretStore()

    /// The record, and the filter everything entering it passes through
    /// (D199). Its own lock rather than `state`'s: engine log lines arrive on
    /// the connect thread, and file I/O never happens while a lock is held.
    private struct Recording {
        var log = DiagnosticsLog()
        var redactor = Redactor()
    }
    private let recording = OSAllocatedUnfairLock(initialState: Recording())
    private let records = DiagnosticsStore()
    private var deadline: DispatchWorkItem?
    /// Every phase has one of its own (feature-spec 3.5). One attempt deadline
    /// could only ever say "it took too long"; a phase deadline says which
    /// step, which is the difference between a timeout and a diagnosis.
    private var phaseDeadline: DispatchWorkItem?
    private var transportPoll: DispatchWorkItem?
    /// The interface that already owned the default route when this attempt
    /// started, if one did (D204).
    private var foreignTunnel: String?
    /// Kept only so the log can say what was last reported.
    private var lastReport: TunnelReport?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice(
            "provider start uid=\(getuid(), privacy: .public) euid=\(geteuid(), privacy: .public)")
        log.notice(
            "engine openvpn3 \(String(cString: vpnplus_engine_version()), privacy: .public) (\(String(cString: vpnplus_engine_platform()), privacy: .public))"
        )

        // Which profile this is. **The start options first**, then
        // providerConfiguration — both handles, never secrets (D191). The app
        // saves the id into the configuration and then starts, and the system
        // still handed this provider a configuration from *before* that save
        // in 6 of 56 sessions on 2026-09-08: the session was named for one
        // profile and connected the other. What the user asked for at the
        // moment they asked rides in the options; the configuration is the
        // answer only when there are none, which is a connection started from
        // System Settings with no app running — the case that makes D75
        // possible.
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration
        let configured = (configuration?["profile"] as? String).flatMap(UUID.init(uuidString:))
        let asked = (options?["profileID"] as? String).flatMap(UUID.init(uuidString:))
        if let asked, let configured, asked != configured {
            log.error(
                "the configuration named \(configured.uuidString, privacy: .public) but the start asked for \(asked.uuidString, privacy: .public); starting what was asked for"
            )
        }
        let identifier = asked ?? configured
        self.identifier = identifier
        // Whatever this profile's record already holds, from a provider
        // process that is gone (A9 capture requirement 5).
        let kept = records.load(for: identifier)
        recording.withLock {
            $0.log = kept
            // A fresh engine writes a fresh stream, so a block the last one
            // left open must not swallow this one's lines.
            $0.redactor = Redactor()
        }

        let completion = Completion(completionHandler)
        state.withLock {
            $0.startCompletion = completion; $0.stopping = false
        }

        // The model's attempt begins **here**, before any guard below can
        // fail, because a failure needs something to be a failure *of*. The
        // first version of this ran after the guards, and a profile with no
        // password reported "disconnected" to an app that was waiting to be
        // told why (measured, 22:41:23).
        apply(.connect(identifier ?? Self.unidentified))

        // The configuration text: what the app handed over, if this is the
        // first connection since importing, else our own stored copy.
        var profile = options?["profile"] as? String
        if let identifier, let handed = profile {
            // Keep it, so every later connection — including one started from
            // System Settings with no app running — needs nothing from anyone.
            do {
                try secrets.set(
                    Data(handed.utf8), for: SecretKind.configuration.account(for: identifier))
                log.notice(
                    "stored the configuration for \(identifier.uuidString, privacy: .public)")
            } catch {
                log.error(
                    "could not store the configuration: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else if let identifier {
            do {
                let stored = try secrets.secret(
                    for: SecretKind.configuration.account(for: identifier))
                profile = stored.flatMap { String(data: $0, encoding: .utf8) }
                log.notice(
                    "read our own configuration for \(identifier.uuidString, privacy: .public): \(profile == nil ? "absent" : "present", privacy: .public)"
                )
            } catch {
                log.error(
                    "could not read the configuration: \(error.localizedDescription, privacy: .public)"
                )
                state.withLock { $0.keychainRefused = true }
            }
        }

        guard let profile, !profile.isEmpty else {
            log.error("no configuration for this profile, in the options or our own store")
            let refused = state.withLock { $0.keychainRefused }
            failAttempt(
                refused
                    ? FailureDetail(.keychainDenied, detail: "The Keychain refused the configuration.")
                    : FailureDetail(
                        .configurationMissing,
                        detail:
                            "The extension holds no configuration for this profile and none was handed to it."
                    ))
            return
        }
        self.profile = profile
        readCredentials(from: options)
        current = chooseSignIn()

        // A profile that needs a password and has none cannot be helped by
        // trying: the engine would carry the emptiness all the way to the
        // server and come back with a rejection, which is a different thing
        // with a different remedy. So it is refused here, at once, with the
        // one reason the app can turn into words (B8 open item 2).
        if current.isEmpty, Engine.needsSignIn(profile: profile) {
            log.error("this profile needs sign-in details and there are none to offer")
            failAttempt(
                FailureDetail(
                    .credentialsUnavailable,
                    detail: "This profile needs a password and the extension has none saved for it."))
            return
        }

        // D204: a daemon-based VPN is invisible to `NEVPNStatus` and plain in
        // the routing table. We do not refuse — A9 has yet to decide whether
        // this is a warning or a wall, and M6 owns the words — but the user
        // will not be left with an unexplained failure either.
        switch DefaultRoute.owner() {
        case .tunnel(let name):
            foreignTunnel = name
            log.error("another tunnel (\(name, privacy: .public)) already owns the default route")
        case .physical(let name):
            log.notice("the default route belongs to \(name, privacy: .public)")
        case .none:
            log.notice("no default route to read before connecting")
        }

        self.serverOverride = Engine.ServerOverride(
            host: options?["serverHost"] as? String ?? "",
            port: options?["serverPort"] as? String ?? "",
            transport: options?["serverTransport"] as? String ?? "")
        if !serverOverride.isEmpty {
            log.notice(
                "server override: \(self.serverOverride.host, privacy: .public):\(self.serverOverride.port, privacy: .public) \(self.serverOverride.transport, privacy: .public)"
            )
        }

        startEngine()
        observeDefaultPath()
    }

    /// Reads every credential this session might use: our own two stored
    /// items, and whatever the app supplied for a session it was asked not to
    /// remember.
    private func readCredentials(from options: [String: NSObject]?) {
        if let username = options?["username"] as? String,
            let password = options?["password"] as? String
        {
            supplied = StoredCredentials(username: username, password: password)
        }
        guard let identifier else { return }
        if let data =
            ((try? secrets.secret(for: SecretKind.password.account(for: identifier))) ?? nil)
        {
            saved = StoredCredentials(data)
        }
        if let data =
            ((try? secrets.secret(for: SecretKind.sessionToken.account(for: identifier))) ?? nil)
        {
            token = StoredSessionToken(data)
        }
        readClientIdentity(for: identifier)
    }

    /// D134's certificate, from the extension's own keychain rather than from
    /// `startTunnel` options — a connection started from System Settings
    /// carries no options, and an identity that is only there when the app
    /// asked would work in one place and fail in the other.
    private func readClientIdentity(for identifier: UUID) {
        func pem(_ kind: SecretKind) -> String {
            guard let data = (try? secrets.secret(for: kind.account(for: identifier))) ?? nil,
                let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
        identity = Engine.ClientIdentity(
            certificate: pem(.certificate), privateKey: pem(.privateKey))
        if !identity.isEmpty {
            // Never the contents, and not even a length: what matters for a
            // diagnosis is that one was used at all.
            log.notice("using the certificate stored for this profile")
        }
    }

    /// The freshest credential available, and where it came from.
    private func chooseSignIn() -> SignIn {
        if let token {
            // The server may name its own user for the token
            // (`auth-token-user`); using ours instead would fail an
            // authentication that would otherwise have worked.
            let username =
                token.username.isEmpty
                ? (saved?.username ?? supplied?.username ?? "")
                : token.username
            return SignIn(username: username, password: token.token, source: .token)
        }
        if let saved {
            return SignIn(username: saved.username, password: saved.password, source: .saved)
        }
        if let supplied {
            return SignIn(
                username: supplied.username, password: supplied.password, source: .supplied)
        }
        return SignIn()
    }

    /// Creates an engine for the stored profile and runs it on its own thread.
    /// Used for the first connection and for every fresh session after it.
    private func startEngine() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let engine = Engine(clientVersion: "VPNPlus/\(version)")
        self.engine = engine
        state.withLock { $0.attemptEnded = false; $0.phasesEntered = []; $0.pushRequests = 0 }
        pausedForNetwork = false
        beginRecording()

        engine.onLog = { [weak self, engineLog] text in
            engineLog.notice("\(text, privacy: .public)")
            // **Every line, redacted, kept** (A9 capture requirement 1,
            // feature-spec 4.9): the progress lines are the timeline that
            // makes a stall explicable, and this is the only copy of them.
            self?.recordEngineLine(text)
            // The one log line that is a count (D177's "free counter"): the
            // engine re-sends its request every 3 s while the server is silent.
            if text.contains("Sending PUSH_REQUEST") {
                self?.state.withLock { $0.pushRequests += 1 }
            }
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.onEstablish = { [weak self] settings in self?.establish(settings) }
        engine.onTeardown = { [weak self, log] disconnect in
            // Nothing of ours to undo: the OS applied the settings and the OS
            // removes them.
            log.notice("engine teardown disconnect=\(disconnect, privacy: .public)")
            // The artboard's "Restored DNS and routes", which is the line that
            // answers J11 for whoever is reading afterwards.
            self?.record(.teardownRestored)
        }

        // Chosen afresh for every session, so a token captured a moment ago
        // is what a reconnect after wake offers.
        current = chooseSignIn()
        log.notice("signing in with \(self.current.source.rawValue, privacy: .public)")
        do {
            try engine.prepare(
                profile: profile,
                username: current.username,
                password: current.password,
                server: serverOverride,
                identity: identity)
        } catch {
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
            // The engine refused the profile before trying: A10 M19's shape.
            failAttempt(FailureDetail(.unsupportedRequirement, detail: "prepare: \(error)"))
            return
        }

        armDeadline()
        pollTransport()
        let done = DispatchSemaphore(value: 0)
        runFinished = done
        let thread = Thread { [weak self] in
            let result = engine.run()
            self?.runEnded(result)
            done.signal()
        }
        thread.name = "engine.connect"
        thread.qualityOfService = .userInitiated
        runThread = thread
        thread.start()
    }

    /// Logs the engine's transport counters every three seconds until the
    /// attempt succeeds or ends. Whether bytes keep arriving while the server
    /// withholds its configuration is the difference between "the server is
    /// silent" and "we are not hearing it", and A9 keeps the answer either way.
    private func pollTransport() {
        transportPoll?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let engine, !state.withLock({ $0.isConnected || $0.stopping }) else {
                return
            }
            let stats = engine.transportCounters
            log.notice(
                "transport: in=\(stats.bytesIn, privacy: .public) out=\(stats.bytesOut, privacy: .public) lastPacket=\(engine.millisecondsSinceLastPacket.map(String.init) ?? "never", privacy: .public)ms"
            )
            pollTransport()
        }
        transportPoll = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: item)
    }

    // MARK: - The model, and telling the app about it

    /// Applies one event to the model, logs the transition, and rings the
    /// doorbell if anything the app can see has changed.
    ///
    /// Every user-visible state change in this file goes through here. That is
    /// the point: the app is not told what we did, it is told what we *are*
    /// (D75), and there is one place that decides what that is.
    @discardableResult
    private func apply(_ event: TunnelEvent) -> Connection {
        let (before, after) = state.withLock { s -> (Connection, Connection) in
            let before = s.connection
            s.connection = ConnectionMachine.next(before, on: event, at: Date())
            return (before, s.connection)
        }
        if before.state != after.state {
            log.notice(
                "state \(before.state.rawValue, privacy: .public) → \(after.state.rawValue, privacy: .public)"
            )
        } else if before.attempt?.phase?.id != after.attempt?.phase?.id,
            let phase = after.attempt?.phase
        {
            log.notice("phase \(phase.id, privacy: .public)")
        } else if before == after {
            // The table does not describe this combination. Worth a line: the
            // model deliberately does not invent a transition, so the only
            // record that it happened is here.
            log.notice(
                "no transition for \(String(describing: event), privacy: .public) in \(before.state.rawValue, privacy: .public)"
            )
            return after
        }
        report()
        return after
    }

    /// The current report, and the doorbell.
    private func report() {
        let report = state.withLock {
            TunnelReport(connection: $0.connection, foreignTunnel: self.foreignTunnel)
        }
        lastReport = report
        notify_post(TunnelReportChannel.notification)
    }

    /// Answers the app's question. The only thing this returns is the report:
    /// no secret crosses, and nothing the caller says changes what we do.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        switch ProviderRequest.decode(messageData) {
        case .report:
            let report = state.withLock {
                TunnelReport(connection: $0.connection, foreignTunnel: self.foreignTunnel)
            }
            log.notice(
                "answering with \(report.state.rawValue, privacy: .public) (pid \(getpid(), privacy: .public))"
            )
            completionHandler?(try? JSONEncoder().encode(report))
        case .diagnostics(let profile):
            // This process's record when it is the profile's, else whatever is
            // on disk — the app may be asking about a profile that has not
            // connected since this provider started.
            // **A blank provider object is not an answer** (D228): NE hands a
            // message to whatever provider exists, including one it created
            // fresh after the session ended, whose record is empty. Measured
            // again here — the session answered 0 for a profile whose two
            // attempts were on disk. So the in-memory record answers only
            // when it has something, and the store answers otherwise.
            let mine = recording.withLock { $0.log }
            let isMine = profile == nil || profile == mine.profile
            let record =
                (isMine && !mine.attempts.isEmpty) ? mine : records.load(for: profile)
            log.notice(
                "answering with \(record.attempts.count, privacy: .public) recorded attempts"
            )
            completionHandler?(try? JSONEncoder().encode(record))
        }
    }

    // MARK: - The record (M6.2)

    /// Starts an attempt in the record. The recovery count is the model's, so
    /// the record and the failure message cannot disagree about it.
    private func beginRecording() {
        let recovery = state.withLock { $0.connection.attempt?.recovery ?? 0 }
        recording.withLock {
            if $0.log.profile == nil { $0.log.profile = self.identifier }
            $0.log.begin(recovery: recovery, at: Date())
        }
    }

    /// One of our own entries — typed, because the words are the app's.
    private func record(_ kind: DiagnosticsEntry.Kind, identifier: String? = nil) {
        let now = Date()
        recording.withLock { $0.log.add(kind, identifier: identifier, at: now) }
    }

    /// The engine's own prose, **redacted before it is kept** and never shown
    /// on a surface (D138, D199).
    private func recordEngineLine(_ text: String) {
        let now = Date()
        recording.withLock {
            guard let scrubbed = $0.redactor.scrub(text) else { return }
            $0.log.add(.engine(scrubbed), at: now)
        }
    }

    /// Ours, for the export, and scrubbed as well: an event's text is the
    /// engine's or the server's, and neither is trusted (D199).
    private func recordNote(_ text: String, identifier: String? = nil) {
        let now = Date()
        recording.withLock {
            $0.log.add(.note(Redactor.scrub(text)), identifier: identifier, at: now)
        }
    }

    /// Closes the attempt and puts the record on disk. **The only place it is
    /// written**, so an attempt's outcome and its persistence cannot diverge —
    /// and outside the lock, because writing a file under one is how a hang
    /// starts.
    ///
    /// It saves whether or not there was an attempt to close. The first
    /// version returned early when the outcome was already settled, and the
    /// entries that arrive **after** it — the teardown's *"Restored DNS and
    /// routes"*, the disconnect itself — reached memory and never the disk:
    /// they were missing from the record the next provider process read
    /// (measured on the owner's connect, 2026-09-09 10:01).
    private func finishRecording(_ outcome: DiagnosticsAttempt.Outcome) {
        let now = Date()
        recording.withLock { $0.log.finish(outcome, at: now) }
        persistRecord()
    }

    /// Puts the record on disk as it stands.
    ///
    /// Called at the **end** of a teardown as well as at an attempt's
    /// outcome, because the engine's own teardown — the artboard's *"Restored
    /// DNS and routes"* — happens after the outcome is settled and after the
    /// save that settled it. It reached memory and stayed there.
    private func persistRecord() {
        let record = recording.withLock { $0.log }
        guard !record.attempts.isEmpty else { return }
        records.save(record, for: record.profile ?? identifier)
    }

    // MARK: - Deadlines (D177, A8)

    /// The engine never gives up on its own. This does: an attempt that has not
    /// reached CONNECTED within the attempt deadline ends the tunnel, so the
    /// user gets the network back and a reason instead of "Reconnecting".
    /// Arms the deadline for the phase just entered, and cancels the last
    /// one. A phase that ends normally is never the one that fires.
    private func armPhaseDeadline(_ phase: OpenVPNPhase) {
        phaseDeadline?.cancel()
        let seconds = Int(phase.deadline.components.seconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !state.withLock({ $0.isConnected || $0.stopping || $0.restarting })
            else { return }
            // Has the attempt moved *past* this phase? Then a later phase has
            // its own clock. "Is it still in this phase" was the wrong
            // question: an engine cycling through refused servers alternates
            // resolve and contact every two seconds, so the contact clock
            // fired while the phase read "resolve" and did nothing.
            let passed = state.withLock { s in
                s.phasesEntered.contains { $0.order > phase.order }
            }
            guard !passed else { return }
            log.error(
                "phase \(phase.rawValue, privacy: .public) exceeded \(seconds, privacy: .public) s; ending the attempt"
            )
            // A stall is a mode with an identity (D100): the phase names the
            // message, and the config stall carries how many times it asked.
            let requests = state.withLock { $0.pushRequests }
            record(.gaveUp(phase: phase.rawValue, seconds: seconds))
            failAttempt(
                FailureDetail.forStall(
                    in: phase, waited: seconds,
                    requests: phase == .waitingForSettings ? requests : nil))
        }
        phaseDeadline = item
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
    }

    private func armDeadline() {
        deadline?.cancel()
        let seconds = Int(Deadlines.attempt.components.seconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !state.withLock({ $0.isConnected }) else { return }
            log.error("no connection after \(seconds, privacy: .public) s; ending the attempt")
            // A reason the app can turn into words, now that there is a code
            // for it. M5.2 makes this five phase deadlines instead of one.
            failAttempt(
                FailureDetail(
                    .timedOut, waited: .seconds(seconds),
                    detail: "The connection did not complete within \(seconds) seconds."))
        }
        deadline = item
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
    }

    /// Ends the current attempt honestly: fails the start if one is pending,
    /// otherwise cancels the tunnel so every surface shows Disconnected.
    private func failAttempt(_ detail: FailureDetail) {
        var detail = detail
        // Two facts about this Mac that the engine cannot know and that
        // explain a server it could not reach better than the engine can
        // (A9 source 3): no network at all, and another tunnel holding the
        // default route when the attempt began (D204).
        if detail.reason.isAboutReachingTheServer {
            if lastPathDescription.hasPrefix("unsatisfied") {
                detail.reason = .noNetwork
            } else if let foreignTunnel {
                detail.reason = .anotherTunnelActive
                detail.foreignTunnel = foreignTunnel
            }
        }
        // The model learns the reason before any surface does, because the
        // model is what the surfaces read — and **it also decides what
        // happens next**: from a recovery attempt with tries left it returns
        // to Reconnecting rather than Failed (D86).
        state.withLock { $0.attemptEnded = true }
        let after = apply(.ended(detail))

        if case .reconnecting(let attempt) = after {
            // Still recovering. Ending the tunnel here would contradict the
            // state both surfaces are showing — and would take the user's
            // network away in order to tell them we are still trying.
            scheduleRecovery(attempt)
            return
        }

        // **The whole record leaves with the tunnel.** `fetchLastDisconnectError`
        // is the only channel that outlives this provider, and until M6.1 it
        // carried the code alone — so a timeout the provider knew was
        // "contacting the server" reached the window as "didn't finish in
        // time" (the M5.6 ladder test).
        let failure: NSError
        if case .failed(let record) = after {
            failure = record.asError()
        } else {
            failure = detail.reason.error(detail.detail ?? "")
        }
        record(
            .failed(
                detail.reason, waited: detail.waited.map { Int($0.components.seconds) },
                requests: detail.attempts))
        finishRecording(.failed(detail.reason))
        let pending = state.withLock { $0.startCompletion != nil }
        if pending {
            finishStart(with: failure)
        }
        engine?.stop()
        cancelTunnelWithError(failure)
    }

    /// The next recovery attempt, after its backoff.
    ///
    /// **Counted, bounded, and visible** (D86): the count is in the model, the
    /// bound is `Recovery.maxAttempts`, and both surfaces are already showing
    /// "attempt 2 of 5" because they read the same model. What was missing was
    /// this — the provider actually waiting and trying again, instead of
    /// cancelling a tunnel the model said was recovering.
    ///
    /// The wait is not politeness. A drop usually means the network went away,
    /// and the owner's most frequent failure is a server that accepts the
    /// sign-in and then withholds the configuration — hammering either makes
    /// it worse.
    private func scheduleRecovery(_ attempt: Attempt) {
        let wait = Recovery.backoff(before: attempt.recovery)
        log.notice(
            "recovery attempt \(attempt.recovery, privacy: .public) of \(Recovery.maxAttempts, privacy: .public) in \(Int(wait.components.seconds), privacy: .public) s"
        )
        record(
            .tryingAgain(
                attempt: attempt.recovery, of: Recovery.maxAttempts,
                seconds: Int(wait.components.seconds)))
        deadline?.cancel()
        phaseDeadline?.cancel()
        transportPoll?.cancel()
        engine?.stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + wait.timeInterval) { [weak self] in
            guard let self, !state.withLock({ $0.stopping }) else { return }
            restartFresh(reason: "recovery attempt \(attempt.recovery)")
        }
    }

    /// Replaces the engine with a fresh session, keeping the tunnel. B3'
    /// measured that a resumed session never gets its config from the owner's
    /// server while a fresh one does (A2), so this is what sleep/wake uses.
    private func restartFresh(reason: String) {
        let (already, wasConnected) = state.withLock { s -> (Bool, Bool) in
            if s.restarting { return (true, s.isConnected) }
            let connected = s.isConnected
            s.restarting = true
            return (false, connected)
        }
        if already { return }
        log.notice("starting a fresh session: \(reason, privacy: .public)")
        // Only a tunnel that was up can be reasserted. Saying so before the
        // first connection would show "Reconnecting" for something that has
        // never connected.
        if wasConnected {
            reasserting = true
            // Recovery, counted from here (D86) — not a fresh attempt, which
            // is what makes the bound mean anything. Already-recovering is
            // left alone: the count belongs to the failure that started the
            // attempt, and incrementing it for every fresh engine would
            // exhaust the bound without anything having failed.
            apply(.dropped)
        }
        let old = engine
        let done = runFinished
        old?.stop()
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            _ = done?.wait(timeout: .now() + 5)
            // Hand the default route back to the physical network for the
            // attempt. Two reasons, both measured in M2.5: the user keeps
            // working while we reconnect instead of losing all networking, and
            // every reconnect that failed did so with a dead tunnel still
            // holding the default route, which the working cases never had.
            let cleared = DispatchSemaphore(value: 0)
            setTunnelNetworkSettings(nil) { [log] error in
                if let error {
                    log.error(
                        "could not clear the tunnel settings: \(error.localizedDescription, privacy: .public)"
                    )
                } else {
                    log.notice(
                        "tunnel settings cleared; the physical network is primary while we reconnect"
                    )
                }
                cleared.signal()
            }
            _ = cleared.wait(timeout: .now() + 5)
            // D205: `NEVPNStatus` says Disconnected while routes can persist
            // for up to ~15 s more, and every reconnect that failed in M2.5
            // did so with a dead tunnel still holding the route. So this waits
            // for the path rather than trusting the transition.
            // Two seconds, not five, and the elapsed time is logged: M2.5
            // measured a 6.5 s reconnect that the user keeps their network
            // through, and a wait that made it 11 s would be a worse answer to
            // the same question. If this ever costs time, the log says so.
            let waited = Date()
            let owner = DefaultRoute.waitForCleanPath(within: .seconds(2))
            let ms = Int(Date().timeIntervalSince(waited) * 1000)
            switch owner {
            case .tunnel(let name):
                log.error(
                    "\(name, privacy: .public) still owns the default route after \(ms, privacy: .public) ms; reconnecting anyway"
                )
            case .physical(let name):
                log.notice(
                    "the default route is back on \(name, privacy: .public) after \(ms, privacy: .public) ms"
                )
            case .none:
                log.notice("no default route after \(ms, privacy: .public) ms; reconnecting anyway")
            }
            state.withLock { $0.restarting = false }
            startEngine()
        }
    }

    // MARK: - Sleep, wake, and the network changing under us (J11)

    /// D206: macOS tells the provider nothing about the transport after wake;
    /// the socket may be dead for minutes before a keepalive notices. So the
    /// engine is paused on sleep and resumed on wake, which rebuilds the
    /// transport deterministically while the tunnel itself persists.
    override func sleep(completionHandler: @escaping () -> Void) {
        let connected = state.withLock { $0.isConnected }
        log.notice("sleep; connected=\(connected, privacy: .public)")
        if connected { engine?.pause(reason: "sleep") }
        completionHandler()
    }

    override func wake() {
        let connected = state.withLock { $0.isConnected }
        log.notice("wake; connected=\(connected, privacy: .public)")
        if connected { restartFresh(reason: "wake") }
    }

    /// The default path changing while connected (Wi-Fi off, cable in) means
    /// the transport is probably dead. Reconnect the transport; the tunnel
    /// persists. Path changes caused by our own tunnel coming up are ignored
    /// for a few seconds after CONNECTED.
    private func observeDefaultPath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let now = Self.describe(path)
            let (connected, since) = state.withLock {
                ($0.isConnected, $0.connection.session?.since)
            }
            let settleSeconds = since.map { Date().timeIntervalSince($0) } ?? 0
            let previous = lastPathDescription
            lastPathDescription = now
            guard now != previous else { return }
            log.notice(
                "network path: \(now, privacy: .public) (was \(previous.isEmpty ? "unknown" : previous, privacy: .public)); connected=\(connected, privacy: .public) since=\(Int(settleSeconds), privacy: .public)s"
            )
            // A tunnel that is up, once it has settled — **or one we paused
            // because the network went away.** The first version tested only
            // `connected`, and after a Wi-Fi loss the model is Reconnecting,
            // so the path's return restarted nothing: the engine stayed
            // paused and the window said "attempt 1 of 5" for ever. Found by
            // reading the code before the M5.6 ladder test, 2026-09-09.
            let paused = pausedForNetwork
            guard (connected && settleSeconds > 5) || paused, !previous.isEmpty else { return }
            if path.status == .satisfied {
                // C measured that the engine's own reconnect on this path is
                // never answered by the server; a fresh engine is.
                if paused { record(.networkReturned) }
                pausedForNetwork = false
                restartFresh(reason: paused ? "network returned" : "network changed")
            } else if !paused {
                // Quiet the engine while there is nothing to send on; the
                // return of a path restarts fresh above.
                log.notice("no network path; pausing the engine until one returns")
                record(.networkLost)
                reasserting = true
                // And say so. **Connected means carrying traffic** — not that
                // a tunnel object exists (feature-spec 3.9) — so a tunnel with
                // no network under it is recovering, not connected.
                //
                // Measured on 2026-09-07: without this the provider reported
                // `connected` for the 17 s a Wi-Fi outage lasted, and only the
                // app's own guard against a report it could not believe kept
                // the user from being told a lie. A guard catching our
                // dishonesty is not the same as not being dishonest.
                apply(.dropped)
                engine?.pause(reason: "network gone")
                pausedForNetwork = true
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.bossagroove.VPNPlus.path"))
    }

    private static func describe(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        // Our own utun appears once the tunnel is up; the physical interfaces
        // are what a change is measured against.
        let interfaces = path.availableInterfaces.map(\.name).filter { !$0.hasPrefix("utun") }
            .sorted()
        return
            "\(status) via \(interfaces.joined(separator: ","))\(path.isExpensive ? " expensive" : "")"
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.notice("provider stop reason=\(reason.rawValue, privacy: .public)")
        state.withLock { $0.stopping = true }
        record(.disconnected)
        finishRecording(.cancelled)
        apply(.disconnect)
        deadline?.cancel()
        phaseDeadline?.cancel()
        transportPoll?.cancel()
        pathMonitor.cancel()
        guard let engine else { completionHandler(); return }
        engine.stop()
        // The connect thread returns once the engine has wound down; give it a
        // bounded moment so a stuck engine cannot hold the stop forever.
        _ = runFinished?.wait(timeout: .now() + 5)
        self.engine = nil
        apply(.tornDown)
        // The engine's teardown has fired by now; the record it wrote goes
        // with everything else.
        persistRecord()
        completionHandler()
    }

    // MARK: - Engine callbacks (connect thread)

    private func handle(_ event: Engine.Event) {
        log.notice(
            "event \(event.name, privacy: .public) \(event.info, privacy: .public)\(event.isFatal ? " (fatal)" : "", privacy: .public)"
        )

        // A phase boundary moves the model and re-arms the clock. Events that
        // are not boundaries leave the phase alone: a phase we cannot place is
        // worse than the one we already have.
        if let phase = OpenVPNPhase.beginning(with: event.name) {
            apply(.entered(phase.asPhase))
            record(.phase(phase.rawValue), identifier: event.name)
            // Once per phase per attempt — see `phasesEntered`.
            let first = state.withLock { $0.phasesEntered.insert(phase).inserted }
            if first { armPhaseDeadline(phase) }
        } else if event.name != "CONNECTED" {
            // Everything else, for the export: the identifier travels with the
            // entry and the screen never shows it (D138).
            recordNote("\(event.name): \(event.info)", identifier: event.name)
        }

        switch event.name {
        case "CONNECTED":
            if let info = engine?.connectionInfo {
                log.notice(
                    "connected to \(info.serverHost, privacy: .public):\(info.serverPort, privacy: .public) via \(info.serverProto, privacy: .public), tunnel address \(info.vpnIPv4, privacy: .public) on \(info.tunName, privacy: .public)"
                )
            }
            // `reasserting` first, and the report after it: the app checks a
            // report against the session's status and rejects one the system
            // contradicts, so announcing "connected" while NE still said
            // "reasserting" got the announcement thrown away (measured,
            // 23:30:25.171). The user still ended up Connected, by the slower
            // route of the app observing the status change — which is the
            // fallback doing someone else's job.
            reasserting = false
            deadline?.cancel()
            phaseDeadline?.cancel()
            transportPoll?.cancel()
            apply(.established)
            record(.connected, identifier: event.name)
            finishRecording(.connected)
            rememberSessionToken()
            // A token that worked has earned the fallback back: the *next*
            // token to be refused is a new one, and stale for its own reasons.
            tokenRefused = false
            finishStart(with: nil)
        case "RECONNECTING":
            // The engine wants a second session in the same client. Against the
            // owner's server that session is never answered (B, B2, B3', C),
            // while a fresh client is — so every reconnect becomes a fresh
            // engine, under the attempt deadline armed by startEngine().
            if state.withLock({ $0.isConnected }) {
                restartFresh(reason: "engine reconnecting")
            }
        case "PAUSE":
            reasserting = true
        case "NEED_CREDS":
            // The engine has nothing to sign in with. Not a rejection: sending
            // the user to check a password that was never offered would be
            // the wrong remedy.
            failAttempt(
                FailureDetail(.credentialsUnavailable, detail: "\(event.name): \(event.info)"))
        case "AUTH_FAILED", "SESSION_EXPIRED":
            // The server refused what we offered. If that was a token, it is
            // stale rather than wrong, and there may be a password behind it.
            if retryWithoutTheToken() { return }
            // What the user has to do differs, so the two are not one failure:
            // a refused password means the details are wrong, while a refused
            // token with nothing behind it means nobody here can sign in.
            let failure: TunnelFailure =
                current.isToken ? .credentialsUnavailable : .authenticationFailed
            failAttempt(FailureDetail(failure, detail: "\(event.name): \(event.info)"))
        default:
            // Through the model, whatever state it is in. Failing only the
            // pending start covered an attempt, and left a fatal error *after*
            // CONNECTED with nowhere to go: the engine's `COMPRESS_ERROR`
            // arrived, the start had long since completed, and the tunnel
            // vanished without a word (measured 2026-09-08). M6 gives these
            // events their names; until then the model says exactly what it
            // knows, which is that it ended.
            if event.isFatal {
                // A9's event, A10's code: the one table where they meet
                // (OpenVPNFailures.swift). Server text travels only for the
                // events whose words are the server's (D104).
                failAttempt(FailureDetail.forEvent(event.name, info: event.info))
            }
        }
    }

    /// Keeps the token the server issued, when it issued one.
    ///
    /// Always in memory, so a fresh session after wake offers the freshest
    /// credential. Stored only for a profile whose sign-in details the user
    /// agreed to keep: a token is not the password, but keeping one would
    /// still let this profile connect with nobody present, and that is a
    /// capability the user declined (D220).
    private func rememberSessionToken() {
        guard let fresh = engine?.sessionToken else { return }
        let rotated = token?.token != fresh.token
        token = fresh
        guard let identifier else { return }
        guard saved != nil else {
            log.notice(
                "the server issued a session token; not stored, because this profile's sign-in details are not saved"
            )
            return
        }
        guard rotated, let encoded = fresh.encoded else { return }
        do {
            try secrets.set(encoded, for: SecretKind.sessionToken.account(for: identifier))
            log.notice("stored the session token for \(identifier.uuidString, privacy: .public)")
        } catch {
            log.error(
                "could not store the session token: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Drops a refused session token and starts a fresh session with whatever
    /// is behind it. Returns false when there is nothing behind it, or when
    /// what was refused was never a token — in both cases the caller ends the
    /// attempt honestly.
    private func retryWithoutTheToken() -> Bool {
        guard current.isToken, !tokenRefused else { return false }
        tokenRefused = true
        token = nil
        if let identifier {
            // A token the server has refused is worse than no token: it will
            // be refused again on every connection until something removes it.
            do {
                try secrets.remove(for: SecretKind.sessionToken.account(for: identifier))
            } catch {
                log.error(
                    "could not remove the refused session token: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !chooseSignIn().isEmpty else {
            log.notice("the session token was refused and there is no password behind it")
            return false
        }
        log.notice("the session token was refused; trying the password behind it")
        restartFresh(reason: "the session token was refused")
        return true
    }

    private func runEnded(_ result: Result<Void, Engine.Failure>) {
        let (wasConnected, stopping, restarting, ended) = state.withLock {
            ($0.isConnected, $0.stopping, $0.restarting, $0.attemptEnded)
        }
        switch result {
        case .success:
            log.notice("engine finished")
        case .failure(let failure):
            log.error("engine ended with error: \(failure.message, privacy: .public)")
        }
        // A fresh session is taking this one's place, and its outcome is the
        // tunnel's. Failing the pending start here would end an attempt that
        // is still running — which is what the token fallback does before the
        // tunnel has ever come up.
        if restarting { return }
        // An end the model already knows about — a fatal event went through
        // `failAttempt` first — is not applied again (`attemptEnded`).
        switch result {
        case .success:
            if !stopping, !ended { apply(.tornDown) }
            finishStart(with: Failure("The connection ended before it was established."))
        case .failure(let failure):
            // The engine's own message is not a code. M6 maps them; until
            // then the honest answer is that we do not know which of A9's
            // modes this was, and the model says exactly that.
            if !stopping, !ended { apply(.ended(FailureDetail(.unknown, detail: failure.message))) }
            finishStart(with: Failure(failure.message))
        }
        if wasConnected, !stopping {
            // The tunnel was up and the engine ended on its own: let NE tear the
            // session down so System Settings and the app see Disconnected.
            cancelTunnelWithError(result.failureError)
        }
    }

    /// Calls the start completion exactly once.
    private func finishStart(with error: Error?) {
        let completion = state.withLock { s -> Completion? in
            defer { s.startCompletion = nil }
            return s.startCompletion
        }
        completion?.call(error)
    }

    /// Turns the engine's request into NetworkExtension settings, applies them,
    /// and hands back the utun descriptor the engine will drive (D209).
    private func establish(_ s: Engine.Settings) -> Int32? {
        log.notice(
            "establish: remote=\(s.remoteAddress, privacy: .public) mtu=\(s.mtu, privacy: .public) addresses=\(s.addresses.count, privacy: .public) routes=\(s.includedRoutes.count, privacy: .public) excluded=\(s.excludedRoutes.count, privacy: .public) reroute4=\(s.rerouteIPv4, privacy: .public) reroute6=\(s.rerouteIPv6, privacy: .public) dns=\(s.dnsServers.count, privacy: .public) domains=\(s.searchDomains.count, privacy: .public)"
        )

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: s.remoteAddress)
        if s.mtu > 0 { settings.mtu = NSNumber(value: s.mtu) }

        let v4 = s.addresses.filter { !$0.isIPv6 }
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(
                addresses: v4.map(\.address),
                subnetMasks: v4.map { Self.mask(prefix: $0.prefixLength) })
            var included = s.includedRoutes.filter { !$0.isIPv6 }.map {
                NEIPv4Route(
                    destinationAddress: $0.address, subnetMask: Self.mask(prefix: $0.prefixLength))
            }
            if s.rerouteIPv4 { included.insert(NEIPv4Route.default(), at: 0) }
            ipv4.includedRoutes = included
            ipv4.excludedRoutes = s.excludedRoutes.filter { !$0.isIPv6 }.map {
                NEIPv4Route(
                    destinationAddress: $0.address, subnetMask: Self.mask(prefix: $0.prefixLength))
            }
            settings.ipv4Settings = ipv4  // D207: assigned after it is complete
        }

        let v6 = s.addresses.filter(\.isIPv6)
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(
                addresses: v6.map(\.address),
                networkPrefixLengths: v6.map { NSNumber(value: $0.prefixLength) })
            var included = s.includedRoutes.filter(\.isIPv6).map {
                NEIPv6Route(
                    destinationAddress: $0.address,
                    networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            if s.rerouteIPv6 { included.insert(NEIPv6Route.default(), at: 0) }
            ipv6.includedRoutes = included
            ipv6.excludedRoutes = s.excludedRoutes.filter(\.isIPv6).map {
                NEIPv6Route(
                    destinationAddress: $0.address,
                    networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            settings.ipv6Settings = ipv6
        }

        if !s.dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: s.dnsServers)
            // B10/D197: when the tunnel carries all traffic its resolver answers
            // every query; otherwise only the pushed domains go to it.
            dns.matchDomains = s.rerouteIPv4 || s.rerouteIPv6 ? [""] : s.searchDomains
            dns.searchDomains = s.searchDomains
            settings.dnsSettings = dns
        }

        let applied = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        setTunnelNetworkSettings(settings) { error in
            failure = error
            applied.signal()
        }
        applied.wait()
        if let failure {
            log.error(
                "setTunnelNetworkSettings failed: \(failure.localizedDescription, privacy: .public)"
            )
            return nil
        }
        // The process outlives sessions, so more than one utun descriptor may
        // be open; the tunnel is the one carrying the address just applied.
        let candidates = UTunDescriptor.all()
        log.notice(
            "utun descriptors in this process: \(candidates.map(\.description).joined(separator: " "), privacy: .public)"
        )
        guard let address = v4.first?.address, let utun = UTunDescriptor.find(carrying: address)
        else {
            log.error(
                "settings applied but no utun descriptor carries \(v4.first?.address ?? "no address", privacy: .public)"
            )
            return nil
        }
        // The engine owns what it is given and closes it on teardown. It gets
        // a duplicate, so NE's own descriptor — the tunnel — survives a
        // teardown and a re-establish (D209).
        let owned = dup(utun.fd)
        log.notice(
            "settings applied; tunnel \(utun.name, privacy: .public) fd=\(utun.fd, privacy: .public), engine gets fd=\(owned, privacy: .public)"
        )
        return owned < 0 ? nil : owned
    }

    private static func mask(prefix: Int) -> String {
        let bits: UInt32 =
            prefix >= 32 ? 0xffff_ffff : prefix <= 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return "\(bits >> 24).\((bits >> 16) & 0xff).\((bits >> 8) & 0xff).\(bits & 0xff)"
    }

    /// The provider's own failures, in the words the log needs. User-facing
    /// wording is A10's job and arrives with M6.
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private extension Result where Failure == Engine.Failure {
    var failureError: Error? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
