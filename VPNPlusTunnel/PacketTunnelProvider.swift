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
import os

/// The provider: it owns one engine per connection and turns what the engine
/// asks for into what NetworkExtension applies. It never edits routes or DNS
/// itself — the OS applies the settings and the OS removes them (B1, B14, C4).
///
/// The completion-handler overrides are not a style choice: under Swift 6
/// strict concurrency the `async` forms cannot be overridden here, because
/// `[String: NSObject]?` is not Sendable and the superclass method is
/// nonisolated.
// @unchecked Sendable: the engine's callbacks arrive on its connect thread and
// touch this object only through the lock below and the loggers.
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
    private let finished = DispatchSemaphore(value: 0)
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
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.notice("provider start uid=\(getuid(), privacy: .public) euid=\(geteuid(), privacy: .public)")
        log.notice("engine openvpn3 \(String(cString: vpnplus_engine_version()), privacy: .public) (\(String(cString: vpnplus_engine_platform()), privacy: .public))")

        // M2 ONLY — the profile and credentials arrive in the start options,
        // straight from the app's test path. M3 stores profiles and M4 moves
        // credentials behind the XPC interface; a start from System Settings
        // (D75) cannot work until then, and says so.
        guard let profile = options?["profile"] as? String, !profile.isEmpty else {
            log.error("no profile in the start options; until M3 a connection must start from the app")
            completionHandler(Failure("No profile was given. Until M3, connect from the VPN Plus window."))
            return
        }
        let username = options?["username"] as? String
        let password = options?["password"] as? String

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let engine = Engine(clientVersion: "VPNPlus/\(version)")
        self.engine = engine
        let completion = Completion(completionHandler)
        state.withLock { $0.startCompletion = completion; $0.connected = false; $0.stopping = false }

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

        do {
            try engine.prepare(profile: profile, username: username, password: password)
        } catch {
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
            finishStart(with: Failure("\(error)"))
            return
        }

        let thread = Thread { [weak self] in
            let result = engine.run()
            self?.runEnded(result)
        }
        thread.name = "engine.connect"
        thread.qualityOfService = .userInitiated
        runThread = thread
        thread.start()

        observeDefaultPath()
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
        if connected { engine?.resume() }
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
                log.notice("network changed while connected: reconnecting the transport")
                engine?.reconnect(after: 0)
            } else {
                log.notice("no network path; the engine keeps trying and reconnects when one returns")
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
            reasserting = false
            finishStart(with: nil)
        case "RECONNECTING", "PAUSE":
            // NE shows this as Reconnecting; the tunnel persists meanwhile.
            if state.withLock({ $0.connected }) { reasserting = true }
        default:
            if event.isFatal {
                finishStart(with: Failure("\(event.name): \(event.info)"))
            }
        }
    }

    private func runEnded(_ result: Result<Void, Engine.Failure>) {
        let (wasConnected, stopping) = state.withLock { ($0.connected, $0.stopping) }
        switch result {
        case .success:
            log.notice("engine finished")
            finishStart(with: Failure("The connection ended before it was established."))
        case .failure(let failure):
            log.error("engine ended with error: \(failure.message, privacy: .public)")
            finishStart(with: Failure(failure.message))
        }
        finished.signal()
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
        guard let utun = UTunDescriptor.find() else {
            log.error("settings applied but no utun descriptor was found")
            return nil
        }
        // The engine owns what it is given and closes it on teardown. It gets
        // a duplicate, so NE's own descriptor — the tunnel — survives a
        // teardown and a re-establish (D209).
        let owned = dup(utun.fd)
        log.notice("settings applied; tunnel descriptor \(utun.name, privacy: .public) fd=\(utun.fd, privacy: .public), engine gets fd=\(owned, privacy: .public)")
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
