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
    /// nobody to ask (A10 M21).
    case credentialsUnavailable = 2
    /// The server refused the sign-in details we had (M1).
    case authenticationFailed = 3
    /// A phase, or the whole attempt, ran out of time and nothing more
    /// specific names it — signing in that never got a verdict, or the
    /// whole-attempt deadline (feature-spec 3.5; A9 `stall.auth`,
    /// `stall.attempt`).
    case timedOut = 4

    // A10's vocabulary, one code per message (D103), added at M6.1. The raw
    // values are the wire format across the NetworkExtension boundary and
    // the stored format in a profile's `lastFailure`; they never change.

    /// Sign-in was accepted and the connection settings never came — the
    /// owner's own failure (M2, `stall.config`).
    case settingsNeverSent = 5
    /// The server did not answer (M3, `stall.contact`, `CONNECTION_TIMEOUT`,
    /// a fatal `TRANSPORT_ERROR`).
    case serverUnreachable = 6
    /// The server's address could not be looked up (M4, `stall.resolve`).
    case serverNotFound = 7
    /// The server's certificate was refused (M5).
    case certificateRejected = 8
    /// The server's certificate is out of date (M6).
    case certificateExpired = 9
    /// A certificate failure while this Mac's clock is implausible (M7). The
    /// provider does not conclude this; M6.3's local rule does.
    case clockWrong = 10
    /// No TLS version or algorithm both sides accept (M8).
    case noSecureConnection = 11
    /// The server told us to stop, possibly saying why (M9). The words travel
    /// in `FailureRecord.serverText`, quoted and attributed (D104).
    case serverEnded = 12
    /// The tunnel connected and the network settings could not be applied on
    /// this Mac (M10, `stall.setup`, `TUN_*`).
    case setupFailed = 13
    /// This Mac has no network at all (M11).
    case noNetwork = 14
    /// Recovery ran out of attempts (M14). The last attempt's own reason is
    /// in `FailureRecord.underlying`.
    case recoveryGaveUp = 15
    /// The Keychain refused, or the item is gone (M15).
    case keychainDenied = 16
    /// The server closed an idle session (M17).
    case idleTimeout = 17
    /// The certificate or key this profile needs could not be used (M18).
    case certificateUnusable = 18
    /// The profile asks for something the engine does not do (M19).
    case unsupportedRequirement = 19
    /// Another tunnel owned the default route when the attempt started
    /// (D204). Its name is in `FailureRecord.foreignTunnel`.
    case anotherTunnelActive = 20
    /// The system reported the tunnel down before our provider ever spoke: the
    /// extension did not start (D310). Seen right after an in-place
    /// replacement, and with the extension switched off in System Settings.
    case componentDidNotStart = 21

    /// Ended for a reason we have not mapped. Never shown as this: the app
    /// says what it does know — the phase, the elapsed time — and never
    /// invents a cause (D85, M20).
    case unknown = 99

    /// Failures a wrong clock can cause. Every one of them looks like the
    /// server's fault and can be the Mac's (D101).
    public var isAboutACertificate: Bool {
        switch self {
        case .certificateRejected, .certificateExpired: true
        default: false
        }
    }

    /// Failures that are about reaching the server at all, which two local
    /// facts can explain better than the engine can: no network, or another
    /// tunnel holding the default route.
    public var isAboutReachingTheServer: Bool {
        switch self {
        case .serverUnreachable, .serverNotFound, .timedOut: true
        default: false
        }
    }

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

    // Added at M6.1. All optional, so a record written before they existed
    // decodes with them absent rather than failing to decode at all.

    /// How long the phase that stalled was waited for (feature-spec 4.10).
    public let waited: Duration?
    /// How many requests were sent during that wait — the engine's 3 s
    /// `PUSH_REQUEST` cadence made countable (4.10).
    public let attempts: Int?
    /// What the server said, when an event carried its words. Shown only
    /// quoted and attributed (D104); never in the app's own voice.
    public let serverText: String?
    /// The engine's own identifier and text, for the log and the export.
    /// Never on a surface (D105, D138).
    public let detail: String?
    /// For `recoveryGaveUp`: what the last attempt actually died of.
    public let underlying: TunnelFailure?
    /// For `anotherTunnelActive`: the tunnel that owned the default route.
    public let foreignTunnel: String?

    public init(
        profile: Profile.ID,
        at: Date,
        reason: TunnelFailure,
        phase: String? = nil,
        elapsed: Duration? = nil,
        recoveryAttempts: Int = 0,
        waited: Duration? = nil,
        attempts: Int? = nil,
        serverText: String? = nil,
        detail: String? = nil,
        underlying: TunnelFailure? = nil,
        foreignTunnel: String? = nil
    ) {
        self.profile = profile
        self.at = at
        self.reason = reason
        self.phase = phase
        self.elapsed = elapsed
        self.recoveryAttempts = recoveryAttempts
        self.waited = waited
        self.attempts = attempts
        self.serverText = serverText
        self.detail = detail
        self.underlying = underlying
        self.foreignTunnel = foreignTunnel
    }

    /// How much this record knows. A failure reaches the app by two channels
    /// — the provider's report, and the error NetworkExtension keeps after
    /// the provider is gone — and whichever lands first must not erase the
    /// one that knows more (M6.1, fact 1).
    public var information: Int {
        var score = 0
        if reason != .unknown { score += 2 }
        if phase != nil { score += 1 }
        if elapsed != nil { score += 1 }
        if waited != nil { score += 1 }
        if attempts != nil { score += 1 }
        if serverText != nil { score += 1 }
        if detail != nil { score += 1 }
        if underlying != nil { score += 1 }
        if foreignTunnel != nil { score += 1 }
        return score
    }

    /// True when this record says more than `other` about what is, as far as
    /// the two can tell, the same failure: same profile, within a minute.
    public func isFuller(than other: FailureRecord) -> Bool {
        guard profile == other.profile, abs(at.timeIntervalSince(other.at)) < 60 else { return false }
        return information > other.information
    }

    /// The whole record, as the error the provider cancels the tunnel with.
    ///
    /// `fetchLastDisconnectError` is the only channel that outlives the
    /// provider, and until M6.1 it carried the code and the time alone — so a
    /// timeout that the provider knew was *contacting the server* reached the
    /// window as "didn't finish in time". The record rides in `userInfo`
    /// whole; the code and time stay where the older readers look for them.
    public func asError() -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: detail ?? reason.rawValueDescription,
            TunnelFailure.timeKey: ISO8601DateFormatter().string(from: at),
        ]
        if let encoded = try? JSONEncoder().encode(self) {
            userInfo[Self.recordKey] = String(decoding: encoded, as: UTF8.self)
        }
        return NSError(domain: TunnelFailure.domain, code: reason.rawValue, userInfo: userInfo)
    }

    /// The key the whole record travels under in an error's `userInfo`.
    public static let recordKey = "com.bossagroove.VPNPlus.failureRecord"

    /// The record back out of an error, when one is in it. Nil for an error
    /// from elsewhere and for one written before M6.1, which the caller reads
    /// with `TunnelFailure.init(_:)` and `time(of:)` as before.
    public init?(error: any Error) {
        let error = error as NSError
        guard error.domain == TunnelFailure.domain,
            let text = error.userInfo[Self.recordKey] as? String,
            let record = try? JSONDecoder().decode(FailureRecord.self, from: Data(text.utf8))
        else { return nil }
        self = record
    }
}

extension TunnelFailure {
    /// A stand-in description for the log when a record carries no detail.
    var rawValueDescription: String { "failure \(rawValue)" }
}

/// What the provider knows when an attempt ends, before the model has said
/// what state that puts it in. The model turns it into a `FailureRecord`
/// together with what only the attempt knows — its phase, its elapsed time,
/// its recovery count (M6.1).
public struct FailureDetail: Sendable, Equatable {
    public var reason: TunnelFailure
    public var waited: Duration?
    public var attempts: Int?
    public var serverText: String?
    public var detail: String?
    public var foreignTunnel: String?

    public init(
        _ reason: TunnelFailure,
        waited: Duration? = nil,
        attempts: Int? = nil,
        serverText: String? = nil,
        detail: String? = nil,
        foreignTunnel: String? = nil
    ) {
        self.reason = reason
        self.waited = waited
        self.attempts = attempts
        self.serverText = serverText
        self.detail = detail
        self.foreignTunnel = foreignTunnel
    }
}
