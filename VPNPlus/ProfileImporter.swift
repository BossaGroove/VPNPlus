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

    private func store(
        _ configuration: Data,
        _ descriptor: ProfileDescriptor,
        from url: URL,
        waivers: [String]
    ) throws {
        let filename = url.lastPathComponent
        // The title the user sees: what the profile calls itself, else the
        // filename without its extension.
        let title = descriptor.displayName.isEmpty
            ? url.deletingPathExtension().lastPathComponent
            : descriptor.displayName

        // A profile imported again replaces its text and keeps the user's
        // adjustments, rather than becoming a second entry (2.6, D132).
        if let existing = try store.profiles().first(where: { $0.origin.filename == filename }) {
            let conflicts = try store.replaceConfiguration(configuration, descriptor: descriptor, for: existing.id)
            log.notice("replaced \(filename, privacy: .public); \(conflicts.count, privacy: .public) overrides now contradicted")
            return
        }

        let profile = Profile(
            origin: Profile.Origin(filename: filename, importedAt: Date()),
            title: title,
            waivedDirectives: descriptor.waivedDirectives,
            acceptedWaivers: waivers)
        try store.add(profile, configuration: configuration)
        log.notice("imported \(filename, privacy: .public)")
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
            alert.addButton(withTitle: String(localized: "Show Which"))
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
            case (.importAnyway, .alertThirdButtonReturn), (.showDetails, .alertSecondButtonReturn):
                showDetails(details, over: window)
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
    private func showDetails(_ directives: [String], over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Settings VPN Plus doesn't use")
        alert.informativeText = directives.isEmpty
            ? String(localized: "None.")
            : directives.joined(separator: "\n")
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
