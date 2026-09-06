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
        MainActor.assumeIsolated {
            // D2 — a cause and a next action, never a raw code. M0 shows the
            // underlying text because there is no curated copy layer yet;
            // feature-spec 4.1 makes replacing this mandatory before release.
            self.status = .failed("The network component could not be installed. \(error.localizedDescription)")
        }
    }
}
