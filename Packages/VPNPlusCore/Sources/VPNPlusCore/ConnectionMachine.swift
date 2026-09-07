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

/// Something that happened to the tunnel.
///
/// Note what is **not** here: no distinction between the user asking and the
/// OS asking. macOS can connect or disconnect our configuration without us
/// (feature-spec 3.11), and a model that treated the two differently would be
/// rendering its own last command as truth — which is exactly what D75
/// forbids. Where the request came from is worth *logging*; it changes no
/// state.
public enum TunnelEvent: Sendable, Equatable {
    /// Connect this profile. From the window, the menu, or System Settings.
    case connect(Profile.ID)
    /// The adapter has entered a phase.
    case entered(TunnelPhase)
    /// The tunnel is up and carrying traffic — not merely that a tunnel object
    /// exists (feature-spec 3.9).
    case established
    /// Bring it down. From anywhere, for any reason.
    case disconnect
    /// It was up, and it is not any more, and nobody asked for that.
    case dropped
    /// The teardown has finished.
    case tornDown
    /// It ended badly, with a reason.
    case failed(TunnelFailure)
    /// An attempt was abandoned before it finished. Bound by D77: an aborted
    /// attempt restores as completely as a clean disconnect.
    case cancelled
    /// A deadline passed. Which one is in the state, not in the event.
    case timedOut
    /// **Reality, read rather than assumed** (D75, D95). After sleep, after
    /// anything the OS did, after a gap in observation of any kind.
    case observed(TunnelState, profile: Profile.ID?)
    /// A failure found after the fact, from something that outlived the
    /// process which concluded it.
    ///
    /// Not a duplicate of `failed`: that one *is* the failure happening, while
    /// this one is picking a reason up off the floor. An attempt can end so
    /// fast that there is nothing left to ask by the time anyone asks — and
    /// the model still has to be able to say Failed, or the reason is stranded
    /// somewhere the window cannot render it.
    case recoveredFailure(FailureRecord)
}

/// A8's transition table, and nothing beyond it.
///
/// A pure function of (state, event, clock) so that the table is testable
/// without a tunnel, a window or a network — which is the whole reason the
/// model lives in this package. Both surfaces read the result; **neither owns
/// it** (D93), which is what makes them agree by construction rather than by
/// two implementations trying to stay in step.
public enum ConnectionMachine {
    /// Applies one event.
    ///
    /// A combination the table does not describe returns the state
    /// **unchanged**. The model never invents a transition: a state it cannot
    /// explain is a lie waiting to be rendered, and the caller that saw the
    /// impossible event is the one with the context to log it.
    public static func next(
        _ from: Connection,
        on event: TunnelEvent,
        at now: Date = Date()
    ) -> Connection {
        switch (from, event) {

        // Reality outranks everything, including anything we just asked for.
        case (_, .observed(let state, let profile)):
            return observe(state, profile: profile, from: from, at: now)

        // A reason recovered after the fact. Only where there is nothing to
        // contradict it: anything live outranks a dead reason (D226).
        case (.disconnected, .recoveredFailure(let record)):
            return .failed(record)

        // Starting an attempt. From Disconnected or Failed it is simply an
        // attempt; from Connected or an attempt on *another* profile it is a
        // switch, which is one operation with two narrated halves (D70).
        case (.disconnected, .connect(let profile)),
            (.failed, .connect(let profile)):
            return .connecting(Attempt(profile: profile, startedAt: now))

        case (.connected(let session), .connect(let profile)):
            guard session.profile != profile else { return from }
            return .disconnecting(
                Teardown(profile: session.profile, startedAt: now, switchingTo: profile))

        case (.connecting(let attempt), .connect(let profile)),
            (.reconnecting(let attempt), .connect(let profile)):
            guard attempt.profile != profile else { return from }
            return .disconnecting(
                Teardown(profile: attempt.profile, startedAt: now, switchingTo: profile))

        case (.disconnecting(let teardown), .connect(let profile)):
            // Changed their mind mid-switch. The teardown continues; only its
            // destination changes.
            return .disconnecting(
                Teardown(
                    profile: teardown.profile, startedAt: teardown.startedAt, switchingTo: profile))

        // Progress inside an attempt.
        case (.connecting(var attempt), .entered(let phase)):
            attempt.phase = phase
            attempt.phaseEnteredAt = now
            return .connecting(attempt)

        case (.reconnecting(var attempt), .entered(let phase)):
            attempt.phase = phase
            attempt.phaseEnteredAt = now
            return .reconnecting(attempt)

        case (.connecting(let attempt), .established),
            (.reconnecting(let attempt), .established):
            return .connected(Session(profile: attempt.profile, since: now))

        // Coming down.
        case (.connected(let session), .disconnect):
            return .disconnecting(Teardown(profile: session.profile, startedAt: now))

        case (.connecting(let attempt), .disconnect),
            (.connecting(let attempt), .cancelled),
            (.reconnecting(let attempt), .disconnect),
            (.reconnecting(let attempt), .cancelled):
            return .disconnecting(Teardown(profile: attempt.profile, startedAt: now))

        case (.disconnecting(let teardown), .tornDown):
            // A switch's second half starts here, and only here: the window
            // never showed Disconnected in between, because it never was.
            if let next = teardown.switchingTo {
                return .connecting(Attempt(profile: next, startedAt: now))
            }
            return .disconnected

        case (.disconnected, .disconnect):
            // Nothing to do, and no state that says "more disconnected".
            return .disconnected

        // Note what is **not** here: `(.failed, .disconnect)`.
        //
        // Ending a failed attempt is the *mechanics* of the failure — the
        // provider cancels the tunnel, and the system then tears it down — so
        // treating that as the user disconnecting erased the reason 44 ms
        // after it was recorded (measured, 22:47:29). A8 is explicit: Failed
        // is terminal and leaves only when the user retries or connects
        // something else. It falls through to `default` and stays.

        // Losing a tunnel that was up. Recovery starts immediately and is
        // counted from one (D86).
        case (.connected(let session), .dropped):
            return .reconnecting(Attempt(profile: session.profile, startedAt: now, recovery: 1))

        // An attempt ending badly. Recovery is bounded, and the bound is the
        // only thing standing between this and OpenVPN Connect's
        // "Continuously Retry" (A1).
        case (.connecting(let attempt), .failed(let reason)),
            (.reconnecting(let attempt), .failed(let reason)):
            return endOrRetry(attempt, reason: reason, at: now)

        case (.connecting(let attempt), .timedOut),
            (.reconnecting(let attempt), .timedOut):
            return endOrRetry(attempt, reason: .timedOut, at: now)

        case (.connected(let session), .failed(let reason)):
            return .failed(FailureRecord(profile: session.profile, at: now, reason: reason))

        case (.disconnecting(let teardown), .timedOut):
            // D39: force it and restore anyway. A switch still goes on to its
            // second half — the user asked for a profile, not for a teardown.
            if let next = teardown.switchingTo {
                return .connecting(Attempt(profile: next, startedAt: now))
            }
            return .disconnected

        default:
            return from
        }
    }

