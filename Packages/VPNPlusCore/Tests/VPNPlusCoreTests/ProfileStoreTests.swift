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
import Testing

@testable import VPNPlusCore

/// The storage contract: what is a secret, what survives a reissued profile,
/// and what deletion leaves behind. Tested against doubles, so the Keychain
/// adapter has nothing in it but Keychain calls.
struct ProfileStoreTests {
    final class Secrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: Data] = [:]
        var failNextWrite = false

        func secret(for account: String) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            return held[account]
        }

        func setSecret(_ data: Data, for account: String) throws {
            if failNextWrite { failNextWrite = false; throw ProfileStoreError.configurationMissing }
            lock.lock(); defer { lock.unlock() }
            held[account] = data
        }

        func removeSecret(for account: String) throws {
            lock.lock(); defer { lock.unlock() }
            held[account] = nil
        }

        var accounts: [String] { lock.lock(); defer { lock.unlock() }; return held.keys.sorted() }
    }

    final class Metadata: MetadataStore, @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: Data] = [:]

        func data(for key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return held[key]
        }

        func setData(_ data: Data?, for key: String) {
            lock.lock(); defer { lock.unlock() }
            held[key] = data
        }

        var keys: [String] { lock.lock(); defer { lock.unlock() }; return held.keys.sorted() }
    }

    private func makeStore() -> (StoredProfileStore, Secrets, Metadata) {
        let secrets = Secrets(), metadata = Metadata()
        return (StoredProfileStore(secrets: secrets, metadata: metadata), secrets, metadata)
    }

    private func profile(_ title: String = "Company SG") -> Profile {
        Profile(origin: Profile.Origin(filename: "\(title).ovpn", importedAt: Date()), title: title)
    }

    private func descriptor(
        allowsPasswordSave: Bool = true,
        alternates: [ServerChoice] = [],
        waived: [String] = []
    ) -> ProfileDescriptor {
        ProfileDescriptor(
            displayName: "Company SG",
            server: ServerEndpoint(host: "sg.example.invalid", port: "1194", transport: "udp"),
            credentials: [.usernamePassword(usernameLocked: nil)],
            allowsPasswordSave: allowsPasswordSave, alternateServers: alternates,
            waivedDirectives: waived)
    }

    // MARK: - The split between secret and not

    @Test func theConfigurationIsASecretAndTheMetadataIsNot() throws {
        let (store, secrets, metadata) = makeStore()
        let one = profile()
        let text = Data("client\nremote sg.example.invalid 1194\n<key>private</key>".utf8)
        try store.add(one, configuration: text)

        // The text is only ever in the secret store.
        #expect(secrets.accounts == [StoredProfileStore.account(for: one.id)])
        for key in metadata.keys {
            let stored = String(decoding: metadata.data(for: key) ?? Data(), as: UTF8.self)
            #expect(!stored.contains("private"), "a secret reached \(key)")
            #expect(!stored.contains("remote sg.example.invalid"))
        }
        #expect(try store.configuration(for: one.id) == text)
        #expect(try store.profiles().map(\.title) == ["Company SG"])
    }

    @Test func anUnknownProfileIsNotFound() throws {
        let (store, _, _) = makeStore()
        #expect(throws: ProfileStoreError.noSuchProfile) { try store.configuration(for: UUID()) }
        #expect(throws: ProfileStoreError.noSuchProfile) { try store.setOverrides(Overrides(title: "x"), for: UUID()) }
    }

    /// A secret removed behind our back is reported, not papered over.
    @Test func aMissingConfigurationSaysSoRatherThanReturningNothing() throws {
        let (store, secrets, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try secrets.removeSecret(for: StoredProfileStore.account(for: one.id))
        #expect(throws: ProfileStoreError.configurationMissing) { try store.configuration(for: one.id) }
    }

    /// The secret is written before the index, so a failure cannot leave a
    /// profile listed with nothing behind it.
    @Test func aFailedSecretWriteAddsNoProfile() throws {
        let (store, secrets, _) = makeStore()
        secrets.failNextWrite = true
        #expect(throws: (any Error).self) { try store.add(profile(), configuration: Data("client".utf8)) }
        #expect(try store.profiles().isEmpty)
    }

    // MARK: - Knowing that a password exists without holding it

    /// The app cannot read what the extension holds, so it records *that* a
    /// password exists. Without this an empty password field is ambiguous
    /// between "use the one you have" and "forget it".
    @Test func whetherSignInDetailsAreSavedIsRecordedAndIsNotASecret() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        #expect(try store.profiles().first?.credentialsSaved == false)

        try store.setCredentialsSaved(true, for: one.id)
        #expect(try store.profiles().first?.credentialsSaved == true)

        // A flag, never the password it describes.
        for key in metadata.keys {
            let stored = String(decoding: metadata.data(for: key) ?? Data(), as: UTF8.self)
            #expect(!stored.contains("hunter2"))
        }

        try store.setCredentialsSaved(false, for: one.id)
        #expect(try store.profiles().first?.credentialsSaved == false)
    }

    @Test func recordingSavedDetailsForSomethingThatIsNotThereFails() throws {
        let (store, _, _) = makeStore()
        #expect(throws: ProfileStoreError.noSuchProfile) { try store.setCredentialsSaved(true, for: UUID()) }
    }

    /// Reissuing a profile leaves the saved password alone, which is D188 seen
    /// from the credential side: a new file is new *settings*, not a new
    /// account.
    @Test func replacingTheConfigurationKeepsTheSavedSignInDetails() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try store.setCredentialsSaved(true, for: one.id)
        _ = try store.replaceConfiguration(
            Data("client\nremote other.example.invalid 1194".utf8),
            descriptor: descriptor(), title: "Company SG", for: one.id)
        #expect(try store.profiles().first?.credentialsSaved == true)
    }

    /// A profile stored before this field existed still decodes.
    @Test func aProfileFromAnEarlierVersionHasNoSavedDetails() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        let older = """
            [{"id":"\(one.id.uuidString)","title":"Company SG",\
            "origin":{"filename":"company.ovpn","importedAt":0}}]
            """
        metadata.setData(Data(older.utf8), for: "profiles.index")
        let read = try store.profiles()
        #expect(read.count == 1)
        #expect(read[0].credentialsSaved == false)
        #expect(read[0].configurationHandedOver == false)
    }

    // MARK: - The failure record, which outlives the state (D96)

    /// The state is not stored at all — that is what makes D96 true. What is
    /// stored is the record, and it has to survive a relaunch to be worth
    /// keeping.
    @Test func theLastFailureIsKeptAndCanBeCleared() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        #expect(try store.profiles().first?.lastFailure == nil)

        let record = FailureRecord(
            profile: one.id, at: Date(timeIntervalSince1970: 1_000),
            reason: .credentialsUnavailable, phase: "auth",
            elapsed: .seconds(12), recoveryAttempts: 2)
        try store.setLastFailure(record, for: one.id)
        #expect(try store.profiles().first?.lastFailure == record)

        try store.setLastFailure(nil, for: one.id)
        #expect(try store.profiles().first?.lastFailure == nil)
    }

    @Test func recordingAFailureForSomethingThatIsNotThereFails() throws {
        let (store, _, _) = makeStore()
        let record = FailureRecord(profile: UUID(), at: Date(), reason: .unknown)
        #expect(throws: ProfileStoreError.noSuchProfile) {
            try store.setLastFailure(record, for: UUID())
        }
    }

    // MARK: - The order is the user's (D119)

    @Test func theOrderIsWhateverTheUserSaidItWas() throws {
        let (store, _, _) = makeStore()
        let one = profile("Singapore")
        let two = profile("Hong Kong")
        let three = profile("Home")
        for each in [one, two, three] { try store.add(each, configuration: Data("client".utf8)) }
        #expect(try store.profiles().map(\.title) == ["Singapore", "Hong Kong", "Home"])

        try store.setOrder([three.id, one.id, two.id])
        #expect(try store.profiles().map(\.title) == ["Home", "Singapore", "Hong Kong"])
    }

    /// A partial order is not a licence to drop profiles: anything the caller
    /// did not mention keeps its place relative to the rest.
    @Test func anIncompleteOrderLosesNothing() throws {
        let (store, _, _) = makeStore()
        let one = profile("Singapore")
        let two = profile("Hong Kong")
        let three = profile("Home")
        for each in [one, two, three] { try store.add(each, configuration: Data("client".utf8)) }

        try store.setOrder([three.id])
        #expect(try store.profiles().map(\.title) == ["Home", "Singapore", "Hong Kong"])

        // An id the store has never heard of changes nothing either.
        try store.setOrder([UUID(), two.id])
        #expect(try store.profiles().count == 3)
        #expect(try store.profiles().first?.title == "Hong Kong")
    }

    @Test func aSuccessfulConnectionIsRemembered() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        #expect(try store.profiles().first?.lastConnected == nil)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.setLastConnected(when, for: one.id)
        #expect(try store.profiles().first?.lastConnected == when)
    }

    // MARK: - Overrides

    @Test func overridesRoundTripAndAnEmptyRecordIsRemoved() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))

        #expect(try store.overrides(for: one.id) == Overrides())
        try store.setOverrides(Overrides(title: "Work", username: "alex"), for: one.id)
        #expect(try store.overrides(for: one.id).title == "Work")

        let before = metadata.keys.count
        try store.setOverrides(Overrides(), for: one.id)
        #expect(metadata.keys.count == before - 1, "an empty record should be removed, not stored")
        #expect(try store.overrides(for: one.id) == Overrides())
    }

    @Test func anUnreadableOverridesRecordDoesNotStrandTheProfile() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try store.setOverrides(Overrides(title: "Work"), for: one.id)
        let key = metadata.keys.first { $0.contains("overrides") }!
        metadata.setData(Data("not json".utf8), for: key)

        // The profile still works; the adjustments are lost, which is the
        // lesser harm and must not be an error.
        #expect(try store.overrides(for: one.id) == Overrides())
        #expect(try store.configuration(for: one.id) == Data("client".utf8))
    }

    // MARK: - Replacing a reissued profile (2.6, D132)

    @Test func replacingKeepsTheIdentityAndTheOverrides() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("old".utf8))
        try store.setOverrides(Overrides(title: "Work", username: "alex", reconnectAutomatically: false), for: one.id)

        let conflicts = try store.replaceConfiguration(Data("new".utf8), descriptor: descriptor(), title: "Company SG", for: one.id)
        #expect(conflicts.isEmpty)
        #expect(try store.configuration(for: one.id) == Data("new".utf8))
        #expect(try store.profiles().count == 1)
        #expect(try store.profiles()[0].id == one.id, "replacing must not create a second profile")
        let kept = try store.overrides(for: one.id)
        #expect(kept.title == "Work")
        #expect(kept.username == "alex")
        #expect(kept.reconnectAutomatically == false)
        #expect(try store.profiles()[0].origin.replacedAt != nil)
        #expect(try store.profiles()[0].origin.importedAt == one.origin.importedAt)
    }

    @Test func replacingReportsWhatTheNewTextContradicts() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("old".utf8))
        try store.setOverrides(Overrides(selectedServer: "gone.example.invalid", savePassword: true), for: one.id)

        let conflicts = try store.replaceConfiguration(
            Data("new".utf8),
            descriptor: descriptor(allowsPasswordSave: false,
                                   alternates: [ServerChoice(host: "sg.example.invalid", label: "Singapore")]),
            title: "Company SG", for: one.id)
        #expect(conflicts.count == 2, "\(conflicts)")
        #expect(conflicts.contains(OverrideConflict(kind: .serverNoLongerOffered("gone.example.invalid"))))
        #expect(conflicts.contains(OverrideConflict(kind: .passwordSavingNowForbidden)))
        // Reported, and still kept: resolving them is the user's to do.
        #expect(try store.overrides(for: one.id).savePassword == true)
    }

    @Test func replacingUpdatesTheWaivedDirectives() throws {
        let (store, _, _) = makeStore()
        var one = profile()
        one.waivedDirectives = ["persist-tun"]
        try store.add(one, configuration: Data("old".utf8))
        _ = try store.replaceConfiguration(
            Data("new".utf8), descriptor: descriptor(waived: ["resolv-retry", "persist-key"]),
            title: "Company SG", for: one.id)
        #expect(try store.profiles()[0].waivedDirectives == ["resolv-retry", "persist-key"])
    }

    @Test func replacingSomethingThatIsNotThereFails() throws {
        let (store, _, _) = makeStore()
        #expect(throws: ProfileStoreError.noSuchProfile) {
            _ = try store.replaceConfiguration(Data("new".utf8), descriptor: descriptor(), title: "x", for: UUID())
        }
    }

    // MARK: - Deletion takes the secrets with it

    @Test func removingTakesTheConfigurationAndTheOverrides() throws {
        let (store, secrets, metadata) = makeStore()
        let one = profile(), two = profile("Company HK")
        try store.add(one, configuration: Data("one".utf8))
        try store.add(two, configuration: Data("two".utf8))
        try store.setOverrides(Overrides(title: "Work"), for: one.id)

        try store.remove(one.id)
        #expect(try store.profiles().map(\.title) == ["Company HK"])
        #expect(secrets.accounts == [StoredProfileStore.account(for: two.id)], "the private key must not survive")
        #expect(!metadata.keys.contains { $0.contains(one.id.uuidString) })
        #expect(try store.configuration(for: two.id) == Data("two".utf8))
    }

    @Test func addingTheSameProfileTwiceDoesNotDuplicateIt() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("first".utf8))
        try store.add(one, configuration: Data("second".utf8))
        #expect(try store.profiles().count == 1)
        #expect(try store.configuration(for: one.id) == Data("second".utf8))
    }

    @Test func anUnreadableIndexIsReportedRatherThanTreatedAsEmpty() {
        let (store, _, metadata) = makeStore()
        metadata.setData(Data("not json".utf8), for: "profiles.index")
        #expect(throws: ProfileStoreError.indexUnreadable) { try store.profiles() }
    }
}
