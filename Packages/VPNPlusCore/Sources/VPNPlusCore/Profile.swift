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

    public init(
        id: UUID = UUID(),
        origin: Origin,
        title: String,
        waivedDirectives: [String] = [],
        acceptedWaivers: [String] = []
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.waivedDirectives = waivedDirectives
        self.acceptedWaivers = acceptedWaivers
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
    /// overrides, and returns what the new text contradicts (D132).
    func replaceConfiguration(
        _ configuration: Data,
        descriptor: ProfileDescriptor,
        for id: Profile.ID
    ) throws -> [OverrideConflict]

    /// Removes the profile and every secret it owns.
    func remove(_ id: Profile.ID) throws
}