    /// What to do when an attempt ends: another go, or Failed.
    private static func endOrRetry(
        _ attempt: Attempt,
        reason: TunnelFailure,
        at now: Date
    ) -> Connection {
        let record = FailureRecord(
            profile: attempt.profile,
            at: now,
            reason: reason,
            phase: attempt.phase?.id,
            elapsed: attempt.elapsed(at: now),
            recoveryAttempts: attempt.recovery)

        // Only a tunnel that had come up earns automatic recovery. An attempt
        // the user just started and that failed at once is theirs to retry —
        // silently trying it five more times would hide the reason they asked
        // for and are waiting to read.
        guard attempt.recovery > 0, Recovery.mayRetry(after: attempt.recovery) else {
            return .failed(record)
        }
        return .reconnecting(
            Attempt(profile: attempt.profile, startedAt: now, recovery: attempt.recovery + 1))
    }

    /// Reconciles the model with what the system actually reports.
    ///
    /// Called on wake and whenever the OS acts on our configuration. **Sleep
    /// is a gap in observation, not a state** (D95): there is no "was asleep"
    /// to return to, only what is true now.
    private static func observe(
        _ state: TunnelState,
        profile: Profile.ID?,
        from: Connection,
        at now: Date
    ) -> Connection {
        // Already agreed, and for the same profile: keep what we have, because
        // it carries clocks and a phase that a bare state cannot.
        if from.state == state, profile == nil || from.profile == profile { return from }

        switch state {
        case .disconnected:
            // **Failed is a disconnected tunnel with a reason**, and the
            // reason is ours: the system has no opinion about it and reports
            // Disconnected either way. Letting an observation clear it would
            // erase the answer the user is looking at, and A8 says Failed is
            // terminal until *they* act (found while wiring M5.2).
            if case .failed = from { return from }
            return .disconnected
        case .connected:
            guard let profile = profile ?? from.profile else { return .disconnected }
            // A tunnel we find already up has no start time we can know. Now
            // is the honest answer: a duration counted from a guess would be a
            // lie, and D73 does not allow one clock to borrow the other's.
            if case .connected(let session) = from, session.profile == profile { return from }
            return .connected(Session(profile: profile, since: now))
        case .connecting, .reconnecting:
            guard let profile = profile ?? from.profile else { return .disconnected }
            let recovery = from.attempt?.recovery ?? (state == .reconnecting ? 1 : 0)
            return state == .reconnecting
                ? .reconnecting(Attempt(profile: profile, startedAt: now, recovery: recovery))
                : .connecting(Attempt(profile: profile, startedAt: now, recovery: recovery))
        case .disconnecting:
            return .disconnecting(Teardown(profile: profile ?? from.profile, startedAt: now))
        case .failed:
            // The system does not report Failed; only we conclude it. If it
            // ever does, we have no reason to attach, and inventing one would
            // be worse than saying we do not know (D85).
            guard let profile = profile ?? from.profile else { return .disconnected }
            if case .failed = from { return from }
            return .failed(FailureRecord(profile: profile, at: now, reason: .unknown))
        }
    }
}

/// How hard, and how long, VPN Plus tries to recover on its own.
///
/// **Bounded, counted and visible** (D86). No value here is infinite (D97):
/// OpenVPN Connect ships "Continuously Retry" as a menu option, which is how
/// hanging forever became a supported feature (A1).
public enum Recovery {
    /// Then Failed, which is terminal and requires the user.
    public static let maxAttempts = 5

    public static func mayRetry(after attempt: Int) -> Bool { attempt < maxAttempts }

    /// How long to wait before recovery attempt `n` — 2, 4, 8, 16, 32 seconds.
    ///
    /// **The first attempt waits too.** A drop usually means the network went
    /// away, and retrying into a network that vanished a millisecond ago
    /// spends an attempt to learn nothing. Backing off is also not politeness:
    /// the owner's most frequent failure is a server that accepts the sign-in
    /// and then withholds the configuration (feature-spec 3.15), and hammering
    /// it makes that worse rather than better.
    public static func backoff(before attempt: Int) -> Duration {
        guard attempt >= 1 else { return .zero }
        return .seconds(1 << min(attempt, maxAttempts))
    }
}
