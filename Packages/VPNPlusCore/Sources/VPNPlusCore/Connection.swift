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

/// What the tunnel is doing, with the facts each state actually has.
///
/// **The payloads are the point.** A session duration cannot be read while
/// connecting because it does not exist there, and an attempt clock cannot be
/// read once connected — which is D73 ("two clocks, never confused") enforced
/// by the type rather than by remembering. A1 found OpenVPN Connect showing a
/// frozen `00:00:00`, which is what one field for two clocks looks like.
///
/// Nothing here knows which protocol it is holding (D183). Phases arrive from
/// the adapter, already named and already carrying their deadline.
public enum Connection: Sendable, Equatable {
    case disconnected
    case connecting(Attempt)
    case connected(Session)
    case disconnecting(Teardown)
    case reconnecting(Attempt)
    /// Terminal: it needs the user (A8 rule 4).
    case failed(FailureRecord)

    /// The six-value identity, which is what feature-spec 3.1 names and what
    /// the status icon is derived from.
    public var state: TunnelState {
        switch self {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        case .reconnecting: .reconnecting
        case .failed: .failed
        }
    }

    /// The profile this is about, when it is about one.
    public var profile: Profile.ID? {
        switch self {
        case .disconnected: nil
        case .connecting(let attempt), .reconnecting(let attempt): attempt.profile
        case .connected(let session): session.profile
        case .disconnecting(let teardown): teardown.profile
        case .failed(let failure): failure.profile
        }
    }

    /// The session, if the tunnel is up.
    public var session: Session? {
        if case .connected(let session) = self { return session }
        return nil
    }

    /// The attempt in progress, if one is. Reconnecting is an attempt too —
    /// that is why they share the type and differ only in what they mean to
    /// the user.
    public var attempt: Attempt? {
        switch self {
        case .connecting(let attempt), .reconnecting(let attempt): attempt
        default: nil
        }
    }
}

/// One attempt to bring a tunnel up.
public struct Attempt: Sendable, Equatable {
    public let profile: Profile.ID
    public let startedAt: Date
    /// Zero for an attempt somebody asked for; 1… for automatic recovery,
    /// which is counted because D86 requires it to be bounded and *visible*.
    public let recovery: Int
    /// The phase the adapter last reported, and when it began. Nil until it
    /// reports one — the model never guesses a phase.
    public var phase: TunnelPhase?
    public var phaseEnteredAt: Date?

    public init(
        profile: Profile.ID,
        startedAt: Date,
        recovery: Int = 0,
        phase: TunnelPhase? = nil,
        phaseEnteredAt: Date? = nil
    ) {
        self.profile = profile
        self.startedAt = startedAt
        self.recovery = recovery
        self.phase = phase
        self.phaseEnteredAt = phaseEnteredAt
    }

    /// The **attempt** clock (D73). Never shown where a session duration
    /// belongs.
    public func elapsed(at now: Date) -> Duration {
        .seconds(max(0, now.timeIntervalSince(startedAt)))
    }

    /// The phase to name, or nil while the attempt is still fast enough that
    /// naming a step would be noise (D71).
    ///
    /// **The delay belongs to the attempt, not to each phase**, and that is a
    /// correction: measuring it against each phase separately made a real
    /// connection read *backwards*. At +2 s it said "Signing in"; at +4 s the
    /// next phase was only 100 ms old, so it fell back to the generic
    /// "Connecting" — a step being un-named looks like progress being lost
    /// (measured, 00:09:37).
    ///
    /// D71's purpose is that a **fast** connection says nothing internal. Once
    /// an attempt is slow enough to narrate, it narrates the step it is
    /// actually on. A step that lasts 150 ms then flickers past, which is
    /// untidy and true; keeping the previous step on screen would be tidy and
    /// false.
    public func revealedPhase(at now: Date) -> TunnelPhase? {
        guard let phase else { return nil }
        return elapsed(at: now) >= Deadlines.phaseReveal ? phase : nil
    }

    /// Which deadline has passed, if either has. **Every phase has a deadline
    /// and every attempt has a deadline** (feature-spec 3.5), and neither is
    /// the engine's own retry behaviour (3.7).
    public func expiry(at now: Date) -> Expiry? {
        if elapsed(at: now) >= Deadlines.attempt { return .attempt }
        if let phase, let phaseEnteredAt {
            let running = Duration.seconds(max(0, now.timeIntervalSince(phaseEnteredAt)))
            if running >= phase.deadline { return .phase(phase) }
        }
        return nil
    }
}

/// What ran out of time. Named, because "it timed out" without saying which
/// step is the failure this project exists to remove.
public enum Expiry: Sendable, Equatable {
    case phase(TunnelPhase)
    case attempt
}

/// A tunnel that is up.
public struct Session: Sendable, Equatable {
    public let profile: Profile.ID
    public let since: Date

    public init(profile: Profile.ID, since: Date) {
        self.profile = profile
        self.since = since
    }

    /// The **session** clock (D73).
    public func duration(at now: Date) -> Duration {
        .seconds(max(0, now.timeIntervalSince(since)))
    }
}

/// A tunnel coming down.
public struct Teardown: Sendable, Equatable {
    /// Nil when we are tearing down something we cannot name — the OS may have
    /// started a connection we did not.
    public let profile: Profile.ID?
    public let startedAt: Date
    /// Set when this teardown is the **first half of a switch** (D70). The
    /// model carries the intent so both surfaces can narrate one operation
    /// rather than a disconnect that happens to be followed by a connect.
    public let switchingTo: Profile.ID?

    public init(profile: Profile.ID?, startedAt: Date, switchingTo: Profile.ID? = nil) {
        self.profile = profile
        self.startedAt = startedAt
        self.switchingTo = switchingTo
    }

    public var isSwitch: Bool { switchingTo != nil }

    /// Past this, force the teardown and restore anyway (D39). A tunnel that
    /// will not come down is not a reason to leave the system half-configured.
    public func expired(at now: Date) -> Bool {
        Duration.seconds(max(0, now.timeIntervalSince(startedAt))) >= Deadlines.disconnect
    }
}
