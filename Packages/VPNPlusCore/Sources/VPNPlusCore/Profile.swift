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

/// One configuration the user has imported. The configuration **text is not
/// here**: it is a secret, it lives in the Keychain, and the store hands it
/// over on request (D190). What is here is what a list can be drawn from
/// without unlocking anything.
public struct Profile: Sendable, Equatable, Identifiable, Codable {
    /// Where this profile came from, so a replacement can say what changed.
    public struct Origin: Sendable, Equatable, Codable {
        /// The file's name as imported, which is also the default title.
        public let filename: String
        public let importedAt: Date
        /// When the text was last replaced by a reissued file (D132).
        public var replacedAt: Date?

        public init(filename: String, importedAt: Date, replacedAt: Date? = nil) {
            self.filename = filename
            self.importedAt = importedAt
            self.replacedAt = replacedAt
        }
    }

    public let id: UUID
    public var origin: Origin
    /// The title shown in lists: the user's, else the configuration's, else
    /// the filename. Overrides are applied by `ProfileSettings`; this is the
    /// cheap answer a list can use without composing anything.
    public var title: String
    /// Directives the engine sets aside for this profile, disclosed as a count
    /// (D187). Stored so the list can show it without re-parsing.
    public var waivedDirectives: [String]
    /// Directives the user chose to set aside, stored with the profile so the
    /// same decision is applied every time it is parsed (D187).
    public var acceptedWaivers: [String]
    /// What the configuration says about itself, kept so the app never needs
    /// the configuration text again once the extension owns it. Nothing
    /// secret is in here.
    public var descriptor: ProfileDescriptor?
    /// True once the extension holds this profile's configuration. Until then
    /// the app still has it and hands it over on the next connection.
    public var configurationHandedOver: Bool
    /// True when the extension is holding sign-in details for this profile.
    ///
    /// Not a secret and not a copy of one: it says *that* a password exists,
    /// which any local administrator can already see from the keychain item's
    /// metadata (D216). The app needs it because it cannot read the secret
    /// itself — and without it an empty password field is ambiguous between
    /// "use the one you have" and "forget the one you have", which is the
    /// difference between connecting and losing a saved password.
    public var credentialsSaved: Bool
    /// When this profile last connected successfully.
    ///
    /// A card says "2 hours ago" or "Never" from it, and D46's *"what changed
    /// since it last worked"* needs it too — which is why removing a profile
    /// has to say it is removing this as well as the profile itself (D82): two
    /// of the three things a removal deletes are invisible.
    public var lastConnected: Date?
    /// The last attempt that ended badly, kept after the state has moved on.
    ///
    /// **Failed does not survive a restart; this does** (D96). On launch the
    /// window is Idle and this is history — timestamped, and one click from
    /// the detail — because relaunching into Failed would claim a failure that
    /// did not just happen, while discarding it would lose the reason the user
    /// may have come back to read.
    public var lastFailure: FailureRecord?

    public init(
        id: UUID = UUID(),
        origin: Origin,
        title: String,
        waivedDirectives: [String] = [],
        acceptedWaivers: [String] = [],
        descriptor: ProfileDescriptor? = nil,
        configurationHandedOver: Bool = false,
        credentialsSaved: Bool = false,
        lastConnected: Date? = nil,
        lastFailure: FailureRecord? = nil
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.waivedDirectives = waivedDirectives
        self.acceptedWaivers = acceptedWaivers
        self.descriptor = descriptor
        self.configurationHandedOver = configurationHandedOver
        self.credentialsSaved = credentialsSaved
        self.lastConnected = lastConnected
        self.lastFailure = lastFailure
    }

    /// Decoding a profile stored before these fields existed must not fail: a
    /// user who updates VPN Plus keeps their profiles.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        origin = try values.decode(Origin.self, forKey: .origin)
        title = try values.decode(String.self, forKey: .title)
        waivedDirectives = try values.decodeIfPresent([String].self, forKey: .waivedDirectives) ?? []
        acceptedWaivers = try values.decodeIfPresent([String].self, forKey: .acceptedWaivers) ?? []
        descriptor = try values.decodeIfPresent(ProfileDescriptor.self, forKey: .descriptor)
        configurationHandedOver = try values.decodeIfPresent(Bool.self, forKey: .configurationHandedOver) ?? false
        credentialsSaved = try values.decodeIfPresent(Bool.self, forKey: .credentialsSaved) ?? false
        lastConnected = try values.decodeIfPresent(Date.self, forKey: .lastConnected)
        lastFailure = try values.decodeIfPresent(FailureRecord.self, forKey: .lastFailure)
    }
}

/// Where profiles live. The core states the contract; the app implements it
/// against the Keychain and preferences, and the tests against memory.
///
/// Two rules the contract carries rather than leaves to callers: the
/// configuration text is stored **verbatim** (D188), and replacing it
/// **preserves the overrides** and reports what they now contradict (D132).
public protocol ProfileStore: Sendable {
    func profiles() throws -> [Profile]

    /// The verbatim configuration text. A secret: never logged, never copied
    /// into a preference (D190, D191).
    func configuration(for id: Profile.ID) throws -> Data

    func overrides(for id: Profile.ID) throws -> Overrides
    func setOverrides(_ overrides: Overrides, for id: Profile.ID) throws

    func add(_ profile: Profile, configuration: Data) throws

    /// Replaces the text of an existing profile, keeping its identity and its
    /// overrides, and returns what the new text contradicts (D132). `title` is
    /// the new default name; a title the user chose still wins, because that
    /// lives in the overrides record.
    func replaceConfiguration(
        _ configuration: Data,
        descriptor: ProfileDescriptor,
        title: String,
        for id: Profile.ID
    ) throws -> [OverrideConflict]

    /// Records what the configuration says about itself, so the app never has
    /// to read the configuration again.
    func setDescriptor(_ descriptor: ProfileDescriptor, for id: Profile.ID) throws

    /// Records whether the extension is holding sign-in details for this
    /// profile. The app cannot read them, so it has to remember that they
    /// exist.
    func setCredentialsSaved(_ saved: Bool, for id: Profile.ID) throws

    /// Keeps, or clears, the record of the last failed attempt (D96).
    func setLastFailure(_ failure: FailureRecord?, for id: Profile.ID) throws

    /// Records a successful connection's time.
    func setLastConnected(_ date: Date, for id: Profile.ID) throws

    /// Stores the order the user put their profiles in.
    ///
    /// **Nothing else may change it** (D119). The grid's value is that the
    /// profile you want is where it was last time; an order that rearranges
    /// itself destroys the muscle memory that makes a one-click switch feel
    /// like one click, and moves the target between the glance and the click.
    /// Ids the store does not know are ignored, and ids missing from the list
    /// keep their relative order at the end.
    func setOrder(_ order: [Profile.ID]) throws

    /// Marks the configuration as handed over to the extension **and deletes
    /// the app's own copy**. Two copies of a private key is worse than none,
    /// so this is one operation rather than two (D190).
    func finishHandover(for id: Profile.ID) throws

    /// Removes the profile and every secret it owns.
    func remove(_ id: Profile.ID) throws
}
