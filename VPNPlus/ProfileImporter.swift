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
        case let .ready(configuration, descriptor, _):
            do {
                try store(configuration, descriptor, from: url, waivers: waiving)
                onChange?()
                if let message = ImportMessage.forOutcome(outcome, filename: filename) {
                    // Imported, and what was set aside disclosed as a count
                    // with the list behind it (2.8, D187).
                    present(message, over: window, url: url)
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
            present(message, over: window, url: url)
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
            present(message, over: window, url: url)
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
            report(
                profile, replacedBy: descriptor, conflicts: conflicts,
                setAside: setAside.directives.count, over: window)
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

    /// **The ReplaceFile artboard**: a report of what the new file changed,
    /// what the user keeps, and the questions the two together raise. An
    /// override the new text contradicts is **kept and asked about**:
    /// dropping it silently is what D132 forbids, and the user is the only
    /// one who can say which they meant.
    ///
    /// `profile` is the record from before the replace, so its descriptor is
    /// the old file's — which is what the before → after rows compare with.
    private func report(
        _ profile: Profile, replacedBy descriptor: ProfileDescriptor,
        conflicts: [OverrideConflict], setAside: Int, over window: NSWindow?
    ) {
        let overrides = (try? store.overrides(for: profile.id)) ?? Overrides()
        let kept = ReplaceCopy.kept(
            overrides, credentialsSaved: profile.credentialsSaved, against: descriptor)
        let name = overrides.title ?? descriptor.preferredTitle(filename: profile.origin.filename)
        let sheet = ReplaceReportSheet(
            title: String(localized: "Profile file replaced"),
            summary: ReplaceCopy.summary(name: name, keptAnything: !kept.isEmpty, setAside: setAside),
            changes: profile.descriptor.map { descriptor.changes(since: $0).map(ReplaceCopy.row) },
            kept: kept,
            questions: conflicts.map { conflict -> ReplaceReportSheet.Question in
                var resolve: (@MainActor () -> Void)?
                if let setting = ReplaceCopy.setting(of: conflict) {
                    resolve = { [weak self] in self?.revert(setting, for: profile.id, to: descriptor) }
                }
                return ReplaceReportSheet.Question(text: ReplaceCopy.question(conflict), resolve: resolve)
            })
        show(sheet, over: window)
    }

    /// **Use the file's**: the one row, reverted, and nothing else touched.
    private func revert(_ setting: Overrides.Setting, for id: Profile.ID, to descriptor: ProfileDescriptor) {
        do {
            let current = try store.overrides(for: id)
            try store.setOverrides(current.reverting(setting, to: descriptor), for: id)
            onChange?()
        } catch {
            log.error(
                "could not take the file's value for \(String(describing: setting), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
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

    /// The message as a sheet in the window (M5.10, the ImportError artboard):
    /// the one thing the user can do about it under the text, the alternative
    /// as a footnote, and a list behind a count unfolding in place rather than
    /// in a second alert (D187).
    private func present(_ message: ImportMessage, over window: NSWindow?, url: URL) {
        let cancel = MessageSheet.Button(title: String(localized: "Cancel"), role: .cancel)
        let ok = MessageSheet.Button(title: String(localized: "OK"), role: .primary)
        var buttons: [MessageSheet.Button] = [ok]
        var details: MessageSheet.Details?
        switch message.action {
        case .chooseFile(let named):
            buttons = [
                MessageSheet.Button(title: String(localized: "Choose the file…"), role: .primary) {
                    [weak self] in self?.locate(named, for: url, over: window)
                },
                cancel,
            ]
        case .importAnyway(let setting):
            buttons = [
                MessageSheet.Button(title: String(localized: "Import Anyway"), role: .primary) {
                    [weak self] in self?.importProfile(at: url, over: window, waiving: setting)
                },
                cancel,
            ]
            details = MessageSheet.Details(link: String(localized: "Show which"), lines: setting)
        case .showDetails(let link, let lines):
            details = MessageSheet.Details(link: link, lines: lines)
        case nil:
            break
        }
        let sheet = MessageSheet(
            icon: message.warns ? .warning : nil,
            title: message.title,
            body: MessageSheet.prose(message.body, bold: message.bold, code: message.code),
            footnote: message.footnote.map { MessageSheet.note($0) },
            details: details,
            buttons: buttons,
            placement: .underTheText)
        show(sheet, over: window)
    }

    private func presentPlain(title: String, body: String, over window: NSWindow?) {
        let sheet = MessageSheet(
            icon: .warning,
            title: title,
            body: MessageSheet.prose(body),
            buttons: [MessageSheet.Button(title: String(localized: "OK"), role: .primary)],
            placement: .underTheText)
        show(sheet, over: window)
    }

    /// In the window, as a sheet. Called from inside an Open panel's
    /// completion as often as not, while that panel is still the window's
    /// sheet — so a panel is waited out, and a sheet of ours (the
    /// configuration sheet, whose footer starts a replace) is presented over.
    private func show(_ sheet: NSViewController, over window: NSWindow?) {
        guard let window = window ?? NSApp.mainWindow else {
            log.error("no window to show a message in")
            return
        }
        if let attached = window.attachedSheet {
            if attached is NSSavePanel {
                Task {
                    try? await Task.sleep(for: .milliseconds(60))
                    show(sheet, over: window)
                }
                return
            }
            if let host = attached.contentViewController {
                host.presentAsSheet(sheet)
                return
            }
        }
        window.contentViewController?.presentAsSheet(sheet)
    }

    #if DEBUG
        /// Development only: the two import-side M5.10 sheets on demand, so
        /// they can be captured beside their artboards (D250).
        func debugPresentMissingFile(filename: String, over window: NSWindow?) {
            guard let message = ImportMessage.forOutcome(.missingFile(named: "ca.crt"), filename: filename)
            else { return }
            present(message, over: window, url: URL(fileURLWithPath: NSHomeDirectory()))
        }

        func debugPresentReport(for profile: Profile, over window: NSWindow?) {
            let old = profile.descriptor
                ?? ProfileDescriptor(
                    displayName: profile.title,
                    server: ServerEndpoint(host: "192.0.2.10", port: "1194", transport: "udp"))
            let new = ProfileDescriptor(
                displayName: old.displayName,
                server: ServerEndpoint(host: "192.0.2.11", port: "443", transport: old.server.transport),
                credentials: old.credentials,
                allowsPasswordSave: old.allowsPasswordSave,
                alternateServers: old.alternateServers,
                waivedDirectives: old.waivedDirectives,
                caPresent: old.caPresent,
                externalPKI: old.externalPKI)
            var withOld = profile
            withOld.descriptor = old
            report(
                withOld, replacedBy: new,
                conflicts: [
                    OverrideConflict(
                        kind: .changedUnderneath(
                            .port, fileWas: old.server.port, fileNow: "443", mine: "8443"))
                ],
                setAside: 0, over: window)
        }
    #endif

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
