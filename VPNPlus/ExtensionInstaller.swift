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
import VPNPlusCore
import os

/// Talks to `OSSystemExtensionManager` for the app, and reports what happened
/// in the vocabulary the app can word (`SetupFailure`, 4.1).
///
/// Two requests: a **probe** at launch — what is installed, without asking
/// anyone anything — and an **activation** when the user has been told what
/// is coming (D65). The probe is what lets setup be deferred to the first
/// Connect (D59) while an already-approved extension still gets replaced by
/// an update at launch (C2a).
@MainActor
final class ExtensionInstaller: NSObject {
    enum Status: Equatable {
        case idle
        case probing
        case requesting
        case needsApproval
        case active
        case failed(SetupFailure)
    }

    // nonisolated: the OSSystemExtensionRequestDelegate callbacks are not
    // main-actor isolated, and they are exactly where logging matters most.
    private nonisolated static let log = Logger(subsystem: "com.bossagroove.VPNPlus", category: "sysext")

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onChange?(status) } }
    }
    var onChange: ((Status) -> Void)?

    private let identifier: String
    /// The probe's request, so its completion is told apart from an
    /// activation's.
    private nonisolated(unsafe) var probeRequest: OSSystemExtensionRequest?

    init(identifier: String) {
        self.identifier = identifier
    }

    /// What is installed, and is it enabled. Enabled means approved on this
    /// Mac, so the extension is activated straight away — a no-op or a
    /// silent in-place replacement (C2a) — and the user is never asked.
    func probe() {
        guard status == .idle else { return }
        status = .probing
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        probeRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func activate() {
        guard InstallLocation.current.isCorrect else {
            status = .failed(.wrongLocation(path: Bundle.main.bundleURL.path))
            return
        }
        Self.log.notice("activating \(self.identifier, privacy: .public) from \(Bundle.main.bundleURL.path, privacy: .public)")
        status = .requesting
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// The user said *Not now*, or the OS prompt went unanswered.
    func decline() {
        status = .failed(.declined)
    }

    /// The system's codes, mapped once (4.1). Nothing else about them travels.
    private nonisolated static func failure(for error: Error) -> SetupFailure {
        let ns = error as NSError
        guard ns.domain == OSSystemExtensionErrorDomain,
            let code = OSSystemExtensionError.Code(rawValue: ns.code)
        else { return .unknown }
        switch code {
        case .requestCanceled, .requestSuperseded, .authorizationRequired:
            return .declined
        case .unsupportedParentBundleLocation:
            return .wrongLocation(path: Bundle.main.bundleURL.path)
        case .forbiddenBySystemPolicy:
            return .forbiddenByPolicy
        case .codeSignatureInvalid, .validationFailed, .extensionNotFound, .extensionMissingIdentifier,
            .missingEntitlement, .unknownExtensionCategory, .duplicateExtensionIdentifer:
            return .damaged
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
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

    nonisolated func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let enabled = properties.contains { $0.isEnabled && !$0.isUninstalling }
        let awaiting = properties.contains { $0.isAwaitingUserApproval }
        Self.log.notice(
            "probe: \(properties.count, privacy: .public) installed, enabled=\(enabled, privacy: .public), awaiting=\(awaiting, privacy: .public)"
        )
        MainActor.assumeIsolated {
            self.probeRequest = nil
            if enabled {
                // Approved on this Mac: bring it up, and let an update replace
                // the staged copy. No prompt can come of this (C2a).
                self.status = .idle
                self.activate()
            } else {
                self.status = .idle
            }
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        MainActor.assumeIsolated { self.status = .needsApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let isProbe = request === probeRequest
        MainActor.assumeIsolated {
            guard !isProbe else { return }
            self.status = result == .completed ? .active : .failed(.needsRestart)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        Self.log.error("request failed domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) info=\(String(describing: ns.userInfo), privacy: .public)")
        let failure = Self.failure(for: error)
        let isProbe = request === probeRequest
        MainActor.assumeIsolated {
            if isProbe {
                // Nothing installed is not a failure; it is the first run.
                self.probeRequest = nil
                self.status = .idle
                return
            }
            self.status = .failed(failure)
        }
    }
}
