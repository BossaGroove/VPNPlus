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

import AppKit
import UniformTypeIdentifiers
import VPNPlusCore
import os

/// Drives an import from a file the user gave us to a profile in the store,
/// asking the one question the outcome calls for and no others.
///
/// The three ways in (2.1) all end here: drag onto the window, File > Open, and
/// double-click in the Finder.
@MainActor
final class ProfileImporter {
    static let profileType = UTType("com.bossagroove.VPNPlus.ovpn-profile") ?? .plainText

    private let store: any ProfileStore
    private let inspector = ProfileImport()
    private let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "import")

    /// Called when the set of stored profiles changed.
    var onChange: (() -> Void)?

    init(store: any ProfileStore) {
        self.store = store
    }

    /// Hands over every configuration the extension does not have yet.
    ///
    /// Called at launch and after each import. The extension is unreachable
    /// until it has run since boot (M4.2), so this quietly does nothing when
    /// it cannot; a profile that has not moved yet still connects, and the
    /// connection itself completes the move.
    func handOverPending() {
        let waiting = ((try? store.profiles()) ?? []).filter { !$0.configurationHandedOver }
        guard !waiting.isEmpty else { return }
        for profile in waiting {
            guard let configuration = try? store.configuration(for: profile.id) else { continue }
            handOver(configuration, for: profile.id)
        }
    }

    /// Presents the Open panel (2.1).
    func chooseFile(over window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.profileType]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose a VPN profile to import.")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importProfile(at: url, over: window)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// The whole import, including whatever it has to ask.
    func importProfile(at url: URL, over window: NSWindow?, waiving: [String] = []) {
        let filename = url.lastPathComponent
        let outcome = inspector.inspect(url, waiving: waiving)

        switch outcome {
        case let .ready(configuration, descriptor, setAside):
            do {
                try store(configuration, descriptor, from: url, waivers: waiving)
                onChange?()
                if let message = ImportMessage.forOutcome(outcome, filename: filename) {
                    // Imported, and what was set aside disclosed as a count
                    // with the list behind it (2.8, D187).
                    present(message, over: window, details: setAside.directives, url: url)
                }
            } catch {
                log.error("could not store \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                presentPlain(
                    title: String(localized: "Couldn't save \(filename)"),
                    body: String(localized: """
                        The profile was read, but VPN Plus couldn't save it. \
                        Your Keychain may have denied access.
                        """),
                    over: window)
            }

        case .missingFile, .unrecognised, .refused:
            guard let message = ImportMessage.forOutcome(outcome, filename: filename) else { return }
            let details: [String]
            if case .unrecognised(let directives) = outcome { details = directives } else { details = [] }
            present(message, over: window, details: details, url: url)
        }
    }

    /// A13a's **Replace profile file…**, and D125's model made concrete: an
    /// employer reissues the profile and it costs one file picker rather than a
    /// retyped configuration.
    ///
    /// Unlike an import, this replaces *this* profile whatever the new file is
    /// called — the user pointed at it, so matching on filename would be
    /// second-guessing them. Overrides are kept, and any the new text now
    /// contradicts are named rather than dropped in silence (D132).
    func replaceFile(of profile: Profile, over window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.profileType]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Replace")
        panel.message = String(localized: "Choose the profile file to use from now on.")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { [weak self] in self?.replace(profile, with: url, over: window) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func replace(_ profile: Profile, with url: URL, over window: NSWindow?) {
        let filename = url.lastPathComponent
        let outcome = inspector.inspect(url, waiving: profile.acceptedWaivers)
        guard case let .ready(configuration, descriptor, setAside) = outcome else {
            // Every other outcome is a refusal or a question, and the existing
            // messages already say the right thing about each — the only
            // difference is that nothing was replaced.
            guard let message = ImportMessage.forOutcome(outcome, filename: filename) else { return }
            var details: [String] = []
            if case .unrecognised(let directives) = outcome { details = directives }
            present(message, over: window, details: details, url: url)
            return
        }
        do {
            let conflicts = try store.replaceConfiguration(
                configuration, descriptor: descriptor,
                title: descriptor.preferredTitle(filename: filename), for: profile.id)
            try store.setDescriptor(descriptor, for: profile.id)
            log.notice(
                "replaced the file for \(profile.id.uuidString, privacy: .public); \(conflicts.count, privacy: .public) overrides now contradicted"
            )
            handOver(configuration, for: profile.id)
            onChange?()
            presentPlain(
                title: String(localized: "Replaced with \(filename)"),
                body: Self.summary(conflicts: conflicts, setAside: setAside.directives),
                over: window)
        } catch {
            log.error(
                "could not replace \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            presentPlain(
                title: String(localized: "Couldn't replace \(filename)"),
                body: String(
                    localized: """
                        The profile was read, but VPN Plus couldn't store it. \
                        Your Keychain may have denied access, and the old profile is still in place.
                        """),
                over: window)
        }
    }

    /// What changed, in the user's terms. An override the new text contradicts
    /// is **kept and named**: dropping it silently is what D132 forbids, and
    /// the user is the only one who can say which they meant.
    private static func summary(conflicts: [OverrideConflict], setAside: [String]) -> String {
        var lines: [String] = [
            String(localized: "Your settings for this profile have been kept.")
        ]
        for conflict in conflicts {
            switch conflict.kind {
            case .serverNoLongerOffered(let host):
                lines.append(
                    String(localized: "The new file no longer offers \(host), which you had chosen."))
            case .usernameNowFixed(let userValue, let fixedValue):
                lines.append(
                    String(
                        localized:
                            "The new file fixes the username to \(fixedValue); yours was \(userValue)."
                    ))
            case .passwordSavingNowForbidden:
                lines.append(
                    String(localized: "The new file does not allow saving the password."))
            }
        }
        if !setAside.isEmpty {
            lines.append(
                String(
                    localized: """
                        VPN Plus doesn't use \(setAside.count) of its settings: \
                        \(setAside.joined(separator: ", ")).
                        """))
        }
        return lines.joined(separator: "\n\n")
    }

    private func store(
        _ configuration: Data,
        _ descriptor: ProfileDescriptor,
        from url: URL,
        waivers: [String]
    ) throws {
        let filename = url.lastPathComponent
        let title = descriptor.preferredTitle(filename: filename)

        // A profile imported again replaces its text and keeps the user's
        // adjustments, rather than becoming a second entry (2.6, D132).
        if let existing = try store.profiles().first(where: { $0.origin.filename == filename }) {
            let conflicts = try store.replaceConfiguration(
                configuration, descriptor: descriptor, title: title, for: existing.id)
            try store.setDescriptor(descriptor, for: existing.id)
            log.notice("replaced \(filename, privacy: .public); \(conflicts.count, privacy: .public) overrides now contradicted")
            handOver(configuration, for: existing.id)
            return
        }

        let profile = Profile(
            origin: Profile.Origin(filename: filename, importedAt: Date()),
            title: title,
            waivedDirectives: descriptor.waivedDirectives,
            acceptedWaivers: waivers,
            descriptor: descriptor)
        try store.add(profile, configuration: configuration)
        log.notice("imported \(filename, privacy: .public)")
        handOver(configuration, for: profile.id)
    }

    /// Gives the configuration to the extension, which owns it from then on,
    /// and drops the app's copy.
    ///
    /// The extension is only reachable once it has run since boot (M4.2), so
    /// this may not succeed now — and that is not an error the user should be
    /// told about. The app keeps its copy, hands it over on the next
    /// connection instead, and the profile works either way.
    private func handOver(_ configuration: Data, for id: Profile.ID) {
        Task { [store, log] in
            do {
                try await PrivilegedClient().setSecret(configuration, kind: .configuration, for: id)
                try store.finishHandover(for: id)
                log.notice("the extension now holds the configuration for \(id.uuidString, privacy: .public)")
            } catch {
                log.notice("the extension is not reachable yet; handing over at the next connection")
            }
        }
    }

    // MARK: - Asking

    private func present(_ message: ImportMessage, over window: NSWindow?, details: [String], url: URL) {
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.body

        switch message.action {
        case .chooseFile(let named):
            alert.addButton(withTitle: String(localized: "Choose \(named)…"))
            alert.addButton(withTitle: String(localized: "Cancel"))
        case .importAnyway(let setting):
            alert.addButton(withTitle: String(localized: "Import Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Show Which"))
            _ = setting
        case .showDetails:
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Show Details"))
        case nil:
            alert.addButton(withTitle: String(localized: "OK"))
        }

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch (message.action, response) {
            case (.chooseFile(let named), .alertFirstButtonReturn):
                locate(named, for: url, over: window)
            case (.importAnyway(let setting), .alertFirstButtonReturn):
                importProfile(at: url, over: window, waiving: setting)
            case (.importAnyway, .alertThirdButtonReturn):
                showDetails(
                    titled: String(localized: "Settings VPN Plus doesn't use"), details, over: window)
            case (.showDetails(let titled, let lines), .alertSecondButtonReturn):
                showDetails(titled: titled, lines, over: window)
            default:
                break
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    private func presentPlain(title: String, body: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }

    /// The list, one click behind the count (D187).
    private func showDetails(titled: String, _ lines: [String], over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = titled
        alert.informativeText = lines.isEmpty
            ? String(localized: "None.")
            : lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: { _ in })
        } else {
            alert.runModal()
        }
    }

    /// Lets the user point at the file the profile refers to, then imports from
    /// a folder containing both (2.3). The profile is not rewritten: a copy of
    /// the pair is merged in a temporary folder, and only the merged text is
    /// stored (D188).
    private func locate(_ named: String, for url: URL, over window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Use This File")
        panel.message = String(localized: "Find \(named), the file this profile refers to.")
        panel.directoryURL = url.deletingLastPathComponent()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else { return }
            do {
                let staged = try stage(profile: url, alongside: chosen, named: named)
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                importProfile(at: staged, over: window)
            } catch {
                log.error("could not stage the profile: \(error.localizedDescription, privacy: .public)")
                presentPlain(
                    title: String(localized: "Couldn't read \(chosen.lastPathComponent)"),
                    body: String(localized: "VPN Plus couldn't read that file."),
                    over: window)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Copies the profile and the file it wants into one temporary folder,
    /// under the name the profile expects, so the engine's own merge can
    /// resolve it. Nothing the user owns is moved or rewritten.
    private func stage(profile: URL, alongside chosen: URL, named: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpnplus-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(profile.lastPathComponent)
        try FileManager.default.copyItem(at: profile, to: staged)
        try FileManager.default.copyItem(at: chosen, to: folder.appendingPathComponent(named))
        return staged
    }
}
