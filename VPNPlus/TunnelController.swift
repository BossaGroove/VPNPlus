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
import NetworkExtension
import VPNPlusCore
import os

/// Creates and drives the VPN configuration. The real connection model
/// (docs/ux/state-model.md) arrives with the engine in M2 and M5; this is the
/// minimum needed to start and stop the tunnel and observe its status.
@MainActor
final class TunnelController {
    static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "tunnel")

    private(set) var status: NEVPNStatus = .invalid {
        didSet { if status != oldValue { announce() } }
    }

    /// Everything that renders this model.
    ///
    /// **A list, not a callback**, because there are two surfaces now and
    /// commitment 6 says they cannot disagree. They cannot, because there is
    /// one model and they are both told about it here — rather than one being
    /// derived from the other, which is how they would drift (D93).
    private var observers: [(Connection, NEVPNStatus) -> Void] = []

    func observe(_ observer: @escaping (Connection, NEVPNStatus) -> Void) {
        observers.append(observer)
        observer(connection, status)
    }

    private func announce() {
        for observer in observers { observer(connection, status) }
    }

    private var manager: NETunnelProviderManager?

    // Written once on the main actor in `init`, read once in `deinit`, which
    // Swift 6 runs nonisolated. There is no window for concurrent access, and
    // the alternative — dropping the deinit because this object happens to
    // live for the app's lifetime — would be true today and a leak later.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            // D75 — observe, never assume. This is also how a connect made
            // from System Settings reaches us.
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        watchReports()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if reportToken != NOTIFY_TOKEN_INVALID { notify_cancel(reportToken) }
    }

    /// Loads the configuration that already exists, without creating or
    /// saving anything.
    ///
    /// Called at launch so the window can say what the *system* is doing
    /// before the user has asked for anything — including why a connection
    /// they started from System Settings, with this app not running, did not
    /// work (D75). Saving is what raises the configuration prompt; loading
    /// raises nothing.
    func load() async {
        do {
            let existing = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = existing.first else {
                Self.log.notice("no VPN configuration to load")
                return
            }
            self.manager = manager
            Self.log.notice(
                "loaded the existing configuration; status \(manager.connection.status.rawValue, privacy: .public)"
            )
            refreshStatus()
        } catch {
            Self.log.error(
                "could not load the configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads the existing configuration or creates one. Saving is what raises
    /// the "would like to add VPN configurations" prompt — C4 counts it.
    /// `name` becomes the configuration's name in **System Settings**.
    ///
    /// C6 leaves us one OS-level VPN configuration, so macOS shows a single
    /// entry — and a single entry called "VPN Plus" gives no indication of
    /// *which* profile it will connect. A user toggling it from System
    /// Settings expecting Singapore may get Hong Kong, and nothing anywhere
    /// told them otherwise.
    ///
    /// So we name it after the active profile and rewrite it on every switch,
    /// which we are doing anyway — rewriting that configuration is *how*
    /// switching works. Free, honest, and it turns C6's constraint from a trap
    /// into a label (A13). Neither incumbent does this.
    func prepare(profile: UUID? = nil, name: String? = nil) async throws {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existing.first ?? NETunnelProviderManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.bossagroove.VPNPlus.tunnel"
        proto.serverAddress = "VPN Plus"
        // Handles and switches only, never secrets (D191). Nothing yet.
        // Handles, never secrets (D191): this dictionary lives in the system's
        // VPN preferences and is readable with admin rights.
        proto.providerConfiguration = profile.map { ["profile": $0.uuidString as NSString] } ?? [:]

        manager.protocolConfiguration = proto
        manager.localizedDescription =
            name.map { String(localized: "VPN Plus — \($0)") } ?? "VPN Plus"
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        refreshStatus()
    }

    /// Starts the tunnel for a profile the extension already knows about.
    ///
    /// What still crosses in the start options, and why: the configuration
    /// **only** until the extension has been given it, and the sign-in details
    /// **only** for a session the user asked not to save. Everything the
    /// extension owns, it reads itself — which is what lets a connection start
    /// from System Settings with no app running (D75).
    func connect(
        id: Profile.ID,
        profile: String?,
        username: String,
        password: String,
        server: ServerEndpoint = ServerEndpoint()
    ) throws {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        stoppedByUser = false
        var options: [String: NSObject] = [:]
        // **The id travels with the start, not only in the saved
        // configuration.** `prepare` saves the id into providerConfiguration
        // and the session is even *named* for it — and 6 of 56 sessions on
        // 2026-09-08 still started the *previous* profile: the system handed
        // the provider a protocolConfiguration from before the save. A handle
        // in the options is what the user asked for at the moment they asked,
        // and the provider prefers it (D191: handles, never secrets).
        options["profileID"] = id.uuidString as NSString
        // Sent only while a profile has not yet been handed over: the provider
        // stores what it receives, so the first connection completes the move
        // and later ones carry nothing but the id in providerConfiguration.
        if let profile { options["profile"] = profile as NSString }
        if !username.isEmpty { options["username"] = username as NSString }
        if !password.isEmpty { options["password"] = password as NSString }
        // Only what the user chose: an override equal to the profile's own
        // value is not an override, and the model already decided that.
        if !server.host.isEmpty { options["serverHost"] = server.host as NSString }
        if !server.port.isEmpty { options["serverPort"] = server.port as NSString }
        if !server.transport.isEmpty { options["serverTransport"] = server.transport as NSString }
        try session.startVPNTunnel(options: options)
    }

    /// Brings the current session down and starts the next one — **as one
    /// operation** (D70).
    ///
    /// The user clicks Connect on another profile, once. That is the whole
    /// interaction: they are never asked to disconnect first, and the profile
    /// list is never disabled. OpenVPN Connect makes the user do both steps,
    /// which is the failure this exists to remove.
    ///
    /// `destination` is held so both surfaces can narrate **one** identity
    /// throughout: the promoted region shows what the user asked for from the
    /// moment they ask (A13), not the profile that happens to be coming down.
    func replaceSession(with destination: Profile.ID, then start: @escaping () -> Void) {
        pendingSwitch = destination
        Self.log.notice(
            "switching to \(destination.uuidString, privacy: .public); tearing the current session down first"
        )
        connection = decorate(connection)
        disconnect()

        // The second half begins when the first finishes, and only then — so
        // no surface ever has a Disconnected state to render in between.
        observe { [weak self] connection, _ in
            guard let self, pendingSwitch == destination, connection.state == .disconnected else {
                return
            }
            pendingSwitch = nil
            Self.log.notice("teardown finished; connecting the profile the user asked for")
            start()
        }
    }

    /// The profile the user asked for while another was still coming down.
    private(set) var pendingSwitch: Profile.ID?

    /// Adds the switch's intent to a state that cannot carry it on its own.
    ///
    /// The provider reports a teardown; only the app knows it is the first
    /// half of something. Held here rather than in the provider because the
    /// user told *the app*, and a report that has to be enriched is better
    /// than a provider that has to be told our plans.
    private func decorate(_ connection: Connection) -> Connection {
        guard let pendingSwitch, case .disconnecting(let teardown) = connection else {
            return connection
        }
        return .disconnecting(
            Teardown(
                profile: teardown.profile, startedAt: teardown.startedAt,
                switchingTo: pendingSwitch))
    }

    func disconnect() {
        stoppedByUser = true
        (manager?.connection as? NETunnelProviderSession)?.stopVPNTunnel()
    }

    /// True when the last thing that happened was the user asking to stop.
    ///
    /// NetworkExtension keeps the last disconnect error until something
    /// replaces it, so without this a reason from an earlier attempt would
    /// reappear every time the user disconnected on purpose.
    private(set) var stoppedByUser = false

    /// Why the last attempt ended, as the provider itself reported it.
    ///
    /// NetworkExtension keeps the error the provider cancelled with, which is
    /// the only way a connection started from **System Settings**, with this
    /// app not running, can explain itself to the user afterwards (D75). The
    /// code crosses; the words are ours (A10).
    func lastFailure() async -> Failure? {
        guard let connection = manager?.connection else { return nil }
        return await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { error in
                guard let error else {
                    continuation.resume(returning: nil)
                    return
                }
                // Read here rather than handed on: an Error is not Sendable,
                // and nothing past this point needs the object itself.
                continuation.resume(
                    returning: Failure(
                        kind: TunnelFailure(error),
                        detail: error.localizedDescription,
                        at: TunnelFailure.time(of: error),
                        record: FailureRecord(error: error)))
            }
        }
    }

    /// Takes the provider's last word from the one place it outlives the
    /// provider, and puts it into the model.
    ///
    /// `fetchLastDisconnectError` and the report cover each other: the report
    /// is richer and needs a living provider, while the error survives its
    /// death. An attempt that fails in 27 ms has nothing left to ask — and it
    /// is exactly the attempt whose reason the user most needs.
    func recoverFailureIfNeeded() async {
        guard connection.state == .disconnected,
            let failure = await lastFailure(), let kind = failure.kind
        else { return }
        // Only a recent one: a reason from last week is not what just
        // happened, and the model may not claim otherwise (D96).
        if let at = failure.at, Date().timeIntervalSince(at) > 15 * 60 { return }
        // The whole record when the provider sent one (M6.1); the code and
        // the time alone from an older extension. The provider names the
        // profile only when the start told it which, so the configuration's
        // answer fills in for a nameless one.
        let record: FailureRecord
        if let whole = failure.record {
            record =
                whole.profile == Self.unidentified
                ? FailureRecord(
                    profile: configuredProfile ?? whole.profile, at: whole.at, reason: whole.reason,
                    phase: whole.phase, elapsed: whole.elapsed,
                    recoveryAttempts: whole.recoveryAttempts, waited: whole.waited,
                    attempts: whole.attempts, serverText: whole.serverText, detail: whole.detail,
                    underlying: whole.underlying, foreignTunnel: whole.foreignTunnel)
                : whole
        } else {
            record = FailureRecord(
                profile: configuredProfile ?? UUID(), at: failure.at ?? Date(), reason: kind)
        }
        connection = ConnectionMachine.next(connection, on: .recoveredFailure(record))
        Self.log.notice(
            "recovered a failure the provider did not live to report: \(kind.rawValue, privacy: .public)"
        )
    }

    struct Failure: Sendable {
        /// Nil when the failure came from somewhere other than our provider.
        let kind: TunnelFailure?
        /// The provider's own words, for the log. Not localized.
        let detail: String
        /// When it happened, when it says. Nil is "unknown", never "old".
        let at: Date?
        /// Everything the provider knew, when it sent it (M6.1).
        let record: FailureRecord?
    }

    /// The id a provider reports under when its start named no profile —
    /// the same all-zero id the extension uses.
    private static let unidentified = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Which profile the system configuration is pointing at — a handle, which
    /// is all `providerConfiguration` ever holds (D191).
    var configuredProfile: UUID? {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
            let identifier = proto.providerConfiguration?["profile"] as? String
        else { return nil }
        return UUID(uuidString: identifier)
    }

    private func refreshStatus() {
        status = manager?.connection.status ?? .invalid
        // The system says *whether*; the provider says *what*. Both, in that
        // order, and never what we last asked for (D75).
        if let observed = Self.tunnelState(for: status) {
            connection = decorate(
                ConnectionMachine.next(
                    connection, on: .observed(observed, profile: configuredProfile)))
        }
        fetchReport()
        schedulePoll()
        // Nothing running, and possibly a reason lying about: pick it up.
        if status == .disconnected { Task { await recoverFailureIfNeeded() } }
    }

    // MARK: - What the provider says about itself (M5.2)

    /// The model, as the app holds it.
    ///
    /// A **mirror**, not a second opinion: the provider runs A8's machine and
    /// reports the result, and where it cannot speak the system's own status
    /// is read instead (D75). Nothing here is derived from what the app just
    /// asked for.
    private(set) var connection = Connection.disconnected {
        didSet { if connection != oldValue { announce() } }
    }

    /// What the provider read about the network before this attempt touched
    /// routing (D201). The window keeps it as the profile's last-good record
    /// once the tunnel is up, and the failure copy asks it whether this Mac is
    /// presenting a private address (feature-spec 4.11).
    private(set) var facts: NetworkFacts?

    private nonisolated(unsafe) var reportToken: Int32 = NOTIFY_TOKEN_INVALID
    private var poll: DispatchWorkItem?

    /// Listens for the provider's doorbell.
    ///
    /// The notification carries no payload — it says only *there is a reason
    /// to ask* — and the answer comes back over XPC where it can be typed.
    private func watchReports() {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(
            TunnelReportChannel.notification, &token, DispatchQueue.main
        ) { _ in
            MainActor.assumeIsolated {
                Self.log.notice("the provider rang")
                self.fetchReport()
            }
        }
        guard status == NOTIFY_STATUS_OK else {
            Self.log.error("could not listen for provider reports: \(status, privacy: .public)")
            return
        }
        reportToken = token
    }

    /// Asks the provider what it is doing.
    ///
    /// Fails quietly when there is nothing to ask — before a tunnel starts
    /// there is no provider, and that is the ordinary case rather than an
    /// error. The system's status still answers the question we can always
    /// ask, which is *is anything running*.
    func fetchReport() {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            Self.log.notice("no session to ask for a report")
            return
        }
        do {
            try session.sendProviderMessage(ProviderRequest.report.encoded()) { [weak self] reply in
                guard let self else { return }
                guard let reply,
                    let report = try? JSONDecoder().decode(TunnelReport.self, from: reply)
                else {
                    Self.log.notice("the provider replied with nothing usable")
                    return
                }
                MainActor.assumeIsolated { self.adopt(report) }
            }
        } catch {
            // Ordinary: before a tunnel starts, and after one ends, there is
            // no provider to ask. Logged while M5.2 is being measured.
            Self.log.notice(
                "cannot ask for a report: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Takes the provider's report, when the system agrees that it could be
    /// true.
    ///
    /// The provider is authoritative about *what it is doing*; the system is
    /// authoritative about *whether it is running at all*. When they
    /// disagree the system wins, because a provider that has died cannot
    /// retract its last word.
    private func adopt(_ report: TunnelReport) {
        guard report.version == TunnelReport.currentVersion else {
            Self.log.error("ignoring a report from a different version of the extension")
            return
        }
        let observed = (manager?.connection.status).flatMap(TunnelController.tunnelState(for:))
        // Failed is the exception: it *is* a disconnected tunnel, plus the
        // reason the system has no opinion about.
        let agrees =
            observed == nil || observed == report.state
            || (report.state == .failed && observed == .disconnected)
        guard agrees else {
            Self.log.notice(
                "the provider reports \(report.state.rawValue, privacy: .public) while the system says \(observed?.rawValue ?? "nothing", privacy: .public); trusting the system"
            )
            return
        }
        // A report that knows less than we do does not get to erase what we
        // know. **NetworkExtension does not keep one provider object per
        // configuration**: measured at 22:50:03, a message sent after a
        // session ended was answered *by the same process* from a freshly
        // created provider whose model was still `disconnected` — 24 ms after
        // the real one had concluded `failed`. It looks authoritative and is
        // not.
        //
        // This is the same rule the machine applies to an observation: Failed
        // is a disconnected tunnel plus a reason, and only the user leaves it.
        if report.state == .disconnected, connection.state == .failed {
            Self.log.notice(
                "ignoring a disconnected report over a failure the user has not seen yet")
            return
        }

        // Two channels can each deliver the same failure — this report, and
        // the error the system keeps after the provider is gone. The one that
        // knows more wins, whichever landed first (M6.1).
        if case .failed(let mine) = connection, case .failed(let theirs) = report.connection,
            mine.isFuller(than: theirs)
        {
            Self.log.notice("keeping the fuller failure record over the provider's report")
            return
        }
        if let told = report.facts { facts = told }
        let before = connection.state
        connection = decorate(report.connection)
        if before != connection.state {
            Self.log.notice(
                "model \(before.rawValue, privacy: .public) → \(self.connection.state.rawValue, privacy: .public) (from the provider)"
            )
        }
        if let phase = report.phase {
            Self.log.notice("phase \(phase, privacy: .public)")
        }
        if let foreign = report.foreignTunnel {
            Self.log.error(
                "another tunnel (\(foreign, privacy: .public)) owned the default route when this attempt started"
            )
        }
        schedulePoll()
    }

    /// The redacted record of what happened, for the Diagnostics sheet
    /// (M6.2, A14).
    ///
    /// Two sources, in this order, because they know different things:
    ///
    /// 1. **The running provider**, which has the attempt in flight — the one
    ///    the user is watching fail.
    /// 2. **The extension's own store**, over the privileged channel, which
    ///    has every attempt that finished and answers with **nothing
    ///    running** — the ordinary case, since the provider exits within a
    ///    second of a failure and D141 says the sheet opens without one.
    ///
    /// Whichever has more attempts wins; a tie goes to the live one.
    func diagnostics(for profile: Profile.ID) async -> DiagnosticsLog? {
        let live = await fromTheProvider(profile)
        let kept: DiagnosticsLog?
        do {
            kept = try await PrivilegedClient().diagnostics(for: profile)
        } catch {
            Self.log.notice(
                "no stored record: \(error.localizedDescription, privacy: .public)")
            kept = nil
        }
        switch (live, kept) {
        case (let live?, let kept?):
            return kept.attempts.count > live.attempts.count ? kept : live
        case (let live?, nil):
            return live
        case (nil, let kept?):
            return kept
        case (nil, nil):
            return nil
        }
    }

    /// The record as the running provider holds it, including the attempt in
    /// flight. Nil whenever there is no provider to ask, which is ordinary.
    private func fromTheProvider(_ profile: Profile.ID) async -> DiagnosticsLog? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            let once = OnceReply(continuation)
            do {
                try session.sendProviderMessage(
                    ProviderRequest.diagnostics(profile: profile).encoded()
                ) { reply in
                    // A report coming back means an extension older than this
                    // app, which answers every message with the model. It
                    // fails to decode, which is the honest outcome.
                    once.finish(reply.flatMap { try? JSONDecoder().decode(DiagnosticsLog.self, from: $0) })
                }
            } catch {
                once.finish(nil)
            }
        }
    }

    /// `sendProviderMessage` promises one call of its handler and cannot
    /// promise it when there is nothing listening; a continuation resumed
    /// twice would trap, and one never resumed would hang.
    private final class OnceReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<DiagnosticsLog?, Never>?

        init(_ continuation: CheckedContinuation<DiagnosticsLog?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: DiagnosticsLog?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Asks again, while an attempt is running, in case the doorbell was not
    /// heard. An interface showing a step that finished ten seconds ago is
    /// exactly the failure this milestone exists to remove.
    private func schedulePoll() {
        poll?.cancel()
        guard connection.state.isTransient else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fetchReport() }
        }
        poll = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TunnelReportChannel.pollWhileAttempting, execute: item)
    }

    /// The system's six values, as A8's six. `.invalid` means there is no
    /// configuration yet, which is not a tunnel state at all — the window
    /// layer says that, from whether setup is complete (D93).
    static func tunnelState(for status: NEVPNStatus) -> TunnelState? {
        switch status {
        case .invalid: nil
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .reasserting: .reconnecting
        case .disconnecting: .disconnecting
        @unknown default: nil
        }
    }
}

extension NEVPNStatus {
    var plainLanguage: String {
        switch self {
        case .invalid: "Not set up"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reasserting: "Reconnecting"
        case .disconnecting: "Disconnecting"
        @unknown default: "Unknown"
        }
    }
}
