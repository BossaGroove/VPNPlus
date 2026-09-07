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

/// Somewhere secrets are kept. One method less than it looks: nothing here
/// hands back a list, because a caller that can enumerate secrets is a caller
/// that can be tricked into reading one it did not mean to.
///
/// The implementation is the Keychain (D190). This protocol exists so the
/// storage *logic* — indexes, overrides, replacement, deletion — is tested
/// without one, leaving the Keychain adapter thin enough to read in one sitting.
public protocol SecretStore: Sendable {
    func secret(for account: String) throws -> Data?
    func setSecret(_ data: Data, for account: String) throws
    func removeSecret(for account: String) throws
}

/// Somewhere non-secret metadata is kept. Preferences, in the app.
public protocol MetadataStore: Sendable {
    func data(for key: String) -> Data?
    func setData(_ data: Data?, for key: String)
}

public enum ProfileStoreError: Error, Equatable {
    case noSuchProfile
    /// The index decoded, but the configuration it points at is gone. Worth its
    /// own case: it means something removed a secret behind our back, and the
    /// honest response is to say so rather than to show an empty profile.
    case configurationMissing
    case indexUnreadable
}

/// `ProfileStore` over a secret store and a metadata store.
///
/// The split is the point (D190, D191): the configuration text is a secret
/// because it routinely contains a private key, while a title and an import
/// date are not, and only the second kind may appear anywhere a local
/// administrator can read it.
public struct StoredProfileStore: ProfileStore {
    private let secrets: SecretStore
    private let metadata: MetadataStore

    private static let indexKey = "profiles.index"
    private static func overridesKey(_ id: Profile.ID) -> String { "profiles.overrides.\(id.uuidString)" }

    /// The Keychain account a profile's configuration is stored under. Also the
    /// only thing that may be handed to the system VPN configuration, which is
    /// readable with admin rights (D191).
    public static func account(for id: Profile.ID) -> String { "profile.\(id.uuidString)" }

    public init(secrets: SecretStore, metadata: MetadataStore) {
        self.secrets = secrets
        self.metadata = metadata
    }

    // MARK: - Reading

    public func profiles() throws -> [Profile] {
        guard let data = metadata.data(for: Self.indexKey) else { return [] }
        do {
            return try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            throw ProfileStoreError.indexUnreadable
        }
    }

    public func configuration(for id: Profile.ID) throws -> Data {
        guard try profiles().contains(where: { $0.id == id }) else {
            throw ProfileStoreError.noSuchProfile
        }
        guard let data = try secrets.secret(for: Self.account(for: id)) else {
            throw ProfileStoreError.configurationMissing
        }
        return data
    }

    public func overrides(for id: Profile.ID) throws -> Overrides {
        guard let data = metadata.data(for: Self.overridesKey(id)) else { return Overrides() }
        // An unreadable overrides record is not worth failing a connection for:
        // the profile still works, the user has lost their adjustments, and
        // pretending otherwise would strand them.
        return (try? JSONDecoder().decode(Overrides.self, from: data)) ?? Overrides()
    }

    // MARK: - Writing

    public func setOverrides(_ overrides: Overrides, for id: Profile.ID) throws {
        guard try profiles().contains(where: { $0.id == id }) else {
            throw ProfileStoreError.noSuchProfile
        }
        // An empty record is removed rather than stored, so "the user has not
        // spoken" and "the user reverted everything" are the same state.
        metadata.setData(overrides.isEmpty ? nil : try JSONEncoder().encode(overrides),
                         for: Self.overridesKey(id))
    }

    public func add(_ profile: Profile, configuration: Data) throws {
        // The secret goes first: a profile in the index whose configuration is
        // missing is a worse state than a secret nothing points at.
        try secrets.setSecret(configuration, for: Self.account(for: profile.id))
        var index = try profiles()
        index.removeAll { $0.id == profile.id }
        index.append(profile)
        try write(index)
    }

    public func replaceConfiguration(
        _ configuration: Data,
        descriptor: ProfileDescriptor,
        title: String,
        for id: Profile.ID
    ) throws -> [OverrideConflict] {
        var index = try profiles()
        guard let position = index.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.noSuchProfile
        }
        try secrets.setSecret(configuration, for: Self.account(for: id))

        // The overrides record is deliberately untouched (D132, 2.6): what the
        // new text contradicts is reported, not resolved on the user's behalf.
        var profile = index[position]
        profile.origin.replacedAt = Date()
        profile.waivedDirectives = descriptor.waivedDirectives
        // The default name follows the new text; a name the user gave it lives
        // in the overrides record and is untouched here.
        if !title.isEmpty { profile.title = title }
        index[position] = profile
        try write(index)

        return try overrides(for: id).conflicts(with: descriptor)
    }

    public func setDescriptor(_ descriptor: ProfileDescriptor, for id: Profile.ID) throws {
        var index = try profiles()
        guard let position = index.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.noSuchProfile
        }
        index[position].descriptor = descriptor
        try write(index)
    }

    public func finishHandover(for id: Profile.ID) throws {
        var index = try profiles()
        guard let position = index.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.noSuchProfile
        }
        // The flag is written before the delete: a profile marked handed-over
        // whose local copy survives is a leak we would find, while a deleted
        // copy with the flag unset would strand the profile.
        index[position].configurationHandedOver = true
        try write(index)
        try secrets.removeSecret(for: Self.account(for: id))
    }

    public func remove(_ id: Profile.ID) throws {
        // Secrets first, and unconditionally: a failure here must not leave a
        // private key behind with nothing referring to it.
        try secrets.removeSecret(for: Self.account(for: id))
        metadata.setData(nil, for: Self.overridesKey(id))
        var index = try profiles()
        index.removeAll { $0.id == id }
        try write(index)
    }

    private func write(_ index: [Profile]) throws {
        metadata.setData(try JSONEncoder().encode(index), for: Self.indexKey)
    }
}
