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

/// The rules feature-spec §2 states about a profile's surface, tested in the
/// model so no interface has to remember them and M5 only has to render them.
struct ProfileSettingsTests {
    private func descriptor(
        name: String = "Company SG",
        server: ServerEndpoint = ServerEndpoint(host: "sg.example.invalid", port: "1194", transport: "udp"),
        credentials: [CredentialRequirement] = [.usernamePassword(usernameLocked: nil)],
        allowsPasswordSave: Bool = true,
        alternates: [ServerChoice] = [],
        waived: [String] = []
    ) -> ProfileDescriptor {
        ProfileDescriptor(
            displayName: name, server: server, credentials: credentials,
            allowsPasswordSave: allowsPasswordSave, alternateServers: alternates,
            waivedDirectives: waived)
    }

    // MARK: - Provenance (D126)

    @Test func aValueFromTheProfileSaysSo() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides())
        #expect(settings.title.value == "Company SG")
        #expect(settings.title.provenance == .fromProfile)
    }

    @Test func anOverriddenValueKeepsWhatTheProfileSaid() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides(title: "Work"))
        #expect(settings.title.value == "Work")
        #expect(settings.title.provenance == .overridden(profileValue: "Company SG"))
    }

    @Test func aValueTheProfileDoesNotSupplyIsNotInvented() {
        let settings = ProfileSettings.compose(descriptor(name: ""), with: Overrides())
        #expect(settings.title.value.isEmpty)
        #expect(settings.title.provenance == .notInProfile)
    }

    @Test func anOverrideEqualToTheProfileIsNotAnOverride() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides(title: "Company SG"))
        #expect(settings.title.provenance == .fromProfile)
    }

    // MARK: - 2.14: a fixed username is read-only, never an empty field

    @Test func aFixedUsernameIsReadOnly() {
        let settings = ProfileSettings.compose(
            descriptor(credentials: [.usernamePassword(usernameLocked: "alex")]), with: Overrides())
        guard case .credentials(let username, _, _) = settings.signIn else {
            Issue.record("expected credentials, got \(settings.signIn)"); return
        }
        #expect(username == .fixed("alex"))
    }

    @Test func aFixedUsernameCannotBeOverridden() {
        // The user may have typed one before the profile was reissued; the
        // profile wins, and the conflict is reported rather than silently kept.
        let fixed = descriptor(credentials: [.usernamePassword(usernameLocked: "alex")])
        let settings = ProfileSettings.compose(fixed, with: Overrides(username: "someone-else"))
        guard case .credentials(let username, _, _) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(username == .fixed("alex"))
        #expect(Overrides(username: "someone-else").conflicts(with: fixed) ==
                [OverrideConflict(kind: .usernameNowFixed(userValue: "someone-else", fixedValue: "alex"))])
    }

    @Test func aFreeUsernameIsEditable() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides(username: "alex"))
        guard case .credentials(let username, _, _) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(username == .editable(ResolvedValue(value: "alex", provenance: .overridden(profileValue: ""))))
    }

    // MARK: - 2.15: password saving is not offered when the profile forbids it

    @Test func passwordSavingIsNotOfferedWhenTheProfileForbidsIt() {
        let settings = ProfileSettings.compose(descriptor(allowsPasswordSave: false), with: Overrides())
        guard case .credentials(_, let saving, _) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(saving == .forbiddenByProfile, "it must not be offered and disabled, but absent")
    }

    @Test func aForbiddingProfileOverridesTheUsersEarlierChoice() {
        // D129: our default applies where the profile is silent, never against it.
        let settings = ProfileSettings.compose(
            descriptor(allowsPasswordSave: false), with: Overrides(savePassword: true))
        guard case .credentials(_, let saving, _) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(saving == .forbiddenByProfile)
    }

    @Test func passwordSavingIsOnByDefaultWhereThePofileIsSilent() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides())
        guard case .credentials(_, let saving, _) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(saving == .offered(on: true))
    }

    // MARK: - 2.16 / D130: several servers make a picker

    @Test func severalServersBecomeAPicker() {
        let settings = ProfileSettings.compose(
            descriptor(alternates: [
                ServerChoice(host: "sg.example.invalid", label: "Singapore"),
                ServerChoice(host: "hk.example.invalid", label: "Hong Kong"),
            ]), with: Overrides(selectedServer: "hk.example.invalid"))
        guard case .choice(let offered, let selected) = settings.server else {
            Issue.record("expected a picker, got \(settings.server)"); return
        }
        #expect(offered.count == 2)
        #expect(selected == "hk.example.invalid")
        #expect(settings.effectiveServer.host == "hk.example.invalid")
    }

    @Test func aChoiceTheProfileNoLongerOffersFallsBackRatherThanShowingADeadOne() {
        let reissued = descriptor(alternates: [ServerChoice(host: "sg.example.invalid", label: "Singapore")])
        let settings = ProfileSettings.compose(reissued, with: Overrides(selectedServer: "gone.example.invalid"))
        guard case .choice(_, let selected) = settings.server else {
            Issue.record("expected a picker"); return
        }
        #expect(selected == "sg.example.invalid")
        #expect(Overrides(selectedServer: "gone.example.invalid").conflicts(with: reissued) ==
                [OverrideConflict(kind: .serverNoLongerOffered("gone.example.invalid"))])
    }

    @Test func oneServerStaysAValueWithItsOwnProvenance() {
        let settings = ProfileSettings.compose(descriptor(), with: Overrides())
        guard case .single(let host, let port, let transport) = settings.server else {
            Issue.record("expected a single server"); return
        }
        #expect(host.value == "sg.example.invalid")
        #expect(host.provenance == .fromProfile)
        #expect(port.value == "1194")
        #expect(transport.value == "udp")
    }

    @Test func aTypedServerOverridesTheProfilesOwn() {
        let settings = ProfileSettings.compose(
            descriptor(), with: Overrides(server: ServerEndpoint(host: "vpn.example.invalid", port: "443", transport: "tcp")))
        guard case .single(let host, let port, _) = settings.server else {
            Issue.record("expected a single server"); return
        }
        #expect(host.provenance == .overridden(profileValue: "sg.example.invalid"))
        #expect(port.value == "443")
        #expect(settings.effectiveServer.host == "vpn.example.invalid")
    }

    // MARK: - Nothing to ask, and the rest

    @Test func aProfileThatSignsInByItselfAsksNothing() {
        let settings = ProfileSettings.compose(descriptor(credentials: [.none]), with: Overrides())
        #expect(settings.signIn == .notNeeded)
    }

    @Test func aChallengeIsCarriedWithItsPromptAndWhetherItEchoes() {
        let settings = ProfileSettings.compose(
            descriptor(credentials: [
                .usernamePassword(usernameLocked: nil),
                .challenge(prompt: "Enter your code", echo: false),
            ]), with: Overrides())
        guard case .credentials(_, _, let challenge) = settings.signIn else {
            Issue.record("expected credentials"); return
        }
        #expect(challenge?.prompt == "Enter your code")
        #expect(challenge?.echo == false)
    }

    @Test func reconnectingAutomaticallyIsOnUnlessTheUserSaysOtherwise() {
        #expect(ProfileSettings.compose(descriptor(), with: Overrides()).reconnectAutomatically)
        #expect(!ProfileSettings.compose(descriptor(), with: Overrides(reconnectAutomatically: false)).reconnectAutomatically)
        #expect(!ProfileSettings.compose(descriptor(), with: Overrides()).connectWhenAppOpens)
    }

    @Test func waivedDirectivesAreCarriedThroughForDisclosure() {
        let settings = ProfileSettings.compose(
            descriptor(waived: ["resolv-retry", "persist-key", "persist-tun"]), with: Overrides())
        #expect(settings.waivedDirectives.count == 3)
    }

    // MARK: - Overrides survive a reissued profile (2.6, D132)

    @Test func overridesAreASeparateRecordAndSurviveRoundTripping() throws {
        let overrides = Overrides(
            title: "Work", username: "alex", savePassword: false, reconnectAutomatically: false)
        let data = try JSONEncoder().encode(overrides)
        #expect(try JSONDecoder().decode(Overrides.self, from: data) == overrides)
        #expect(Overrides().isEmpty)
        #expect(!overrides.isEmpty)
    }

    @Test func anUncontradictedOverrideIsNotReportedAsAConflict() {
        let unchanged = descriptor(alternates: [ServerChoice(host: "sg.example.invalid", label: "Singapore")])
        let overrides = Overrides(title: "Work", selectedServer: "sg.example.invalid", username: "alex")
        #expect(overrides.conflicts(with: unchanged).isEmpty)
    }

    @Test func forbiddingPasswordSavingIsReportedWhenTheUserHadAskedForIt() {
        let reissued = descriptor(allowsPasswordSave: false)
        #expect(Overrides(savePassword: true).conflicts(with: reissued) ==
                [OverrideConflict(kind: .passwordSavingNowForbidden)])
    }
}
