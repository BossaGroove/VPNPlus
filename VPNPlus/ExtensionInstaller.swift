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
import SystemExtensions
import os

/// Activates the packet tunnel system extension and reports what happened in
/// plain language. M0 does nothing else with it — the tunnel engine is M1.
@MainActor
final class ExtensionInstaller: NSObject {
    enum Status: Equatable {
        case idle
        case requesting
        case needsApproval
        case active
        case failed(String)
    }

    // nonisolated: the OSSystemExtensionRequestDelegate callbacks are not
    // main-actor isolated, and they are exactly where logging matters most.
    private nonisolated static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "sysext")

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onChange?(status) } }
    }

    var onChange: ((Status) -> Void)?

    private let identifier: String

    init(identifier: String) {
        self.identifier = identifier
    }

    func activate() {
        guard InstallLocation.current.isCorrect else {
            status = .failed(InstallLocation.current.explanation ?? "")
            return
        }

        // Diagnostic: OSSystemExtensionManager scans the *running* bundle, and
        // when it fails it reports only the identifier it wanted. Log what we
        // are actually looking at, since that is the part it will not say.
        let bundle = Bundle.main.bundleURL
        let dir = bundle.appendingPathComponent("Contents/Library/SystemExtensions")
        let found = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        Self.log.notice("bundle=\(bundle.path, privacy: .public)")
        Self.log.notice("sysex dir=\(dir.path, privacy: .public) contents=\(found, privacy: .public)")
        for name in found {
            let plist = dir.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
            let id = (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String) ?? "<none>"
            Self.log.notice("  \(name, privacy: .public) -> \(id, privacy: .public)")
        }
        Self.log.notice("requesting=\(self.identifier, privacy: .public)")

        status = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // C7 / feature-spec 8.2 — an update replaces in place and asks nothing.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.status = .needsApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        MainActor.assumeIsolated {
            self.status = result == .completed
                ? .active
                : .failed("The network component needs a restart to finish installing.")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        Self.log.error("activation failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) info=\(String(describing: ns.userInfo), privacy: .public)")
        MainActor.assumeIsolated {
            // D2 — a cause and a next action, never a raw code. M0 shows the
            // underlying text because there is no curated copy layer yet;
            // feature-spec 4.1 makes replacing this mandatory before release.
            self.status = .failed("The network component could not be installed. \(error.localizedDescription)")
        }
    }
}
