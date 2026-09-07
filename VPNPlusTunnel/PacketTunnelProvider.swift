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
    private var connectedAt: Date?
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
        var connected = false
        var stopping = false
        /// The engine is being replaced by a fresh one; its ending must not
        /// end the tunnel.
        var restarting = false
    }

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
    private let secrets = ExtensionSecretStore()
    private var deadline: DispatchWorkItem?
    private var transportPoll: DispatchWorkItem?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice("provider start uid=\(getuid(), privacy: .public) euid=\(geteuid(), privacy: .public)")
        log.notice("engine openvpn3 \(String(cString: vpnplus_engine_version()), privacy: .public) (\(String(cString: vpnplus_engine_platform()), privacy: .public))")

        // Which profile this is, from providerConfiguration — a handle, never
        // a secret (D191). A connection from System Settings carries this and
        // nothing else, which is what makes D75 possible.
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let identifier = (configuration?["profile"] as? String).flatMap(UUID.init(uuidString:))
        self.identifier = identifier

        let completion = Completion(completionHandler)
        state.withLock { $0.startCompletion = completion; $0.connected = false; $0.stopping = false }

        // The configuration text: what the app handed over, if this is the
        // first connection since importing, else our own stored copy.
        var profile = options?["profile"] as? String
        if let identifier, let handed = profile {
            // Keep it, so every later connection — including one started from
            // System Settings with no app running — needs nothing from anyone.
            do {
                try secrets.set(Data(handed.utf8), for: SecretKind.configuration.account(for: identifier))
                log.notice("stored the configuration for \(identifier.uuidString, privacy: .public)")
            } catch {
                log.error("could not store the configuration: \(error.localizedDescription, privacy: .public)")
            }
        } else if let identifier {
            do {
                let stored = try secrets.secret(for: SecretKind.configuration.account(for: identifier))
                profile = stored.flatMap { String(data: $0, encoding: .utf8) }
                log.notice("read our own configuration for \(identifier.uuidString, privacy: .public): \(profile == nil ? "absent" : "present", privacy: .public)")
            } catch {
                log.error("could not read the configuration: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard let profile, !profile.isEmpty else {
            log.error("no configuration for this profile, in the options or our own store")
            failAttempt(TunnelFailure.configurationMissing.error(
                "The extension holds no configuration for this profile and none was handed to it."))
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
            failAttempt(TunnelFailure.credentialsUnavailable.error(
                "This profile needs a password and the extension has none saved for it."))
            return
        }

        self.serverOverride = Engine.ServerOverride(
            host: options?["serverHost"] as? String ?? "",
            port: options?["serverPort"] as? String ?? "",
            transport: options?["serverTransport"] as? String ?? "")
        if !serverOverride.isEmpty {
            log.notice("server override: \(self.serverOverride.host, privacy: .public):\(self.serverOverride.port, privacy: .public) \(self.serverOverride.transport, privacy: .public)")
        }

        startEngine()
        observeDefaultPath()
    }

    /// Reads every credential this session might use: our own two stored
    /// items, and whatever the app supplied for a session it was asked not to
    /// remember.
    private func readCredentials(from options: [String: NSObject]?) {
        if let username = options?["username"] as? String, let password = options?["password"] as? String {
            supplied = StoredCredentials(username: username, password: password)
        }
        guard let identifier else { return }
        if let data = ((try? secrets.secret(for: SecretKind.password.account(for: identifier))) ?? nil) {
            saved = StoredCredentials(data)
        }
        if let data = ((try? secrets.secret(for: SecretKind.sessionToken.account(for: identifier))) ?? nil) {
            token = StoredSessionToken(data)
        }
    }

    /// The freshest credential available, and where it came from.
    private func chooseSignIn() -> SignIn {
        if let token {
            // The server may name its own user for the token
            // (`auth-token-user`); using ours instead would fail an
            // authentication that would otherwise have worked.
            let username = token.username.isEmpty
                ? (saved?.username ?? supplied?.username ?? "")
                : token.username
            return SignIn(username: username, password: token.token, source: .token)
        }
        if let saved { return SignIn(username: saved.username, password: saved.password, source: .saved) }
        if let supplied {
            return SignIn(username: supplied.username, password: supplied.password, source: .supplied)
        }
        return SignIn()
    }

    /// Creates an engine for the stored profile and runs it on its own thread.
    /// Used for the first connection and for every fresh session after it.
    private func startEngine() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let engine = Engine(clientVersion: "VPNPlus/\(version)")
        self.engine = engine

        engine.onLog = { [engineLog] text in
            engineLog.notice("\(text, privacy: .public)")
        }
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.onEstablish = { [weak self] settings in self?.establish(settings) }
        engine.onTeardown = { [log] disconnect in
            // Nothing of ours to undo: the OS applied the settings and the OS
            // removes them.
            log.notice("engine teardown disconnect=\(disconnect, privacy: .public)")
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
                server: serverOverride)
        } catch {
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
            failAttempt(Failure("\(error)"))
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
            guard let self, let engine, !state.withLock({ $0.connected || $0.stopping }) else { return }
            let stats = engine.transportCounters
            log.notice("transport: in=\(stats.bytesIn, privacy: .public) out=\(stats.bytesOut, privacy: .public) lastPacket=\(engine.millisecondsSinceLastPacket.map(String.init) ?? "never", privacy: .public)ms")
            pollTransport()
        }
        transportPoll = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: item)
    }

    // MARK: - Deadlines (D177, A8)

    /// The engine never gives up on its own. This does: an attempt that has not
    /// reached CONNECTED within the attempt deadline ends the tunnel, so the
    /// user gets the network back and a reason instead of "Reconnecting".
    private func armDeadline() {
        deadline?.cancel()
        let seconds = Int(Deadlines.attempt.components.seconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self, !state.withLock({ $0.connected }) else { return }
            log.error("no connection after \(seconds, privacy: .public) s; ending the attempt")
            failAttempt(Failure("The server did not finish the connection within \(seconds) seconds."))
        }
        deadline = item
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
    }

    /// Ends the current attempt honestly: fails the start if one is pending,
    /// otherwise cancels the tunnel so every surface shows Disconnected.
    private func failAttempt(_ failure: any Error) {
        let pending = state.withLock { $0.startCompletion != nil }
        if pending {
            finishStart(with: failure)
        }
        engine?.stop()
        cancelTunnelWithError(failure)
    }

    /// Replaces the engine with a fresh session, keeping the tunnel. B3'
    /// measured that a resumed session never gets its config from the owner's
    /// server while a fresh one does (A2), so this is what sleep/wake uses.
    private func restartFresh(reason: String) {
        let (already, wasConnected) = state.withLock { s -> (Bool, Bool) in
            if s.restarting { return (true, s.connected) }
            let connected = s.connected
            s.restarting = true; s.connected = false
            return (false, connected)
        }
        if already { return }
        log.notice("starting a fresh session: \(reason, privacy: .public)")
        // Only a tunnel that was up can be reasserted. Saying so before the
        // first connection would show "Reconnecting" for something that has
        // never connected.
        if wasConnected { reasserting = true }
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
                    log.error("could not clear the tunnel settings: \(error.localizedDescription, privacy: .public)")
                } else {
                    log.notice("tunnel settings cleared; the physical network is primary while we reconnect")
                }
                cleared.signal()
            }
            _ = cleared.wait(timeout: .now() + 5)
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
        let connected = state.withLock { $0.connected }
        log.notice("sleep; connected=\(connected, privacy: .public)")
        if connected { engine?.pause(reason: "sleep") }
        completionHandler()
    }

    override func wake() {
        let connected = state.withLock { $0.connected }
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
            let (connected, since) = state.withLock { ($0.connected, connectedAt) }
            let settleSeconds = since.map { Date().timeIntervalSince($0) } ?? 0
            let previous = lastPathDescription
            lastPathDescription = now
            guard now != previous else { return }
            log.notice("network path: \(now, privacy: .public) (was \(previous.isEmpty ? "unknown" : previous, privacy: .public)); connected=\(connected, privacy: .public) since=\(Int(settleSeconds), privacy: .public)s")
            guard connected, settleSeconds > 5, !previous.isEmpty else { return }
            if path.status == .satisfied {
                // C measured that the engine's own reconnect on this path is
                // never answered by the server; a fresh engine is.
                restartFresh(reason: "network changed")
            } else {
                // Quiet the engine while there is nothing to send on; the
                // return of a path restarts fresh above.
                log.notice("no network path; pausing the engine until one returns")
                reasserting = true
                engine?.pause(reason: "network gone")
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
        let interfaces = path.availableInterfaces.map(\.name).filter { !$0.hasPrefix("utun") }.sorted()
        return "\(status) via \(interfaces.joined(separator: ","))\(path.isExpensive ? " expensive" : "")"
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.notice("provider stop reason=\(reason.rawValue, privacy: .public)")
        state.withLock { $0.stopping = true }
        deadline?.cancel()
        transportPoll?.cancel()
        pathMonitor.cancel()
        guard let engine else { completionHandler(); return }
        engine.stop()
        // The connect thread returns once the engine has wound down; give it a
        // bounded moment so a stuck engine cannot hold the stop forever.
        _ = runFinished?.wait(timeout: .now() + 5)
        self.engine = nil
        completionHandler()
    }

    // MARK: - Engine callbacks (connect thread)

    private func handle(_ event: Engine.Event) {
        log.notice("event \(event.name, privacy: .public) \(event.info, privacy: .public)\(event.isFatal ? " (fatal)" : "", privacy: .public)")
        switch event.name {
        case "CONNECTED":
            if let info = engine?.connectionInfo {
                log.notice("connected to \(info.serverHost, privacy: .public):\(info.serverPort, privacy: .public) via \(info.serverProto, privacy: .public), tunnel address \(info.vpnIPv4, privacy: .public) on \(info.tunName, privacy: .public)")
            }
            state.withLock { $0.connected = true }
            connectedAt = Date()
            deadline?.cancel()
            transportPoll?.cancel()
            reasserting = false
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
            if state.withLock({ $0.connected }) {
                restartFresh(reason: "engine reconnecting")
            }
        case "PAUSE":
            reasserting = true
        case "NEED_CREDS":
            // The engine has nothing to sign in with. Not a rejection: sending
            // the user to check a password that was never offered would be
            // the wrong remedy.
            failAttempt(TunnelFailure.credentialsUnavailable.error("\(event.name): \(event.info)"))
        case "AUTH_FAILED", "SESSION_EXPIRED":
            // The server refused what we offered. If that was a token, it is
            // stale rather than wrong, and there may be a password behind it.
            if retryWithoutTheToken() { return }
            // What the user has to do differs, so the two are not one failure:
            // a refused password means the details are wrong, while a refused
            // token with nothing behind it means nobody here can sign in.
            let failure: TunnelFailure = current.isToken ? .credentialsUnavailable : .authenticationFailed
            failAttempt(failure.error("\(event.name): \(event.info)"))
        default:
            if event.isFatal {
                finishStart(with: Failure("\(event.name): \(event.info)"))
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
            log.notice("the server issued a session token; not stored, because this profile's sign-in details are not saved")
            return
        }
        guard rotated, let encoded = fresh.encoded else { return }
        do {
            try secrets.set(encoded, for: SecretKind.sessionToken.account(for: identifier))
            log.notice("stored the session token for \(identifier.uuidString, privacy: .public)")
        } catch {
            log.error("could not store the session token: \(error.localizedDescription, privacy: .public)")
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
                log.error("could not remove the refused session token: \(error.localizedDescription, privacy: .public)")
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
        let (wasConnected, stopping, restarting) = state.withLock { ($0.connected, $0.stopping, $0.restarting) }
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
        switch result {
        case .success:
            finishStart(with: Failure("The connection ended before it was established."))
        case .failure(let failure):
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
        log.notice("establish: remote=\(s.remoteAddress, privacy: .public) mtu=\(s.mtu, privacy: .public) addresses=\(s.addresses.count, privacy: .public) routes=\(s.includedRoutes.count, privacy: .public) excluded=\(s.excludedRoutes.count, privacy: .public) reroute4=\(s.rerouteIPv4, privacy: .public) reroute6=\(s.rerouteIPv6, privacy: .public) dns=\(s.dnsServers.count, privacy: .public) domains=\(s.searchDomains.count, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: s.remoteAddress)
        if s.mtu > 0 { settings.mtu = NSNumber(value: s.mtu) }

        let v4 = s.addresses.filter { !$0.isIPv6 }
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4.map(\.address), subnetMasks: v4.map { Self.mask(prefix: $0.prefixLength) })
            var included = s.includedRoutes.filter { !$0.isIPv6 }.map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: Self.mask(prefix: $0.prefixLength))
            }
            if s.rerouteIPv4 { included.insert(NEIPv4Route.default(), at: 0) }
            ipv4.includedRoutes = included
            ipv4.excludedRoutes = s.excludedRoutes.filter { !$0.isIPv6 }.map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: Self.mask(prefix: $0.prefixLength))
            }
            settings.ipv4Settings = ipv4  // D207: assigned after it is complete
        }

        let v6 = s.addresses.filter(\.isIPv6)
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: v6.map(\.address), networkPrefixLengths: v6.map { NSNumber(value: $0.prefixLength) })
            var included = s.includedRoutes.filter(\.isIPv6).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            if s.rerouteIPv6 { included.insert(NEIPv6Route.default(), at: 0) }
            ipv6.includedRoutes = included
            ipv6.excludedRoutes = s.excludedRoutes.filter(\.isIPv6).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefixLength))
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
            log.error("setTunnelNetworkSettings failed: \(failure.localizedDescription, privacy: .public)")
            return nil
        }
        // The process outlives sessions, so more than one utun descriptor may
        // be open; the tunnel is the one carrying the address just applied.
        let candidates = UTunDescriptor.all()
        log.notice("utun descriptors in this process: \(candidates.map(\.description).joined(separator: " "), privacy: .public)")
        guard let address = v4.first?.address, let utun = UTunDescriptor.find(carrying: address) else {
            log.error("settings applied but no utun descriptor carries \(v4.first?.address ?? "no address", privacy: .public)")
            return nil
        }
        // The engine owns what it is given and closes it on teardown. It gets
        // a duplicate, so NE's own descriptor — the tunnel — survives a
        // teardown and a re-establish (D209).
        let owned = dup(utun.fd)
        log.notice("settings applied; tunnel \(utun.name, privacy: .public) fd=\(utun.fd, privacy: .public), engine gets fd=\(owned, privacy: .public)")
        return owned < 0 ? nil : owned
    }

    private static func mask(prefix: Int) -> String {
        let bits: UInt32 = prefix >= 32 ? 0xffff_ffff : prefix <= 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
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
