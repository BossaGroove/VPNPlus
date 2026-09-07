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
import VPNPlusCore

/// The region above the grid: **the profile that is involved, lifted out of
/// the grid rather than duplicated in it** (D114).
///
/// That one rule is what makes the whole screen simple. Because the involved
/// profile is *not* in the grid, a grid card never shows connection state,
/// never needs a status dot, and has exactly one design. And it states C6
/// structurally — one tunnel at a time, so one profile above the line and the
/// rest below it.
///
/// **Never navigate to connect** (D54): everything here happens in place.
@MainActor
final class PromotedRegionView: NSView {
    private let nameLabel = NSTextField.label(
        font: Type.cardTitle, colour: Palette.textSecondary, truncation: .byTruncatingMiddle)
    private let stateLabel = NSTextField.label(font: Type.stateTitle, colour: Palette.textPrimary)
    private let clockLabel = NSTextField.label(
        font: Type.ticking(Type.stateTitle), colour: Palette.textSecondary)
    private let detailLabel = NSTextField.label(
        font: Type.body, colour: Palette.textSecondary, truncation: .byWordWrapping)
    private let primary = NSButton()
    private let guidance = GuidanceView()
    private let connectionStack: NSStackView

    /// The one state-labelled control (D56): Cancel · Disconnect · Try again.
    private var primaryAction: (() -> Void)?

    var onCancel: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onRetry: (() -> Void)?

    init() {
        primary.bezelStyle = .rounded
        primary.font = Type.control
        primary.controlSize = .large
        primary.translatesAutoresizingMaskIntoConstraints = false

        let headline = NSStackView(views: [stateLabel, clockLabel])
        headline.orientation = .horizontal
        headline.spacing = Space.m
        headline.alignment = .firstBaseline

        connectionStack = NSStackView(views: [nameLabel, headline, detailLabel, primary])
        connectionStack.orientation = .vertical
        connectionStack.alignment = .leading
        connectionStack.spacing = Space.s
        connectionStack.setCustomSpacing(Space.l, after: detailLabel)
        connectionStack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        primary.target = self
        primary.action = #selector(act)

        // **An NSStackView, and that is load-bearing.** A stack view detaches
        // a hidden view from its layout; a plain view keeps its space. With
        // these two as plain subviews pinned only `lessThanOrEqualTo` the
        // bottom, nothing pulled this region's height down — Auto Layout gave
        // it 584 of the window's 672 points and left the grid's scroll view
        // zero, which is the empty window M5.4 first shipped (measured).
        //
        // Pinned to **all four** edges, so the region is exactly as tall as
        // whichever of the two is showing — and nothing at all when neither
        // is, which is Idle.
        let outer = NSStackView(views: [connectionStack, guidance])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            primary.heightAnchor.constraint(greaterThanOrEqualToConstant: Space.hitTarget),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - The connection states

    /// `name` is what the user calls the profile, composed by the window.
    func show(_ connection: Connection, name: String, at now: Date = Date()) {
        guidance.isHidden = true
        connectionStack.isHidden = false
        nameLabel.stringValue = name
        nameLabel.isHidden = false
        detailLabel.isHidden = true
        detailLabel.preferredMaxLayoutWidth = 520

        switch connection {
        case .connecting(let attempt), .reconnecting(let attempt):
            stateLabel.stringValue = connection.stateLine(at: now)
            stateLabel.textColor = Palette.textPrimary
            // Attempt-elapsed, and never in a session duration's place (D73).
            clockLabel.stringValue = "\(Int(attempt.elapsed(at: now).components.seconds))s"
            clockLabel.isHidden = false
            // **Cancel, not Disconnect.** Nothing is up to disconnect, and an
            // aborted attempt restores as completely as a clean one (D77).
            label(primary, String(localized: "Cancel"), keyEquivalent: "\u{1b}") { [weak self] in
                self?.onCancel?()
            }

        case .connected(let session):
            stateLabel.stringValue = String(localized: "Connected")
            stateLabel.textColor = Palette.stateConnected
            clockLabel.stringValue = connection.clock(at: now)
            clockLabel.isHidden = false
            // No confirmation, and no setting for one (D74): reversible,
            // one click, unmistakable.
            label(primary, String(localized: "Disconnect"), keyEquivalent: "") { [weak self] in
                self?.onDisconnect?()
            }
            _ = session

        case .failed(let record):
            // The name is already in the title — "Couldn't connect to X" —
            // and A10's copy rule puts it there on purpose (rule 2). Saying it
            // twice reads like a stutter.
            nameLabel.isHidden = true
            stateLabel.stringValue = FailureCopy.title(record, name: name)
            stateLabel.textColor = Palette.stateFailed
            clockLabel.isHidden = true
            detailLabel.stringValue = FailureCopy.body(record, name: name)
            detailLabel.isHidden = false
            label(primary, String(localized: "Try Again"), keyEquivalent: "\r") { [weak self] in
                self?.onRetry?()
            }

        case .disconnecting(let teardown):
            stateLabel.stringValue =
                teardown.isSwitch
                ? String(localized: "Switching")
                : String(localized: "Disconnecting")
            stateLabel.textColor = Palette.textPrimary
            clockLabel.isHidden = true
            primary.isHidden = true

        case .disconnected:
            // Nothing is promoted when nothing is happening; the grid is the
            // content (A12's Idle).
            connectionStack.isHidden = true
        }
    }

    /// Idle: there is nothing promoted, because nothing is happening — and
    /// **the region takes no space at all**, rather than keeping the height of
    /// whatever it showed last. A hidden view keeps its layout space; a view
    /// with nothing in it does not.
    func showNothing() {
        connectionStack.isHidden = true
        guidance.isHidden = true
    }

    /// Setup and Blocked: the region carries the guidance, and **the reason is
    /// stated once here rather than repeated on every card** (D116). D67 asks
    /// for a visible reason, not fifteen copies of one.
    func show(
        guidance content: (title: String, body: String, action: (title: String, run: () -> Void)?)
    ) {
        connectionStack.isHidden = true
        guidance.isHidden = false
        guidance.show(title: content.title, body: content.body, action: content.action)
    }

    private func label(
        _ button: NSButton, _ title: String, keyEquivalent: String, run: @escaping () -> Void
    ) {
        button.isHidden = false
        button.title = title
        button.keyEquivalent = keyEquivalent
        primaryAction = run
        // A20: focus moves to the promoted region's primary control — the
        // thing the user just acted on — so Return does the obvious next
        // thing.
        window?.makeFirstResponder(button)
    }

    @objc private func act() { primaryAction?() }
}
