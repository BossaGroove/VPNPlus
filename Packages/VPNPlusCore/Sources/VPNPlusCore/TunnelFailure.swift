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

/// Why a tunnel could not run, in the one form that survives every trip it
/// has to make: across the boundary to the app, and into a stored record that
/// outlives the process (D96).
///
/// It lives here rather than beside the privileged interface because the
/// connection model needs the same vocabulary, and two enumerations of one
/// thing is exactly the disagreement D93 exists to prevent.
///
/// A **code** crosses; the *words* stay in the app. The extension carries no
/// localized strings, and the copy is A10's to write (D221).
///
/// A small closed set on purpose. The full A9→A10 mapping is M6's, and it will
/// extend this; what is here is what M4 and M5 can actually distinguish.
public enum TunnelFailure: Int, Sendable, Codable, CaseIterable {
    /// The extension holds no configuration for this profile, and none was
    /// handed to it.
    case configurationMissing = 1
    /// The profile needs a password, nothing had one to give, and there was
    /// nobody to ask.
    case credentialsUnavailable = 2
    /// The server refused the sign-in details we had.
    case authenticationFailed = 3
    /// A phase, or the whole attempt, ran out of time (feature-spec 3.5).
    case timedOut = 4
    /// Ended for a reason we have not mapped yet. Never shown as this: the app
    /// says what it does know — the phase, the elapsed time — and never
    /// invents a cause (D85).
    case unknown = 99

    public static let domain = "com.bossagroove.VPNPlus.tunnel"

    /// The key the time of the failure travels under.
    ///
    /// Whether NetworkExtension hands the app our `userInfo` verbatim is not
    /// documented. Measured at M4.6: **it does**, description and this key
    /// both. An absent time is still read as "unknown", never as "old".
    public static let timeKey = "com.bossagroove.VPNPlus.failedAt"

    /// `detail` is for the log and for diagnostics. It is written in the
    /// extension, which is not localized, so it is never what a user reads.
    public func error(_ detail: String, at time: Date = Date()) -> NSError {
        NSError(
            domain: Self.domain, code: rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: detail,
                Self.timeKey: ISO8601DateFormatter().string(from: time),
            ])
    }

    /// Reads one back. Anything from elsewhere is nil rather than guessed at.
    public init?(_ error: any Error) {
        let error = error as NSError
        guard error.domain == Self.domain, let known = Self(rawValue: error.code) else {
            return nil
        }
        self = known
    }

    /// When the failure happened, if it says. The app needs this because it
    /// may be reading a failure from before it was running, and a week-old
    /// reason presented as news is worse than no reason at all.
    public static func time(of error: any Error) -> Date? {
        guard let text = (error as NSError).userInfo[timeKey] as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// What a failure was, kept after the state has moved on.
///
/// **Failed does not survive a restart; this does** (D96). Relaunching into
/// Failed would claim a failure that did not just happen, which commitment 3
/// forbids — but discarding it is also wrong, because the user may have quit
/// *because* it failed and come back to look. So: a record, not a state.
public struct FailureRecord: Sendable, Equatable, Codable {
    public let profile: Profile.ID
    public let at: Date
    public let reason: TunnelFailure
    /// The phase it died in, by id rather than by value: a record outlives the
    /// adapter that named the phase, and may be read by a build that no longer
    /// has it.
    public let phase: String?
    /// How long the attempt had been running. Real, and more than either
    /// incumbent offers, even when the cause is unknown (D85).
    public let elapsed: Duration?
    /// How many automatic recovery attempts had been made. Zero for a failure
    /// the user's own attempt ran into.
    public let recoveryAttempts: Int

    public init(
        profile: Profile.ID,
        at: Date,
        reason: TunnelFailure,
        phase: String? = nil,
        elapsed: Duration? = nil,
        recoveryAttempts: Int = 0
    ) {
        self.profile = profile
        self.at = at
        self.reason = reason
        self.phase = phase
        self.elapsed = elapsed
        self.recoveryAttempts = recoveryAttempts
    }
}
