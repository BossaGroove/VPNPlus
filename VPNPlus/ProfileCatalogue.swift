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
import VPNPlusCore

/// Reading the profiles, in the one place that knows how.
///
/// Both surfaces need the same three answers — what profiles there are, what
/// to call each one, and what each one asks of the user — and **the second
/// implementation of that is where the window and the menu start to
/// disagree**. The status item is a peer of the window (D33), not something
/// derived from it, so what they share has to be shared deliberately.
@MainActor
struct ProfileCatalogue {
    let store: any ProfileStore

    init(store: any ProfileStore = StoredProfileStore.live) {
        self.store = store
    }

    var profiles: [Profile] {
        (try? store.profiles()) ?? []
    }

    /// The user's name for a profile, else the configuration's, else the
    /// file's — composed, because the rule belongs to the overrides record
    /// and not to a view (D230).
    func title(of profile: Profile) -> String {
        settings(of: profile)?.title.value ?? profile.title
    }

    func titles() -> [Profile.ID: String] {
        var titles: [Profile.ID: String] = [:]
        for profile in profiles { titles[profile.id] = title(of: profile) }
        return titles
    }

    func profile(_ id: Profile.ID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The configuration and the user's overrides, composed (D188).
    func settings(of profile: Profile) -> ProfileSettings? {
        guard let descriptor = descriptor(of: profile) else { return nil }
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        return ProfileSettings.compose(
            descriptor, with: overrides, filename: profile.origin.filename)
    }

    /// What the profile says about itself. Stored at import, because once the
    /// extension owns the configuration the app cannot read it again — and
    /// re-deriving it from a copy the app kept would *be* that second copy
    /// (D218).
    func descriptor(of profile: Profile) -> ProfileDescriptor? {
        if let stored = profile.descriptor { return stored }
        // A profile imported before descriptors were stored: derive it once
        // from the copy the app still holds, and keep it.
        guard let configuration = try? store.configuration(for: profile.id),
            let text = String(data: configuration, encoding: .utf8),
            let derived = ProfileImport.describe(text, setAside: profile.waivedDirectives)
        else { return nil }
        try? store.setDescriptor(derived, for: profile.id)
        return derived
    }
}
