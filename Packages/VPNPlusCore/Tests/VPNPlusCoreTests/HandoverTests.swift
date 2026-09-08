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

/// Moving a configuration from the app to the extension. The property under
/// test is the one that matters: **at no point are there two copies of a
/// private key**, and at no point is there none.
struct HandoverTests {
    private func makeStore() -> (StoredProfileStore, ProfileStoreTests.Secrets, ProfileStoreTests.Metadata) {
        let secrets = ProfileStoreTests.Secrets(), metadata = ProfileStoreTests.Metadata()
        return (StoredProfileStore(secrets: secrets, metadata: metadata), secrets, metadata)
    }

    private func profile() -> Profile {
        Profile(origin: Profile.Origin(filename: "Company SG.ovpn", importedAt: Date()), title: "Company SG")
    }

    private let descriptor = ProfileDescriptor(
        displayName: "Company SG",
        server: ServerEndpoint(host: "sg.example.invalid", port: "1194", transport: "udp"),
        credentials: [.usernamePassword(usernameLocked: nil)],
        waivedDirectives: ["persist-tun"])

    @Test func aNewProfileIsNotYetHandedOver() throws {
        let (store, secrets, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        #expect(try !store.profiles()[0].configurationHandedOver)
        #expect(secrets.accounts.count == 1, "the app holds it until the extension confirms")
    }

    @Test func finishingTheHandoverDeletesTheAppsCopy() throws {
        let (store, secrets, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try store.finishHandover(for: one.id)

        #expect(try store.profiles()[0].configurationHandedOver)
        #expect(secrets.accounts.isEmpty, "two copies of a private key is worse than none")
        #expect(throws: ProfileStoreError.configurationMissing) { try store.configuration(for: one.id) }
    }

    /// The app must still work after its copy is gone, which is what the stored
    /// descriptor is for.
    @Test func theDescriptorSurvivesTheHandover() throws {
        let (store, _, _) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try store.setDescriptor(descriptor, for: one.id)
        try store.finishHandover(for: one.id)

        let stored = try store.profiles()[0]
        #expect(stored.descriptor == descriptor)
        #expect(stored.descriptor?.server.host == "sg.example.invalid")
        // And composing still works with no configuration in reach.
        let settings = ProfileSettings.compose(
            stored.descriptor!, with: Overrides(username: "alex"),
            filename: stored.origin.filename)
        #expect(settings.effectiveServer.host == "sg.example.invalid")
    }

    /// Nothing secret may reach preferences, and the descriptor is now stored
    /// there — so the claim is re-tested with a descriptor present.
    @Test func theStoredDescriptorCarriesNoSecret() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        let text = "client\n<key>PRIVATE-KEY-MATERIAL</key>\n<ca>CERT</ca>"
        try store.add(one, configuration: Data(text.utf8))
        try store.setDescriptor(descriptor, for: one.id)
        try store.finishHandover(for: one.id)

        for key in metadata.keys {
            let stored = String(decoding: metadata.data(for: key) ?? Data(), as: UTF8.self)
            #expect(!stored.contains("PRIVATE-KEY-MATERIAL"), "a key reached \(key)")
            #expect(!stored.contains("CERT"), "a certificate reached \(key)")
        }
    }

    @Test func handingOverSomethingThatIsNotThereFails() {
        let (store, _, _) = makeStore()
        #expect(throws: ProfileStoreError.noSuchProfile) { try store.finishHandover(for: UUID()) }
        #expect(throws: ProfileStoreError.noSuchProfile) { try store.setDescriptor(descriptor, for: UUID()) }
    }

    /// A profile stored by an older version has neither field, and must still
    /// decode — a user who updates keeps their profiles.
    @Test func aProfileFromAnEarlierVersionStillDecodes() throws {
        let older = """
            [{"id":"\(UUID().uuidString)","title":"Company SG",
              "origin":{"filename":"Company SG.ovpn","importedAt":1000.0},
              "waivedDirectives":["persist-tun"],"acceptedWaivers":[]}]
            """
        let decoded = try JSONDecoder().decode([Profile].self, from: Data(older.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].title == "Company SG")
        #expect(decoded[0].descriptor == nil)
        #expect(!decoded[0].configurationHandedOver, "an old profile is not handed over")
        #expect(decoded[0].waivedDirectives == ["persist-tun"])
    }

    @Test func removingAHandedOverProfileStillClearsItsOverrides() throws {
        let (store, _, metadata) = makeStore()
        let one = profile()
        try store.add(one, configuration: Data("client".utf8))
        try store.setOverrides(Overrides(title: "Work"), for: one.id)
        try store.finishHandover(for: one.id)
        try store.remove(one.id)
        #expect(try store.profiles().isEmpty)
        #expect(!metadata.keys.contains { $0.contains(one.id.uuidString) })
    }
}
