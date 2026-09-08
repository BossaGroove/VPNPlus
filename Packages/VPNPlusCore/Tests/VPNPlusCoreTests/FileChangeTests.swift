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

/// What a reissued file changed, and which of the user's overrides that
/// turns into a question (the ReplaceFile artboard, D132).
struct FileChangeTests {
    private let old = ProfileDescriptor(
        displayName: "Company SG",
        server: ServerEndpoint(host: "192.0.2.10", port: "1194", transport: "udp"),
        credentials: [.usernamePassword(usernameLocked: nil)],
        caPresent: true)

    private func reissued(
        host: String = "192.0.2.10", port: String = "1194", transport: String = "udp",
        caPresent: Bool? = true
    ) -> ProfileDescriptor {
        ProfileDescriptor(
            displayName: "Company SG",
            server: ServerEndpoint(host: host, port: port, transport: transport),
            credentials: [.usernamePassword(usernameLocked: nil)],
            caPresent: caPresent)
    }

    @Test func theSameFileChangesNothing() {
        #expect(reissued().changes(since: old).isEmpty)
    }

    @Test func changesComeInTheReportsOrder() {
        let changes = reissued(host: "192.0.2.11", port: "443").changes(since: old)
        #expect(changes == [
            .host(from: "192.0.2.10", to: "192.0.2.11"),
            .port(from: "1194", to: "443"),
        ])
    }

    /// A record from before the authority was tracked is not a file that
    /// changed, and must not be reported as one.
    @Test func anAuthorityNobodyRecordedIsNotAChange() {
        let untracked = ProfileDescriptor(
            displayName: "Company SG",
            server: ServerEndpoint(host: "192.0.2.10", port: "1194", transport: "udp"),
            credentials: [.usernamePassword(usernameLocked: nil)],
            caPresent: nil)
        #expect(reissued(caPresent: true).changes(since: untracked).isEmpty)
        #expect(reissued(caPresent: false).changes(since: old) == [
            .certificateAuthority(from: true, to: false)
        ])
    }

    // MARK: - The question

    private let movedThePort = Overrides(
        server: ServerEndpoint(host: "192.0.2.10", port: "8443", transport: "udp"))

    @Test func anOverriddenRowTheFileAlsoChangedIsAQuestion() {
        let conflicts = movedThePort.conflicts(with: reissued(port: "443"), replacing: old)
        #expect(conflicts.map(\.kind) == [
            .changedUnderneath(.port, fileWas: "1194", fileNow: "443", mine: "8443")
        ])
    }

    @Test func aRowNobodyOverrodeIsJustAChange() {
        let conflicts = Overrides().conflicts(with: reissued(port: "443"), replacing: old)
        #expect(conflicts.isEmpty)
    }

    /// The employer moved the port to where the user had already put it.
    /// Nothing to ask: the row reads "from the profile" from now on.
    @Test func anOverrideTheFileCaughtUpWithIsNotAQuestion() {
        let conflicts = movedThePort.conflicts(with: reissued(port: "8443"), replacing: old)
        #expect(conflicts.isEmpty)
    }

    /// The endpoint override holds the old host too, but only as a snapshot:
    /// once that part has followed the file (`following`), the moved host is
    /// a change and not a question.
    @Test func anOverrideOnARowTheFileLeftAloneIsNotAQuestion() {
        let new = reissued(host: "192.0.2.11")
        let record = movedThePort.following(new, from: old)
        #expect(record.server?.host == "192.0.2.11", "the snapshot follows the file")
        #expect(record.server?.port == "8443", "the user's own value stays")
        #expect(record.conflicts(with: new, replacing: old).isEmpty)
    }

    @Test func anEndpointTheFileCaughtUpWithEntirelyIsNoOverride() {
        let record = movedThePort.following(reissued(port: "8443"), from: old)
        #expect(record.server == nil)
    }

    /// Without the old descriptor there is nothing to compare, and the three
    /// refusals are still found.
    @Test func withoutTheOldFileOnlyTheRefusalsAreFound() {
        let locked = ProfileDescriptor(
            displayName: "Company SG",
            server: ServerEndpoint(host: "192.0.2.10", port: "443", transport: "udp"),
            credentials: [.usernamePassword(usernameLocked: "svc")])
        var overrides = movedThePort
        overrides.username = "alex"
        let conflicts = overrides.conflicts(with: locked, replacing: nil)
        #expect(conflicts.map(\.kind) == [
            .usernameNowFixed(userValue: "alex", fixedValue: "svc")
        ])
    }

    /// Through the store, which knows the old descriptor because it holds it.
    @Test func theStoreReportsTheQuestionOnReplace() throws {
        let store = StoredProfileStore(
            secrets: ProfileStoreTests.Secrets(), metadata: ProfileStoreTests.Metadata())
        let profile = Profile(
            origin: Profile.Origin(filename: "sg.ovpn", importedAt: Date()),
            title: "Company SG", descriptor: old)
        try store.add(profile, configuration: Data("old".utf8))
        try store.setOverrides(movedThePort, for: profile.id)

        let conflicts = try store.replaceConfiguration(
            Data("new".utf8), descriptor: reissued(port: "443"), title: "Company SG",
            for: profile.id)
        #expect(conflicts.map(\.kind) == [
            .changedUnderneath(.port, fileWas: "1194", fileNow: "443", mine: "8443")
        ])
        // And the override itself is untouched: reported, not resolved.
        #expect(try store.overrides(for: profile.id) == movedThePort)
    }

    @Test func theStoreLetsASnapshotFollowTheFile() throws {
        let store = StoredProfileStore(
            secrets: ProfileStoreTests.Secrets(), metadata: ProfileStoreTests.Metadata())
        let profile = Profile(
            origin: Profile.Origin(filename: "sg.ovpn", importedAt: Date()),
            title: "Company SG", descriptor: old)
        try store.add(profile, configuration: Data("old".utf8))
        try store.setOverrides(movedThePort, for: profile.id)

        let conflicts = try store.replaceConfiguration(
            Data("new".utf8), descriptor: reissued(host: "192.0.2.11"), title: "Company SG",
            for: profile.id)
        #expect(conflicts.isEmpty)
        let after = try store.overrides(for: profile.id)
        #expect(after.server?.host == "192.0.2.11")
        #expect(after.server?.port == "8443")
    }
}
