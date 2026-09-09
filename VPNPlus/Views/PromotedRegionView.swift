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
/// **Built from the artboards, not from the prose about them** (D250). The
/// mockup gives this region a *container* — and that is the whole difference
/// between what M5.4 shipped and what was designed: without one, an idle card
/// in the grid below looks more substantial than the live connection above it,
/// which is the least important thing on screen outweighing the most.
///
/// Two shapes, and the artboards are explicit about which state gets which:
///
/// | | Gutter | Title | Third line | Buttons |
/// |---|---|---|---|---|
/// | Connected | 12 pt dot | 22 pt | duration | right, centred |
/// | Connecting / Switching | spinner | 22 pt | elapsed, or what is coming down | right |
/// | Failed / Blocked / Setup | triangle or spinner | **15 pt** | prose | **below**, left |
///
/// **The accent lives in the gutter, never in the word** (D-6). A green
/// "Connected" spends the accent on the one word that already says it and
/// leaves nothing for a reader who cannot see the colour; a green dot beside a
/// neutral word says it twice, in two channels.
@MainActor
final class PromotedRegionView: NSView {
    /// The artboard's measurements. Named rather than inlined because three of
    /// them are load-bearing: the gutter is what gives every state one
    /// indicator in one place, and the container's padding and radius are what
    /// make this a surface rather than text on a window.
    private enum Metric {
        static let padding: CGFloat = 18
        static let radius: CGFloat = 10
        static let gutter: CGFloat = 22
        static let gutterGap: CGFloat = 14
        static let dot: CGFloat = 12
        static let icon: CGFloat = 20
        static let buttonHeight: CGFloat = 28
        static let disconnectWidth: CGFloat = 116
        static let cancelWidth: CGFloat = 100
    }

    // The gutter: one indicator per state, and only one ever visible.
    private let dot = NSView()
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()

    private let nameLabel = NSTextField.label(
        font: Type.body, colour: Palette.textSecondary, truncation: .byTruncatingMiddle)
    private let stateLabel = NSTextField.label(font: Type.stateTitle, colour: Palette.textPrimary)
    /// The line under the state: a duration, an elapsed time, or — during a
    /// switch — what is being disconnected first. One slot, because the
    /// artboards put all three in the same place.
    private let clockLabel = NSTextField.label(
        font: Type.ticking(Type.caption), colour: Palette.textTertiary)

    private let proseTitle = NSTextField.label(
        font: Type.promotedProse, colour: Palette.textPrimary, truncation: .byWordWrapping)
    private let proseBody = NSTextField.label(
        font: Type.body, colour: Palette.textSecondary, truncation: .byWordWrapping)

    private let primary = NSButton()
    private let proseButton = NSButton()
    /// A10's further actions: *Show details* on every failure (D50), and a
    /// remedy that lives elsewhere where there is one — M7's *Open Date &
    /// Time*. Two slots, because no message has more.
    private let secondaryButton = NSButton()
    private let tertiaryButton = NSButton()

    // The Failed artboard's two blocks under the paragraph (A7's parts three
    // and four): a small heavy heading, then a list or a paragraph.
    private let causesHeading = NSTextField.label(
        font: Type.sectionLabel, colour: Palette.textSecondary)
    private let causesList = NSStackView()
    private let changedHeading = NSTextField.label(
        font: Type.sectionLabel, colour: Palette.textSecondary)
    private let changedBody = NSTextField.label(
        font: Type.body, colour: Palette.textSecondary, truncation: .byWordWrapping)

    private let shortForm: NSStackView
    private let proseForm: NSStackView
    private let content: NSStackView
    private let gutterBox = NSView()
    private var padding: [NSLayoutConstraint] = []

    private var primaryAction: (() -> Void)?
    private var proseAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var tertiaryAction: (() -> Void)?
    /// *Show details*: the window opens the Diagnostics sheet (A14, M6.5).
    var onShowDetails: (() -> Void)?

    /// Now against the last time the failed profile worked, when the window
    /// has it (A7, D46). Set like `facts`: exactly one state reads it.
    var comparison: NetworkComparison?

    var onCancel: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onRetry: (() -> Void)?

    /// True while nothing is promoted, so the window can close the gap above
    /// the grid instead of leaving the height of a card that is not there.
    private(set) var isEmpty = true

    init() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Metric.dot / 2
        dot.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        for control in [primary, proseButton, secondaryButton, tertiaryButton] {
            control.bezelStyle = .rounded
            control.font = Type.control
            control.translatesAutoresizingMaskIntoConstraints = false
            control.heightAnchor.constraint(equalToConstant: Metric.buttonHeight).isActive = true
        }

        // Short states: the button sits at the trailing edge, vertically
        // centred against the three lines — not underneath them.
        let lines = NSStackView(views: [nameLabel, stateLabel, clockLabel])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Space.xs
        lines.setCustomSpacing(Space.s, after: stateLabel)
        shortForm = NSStackView(views: [lines, primary])
        shortForm.orientation = .horizontal
        shortForm.alignment = .centerY
        shortForm.spacing = Space.l
        shortForm.distribution = .fill
        // The text takes the slack so the button lands on the trailing edge.
        // Without this the stack sizes to its content and the button sits
        // against the headline, which reads as part of it.
        lines.setContentHuggingPriority(.init(1), for: .horizontal)
        primary.setContentHuggingPriority(.required, for: .horizontal)

        // Prose states: a title, a paragraph, the Failed artboard's two blocks
        // — *Common causes*, *What changed since it last worked* — and the
        // actions below it all. The blocks hide when a message has nothing for
        // them, and the stack closes up around them.
        causesHeading.stringValue = String(localized: "Common causes")
        causesList.orientation = .vertical
        causesList.alignment = .leading
        causesList.spacing = Space.xs
        changedHeading.stringValue = String(localized: "What changed since it last worked")
        let actions = NSStackView(views: [proseButton, secondaryButton, tertiaryButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Space.s
        proseForm = NSStackView(views: [
            proseTitle, proseBody, causesHeading, causesList, changedHeading, changedBody, actions,
        ])
        proseForm.orientation = .vertical
        proseForm.alignment = .leading
        proseForm.spacing = Space.s
        // The artboard's rhythm: 16 above a heading, 4 under it, 20 above the
        // buttons.
        proseForm.setCustomSpacing(Space.l, after: proseBody)
        proseForm.setCustomSpacing(Space.xs, after: causesHeading)
        proseForm.setCustomSpacing(Space.l, after: causesList)
        proseForm.setCustomSpacing(Space.xs, after: changedHeading)
        proseForm.setCustomSpacing(Space.xl, after: changedBody)

        content = NSStackView(views: [shortForm, proseForm])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        // …and the content takes the slack from the gutter, so "trailing
        // edge" means the card's edge rather than the text's.
        content.setContentHuggingPriority(.init(1), for: .horizontal)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metric.radius
        // Clipped, so that while the region slides in from zero height its
        // content grows into view rather than hanging below the card's edge.
        layer?.masksToBounds = true
        primary.target = self
        primary.action = #selector(act)
        proseButton.target = self
        proseButton.action = #selector(actProse)
        secondaryButton.target = self
        secondaryButton.action = #selector(actSecondary)
        tertiaryButton.target = self
        tertiaryButton.action = #selector(actTertiary)

        gutterBox.translatesAutoresizingMaskIntoConstraints = false
        for indicator in [dot, spinner, icon] { gutterBox.addSubview(indicator) }

        // **Plain constraints, not a stack.** In a horizontal stack the
        // content sized to its own text and no hugging priority would make it
        // fill, so "Disconnect on the trailing edge" came out as "Disconnect
        // beside the headline" — which reads as part of it. Pinning the
        // content's trailing edge to the card's says it once and cannot be
        // argued with.
        addSubview(gutterBox)
        addSubview(content)

        // Held, because Idle sets every one of them to zero: a container with
        // its padding still in place is a 36 pt empty card.
        padding = [
            gutterBox.topAnchor.constraint(equalTo: topAnchor, constant: Metric.padding),
            gutterBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metric.padding),
        ]

        NSLayoutConstraint.activate(
            padding + [
                content.topAnchor.constraint(equalTo: gutterBox.topAnchor),
                content.leadingAnchor.constraint(
                    equalTo: gutterBox.trailingAnchor, constant: Metric.gutterGap),
                gutterBox.widthAnchor.constraint(equalToConstant: Metric.gutter),
                dot.widthAnchor.constraint(equalToConstant: Metric.dot),
                dot.heightAnchor.constraint(equalToConstant: Metric.dot),
                // Optically centred against a cap-height line rather than
                // hung from the top of it, which the artboard does with a
                // 4 pt nudge inside a 2 pt inset.
                dot.topAnchor.constraint(equalTo: gutterBox.topAnchor, constant: 6),
                dot.centerXAnchor.constraint(equalTo: gutterBox.centerXAnchor),
                spinner.topAnchor.constraint(equalTo: gutterBox.topAnchor, constant: 2),
                spinner.centerXAnchor.constraint(equalTo: gutterBox.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: Metric.icon),
                icon.heightAnchor.constraint(equalToConstant: Metric.icon),
                icon.topAnchor.constraint(equalTo: gutterBox.topAnchor, constant: 2),
                icon.centerXAnchor.constraint(equalTo: gutterBox.centerXAnchor),
                gutterBox.heightAnchor.constraint(greaterThanOrEqualToConstant: Metric.icon + 2),
                primary.widthAnchor.constraint(
                    greaterThanOrEqualToConstant: Metric.cancelWidth),
                shortForm.widthAnchor.constraint(equalTo: content.widthAnchor),
                proseForm.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        showNothing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateLayer() {
        // Drawn here rather than set once, so it follows a theme change.
        layer?.backgroundColor = isEmpty ? nil : Palette.surfaceCard.cgColor
        layer?.borderColor = Palette.border.cgColor
        layer?.borderWidth = isEmpty ? 0 : 1
        dot.layer?.backgroundColor = Palette.stateConnected.cgColor
    }

    // MARK: - The gutter

    private enum Indicator {
        case none
        case connected
        case busy
        case warning(NSColor)
    }

    private func gutter(_ indicator: Indicator) {
        dot.isHidden = true
        icon.isHidden = true
        if case .busy = indicator {} else { spinner.stopAnimation(nil) }

        switch indicator {
        case .none:
            break
        case .connected:
            dot.isHidden = false
        case .busy:
            // **Untinted, and that is a departure.** The Setup artboard draws
            // its spinner in the accent colour; `NSProgressIndicator` has no
            // tint, and the alternatives are a layer filter or a hand-drawn
            // spinner — both worse than the system's own, which animates
            // correctly, respects Reduce Motion and matches every other
            // spinner on the Mac. Setup still carries the accent, on its
            // default button.
            spinner.startAnimation(nil)
        case .warning(let colour):
            icon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            icon.contentTintColor = colour
            icon.isHidden = false
        }
    }

    // MARK: - The connection states

    /// `name` is what to call the profile this region is about — for a switch,
    /// the one being connected *to*. `switchingFrom` names the one coming
    /// down, which the artboard puts on the third line.
    /// What this Mac's network looks like, when the app has been told. Set
    /// rather than passed, because it belongs to none of the four `show`
    /// signatures and changes on its own schedule: exactly one failure
    /// message asks it anything (feature-spec 4.11).
    var facts: NetworkFacts?

    func show(
        _ connection: Connection, name: String, switchingFrom: String? = nil,
        at now: Date = Date()
    ) {
        isEmpty = false
        needsDisplay = true
        for constraint in padding { constraint.constant = 0 }
        padding[0].constant = Metric.padding
        padding[1].constant = Metric.padding
        padding[2].constant = -Metric.padding
        padding[3].constant = -Metric.padding

        shortForm.isHidden = false
        proseForm.isHidden = true
        nameLabel.isHidden = false
        nameLabel.stringValue = name
        clockLabel.isHidden = false
        primary.isHidden = false
        causesHeading.isHidden = true
        causesList.isHidden = true
        changedHeading.isHidden = true
        changedBody.isHidden = true
        secondaryButton.isHidden = true
        tertiaryButton.isHidden = true

        switch connection {
        case .connecting(let attempt), .reconnecting(let attempt):
            gutter(.busy)
            stateLabel.stringValue = connection.stateLine(at: now)
            // "elapsed", from the artboard: a bare number beside a state
            // reads as part of the state.
            let seconds = Int(attempt.elapsed(at: now).components.seconds)
            clockLabel.stringValue = String(
                localized: "\(seconds / 60):\(String(format: "%02d", seconds % 60)) elapsed")
            // **Cancel, not Disconnect.** Nothing is up to disconnect, and an
            // aborted attempt restores as completely as a clean one (D77).
            width(primary, Metric.cancelWidth)
            label(primary, String(localized: "Cancel"), keyEquivalent: "\u{1b}") { [weak self] in
                self?.onCancel?()
            }

        case .connected:
            gutter(.connected)
            stateLabel.stringValue = String(localized: "Connected")
            clockLabel.stringValue = connection.clock(at: now)
            // No confirmation, and no setting for one (D74): reversible,
            // one click, unmistakable.
            width(primary, Metric.disconnectWidth)
            label(primary, String(localized: "Disconnect"), keyEquivalent: "") { [weak self] in
                self?.onDisconnect?()
            }

        case .disconnecting(let teardown):
            gutter(.busy)
            stateLabel.stringValue = connection.stateLine(at: now)
            clockLabel.stringValue =
                switchingFrom.map { String(localized: "Disconnecting from \($0) first") } ?? ""
            clockLabel.isHidden = clockLabel.stringValue.isEmpty
            if teardown.isSwitch {
                width(primary, Metric.cancelWidth)
                label(primary, String(localized: "Cancel"), keyEquivalent: "\u{1b}") {
                    [weak self] in self?.onCancel?()
                }
            } else {
                primary.isHidden = true
            }

        case .failed(let record):
            // The name is already in the title — "Couldn't connect to X" —
            // and A10's copy rule puts it there on purpose (rule 2).
            gutter(.warning(Palette.stateFailed))
            shortForm.isHidden = true
            proseForm.isHidden = false
            // A7's four parts (D81), from A10's set.
            let message = FailureCopy.message(record, name: name, facts: facts, comparison: comparison)
            proseTitle.stringValue = message.title
            proseBody.stringValue = message.body
            proseBody.isHidden = false
            show(causes: message.causes)
            show(changed: message.whatChanged)
            // Try again is the default button, so it is the blue one the
            // artboard draws. **Show details is deliberately absent until
            // M6.5**: the diagnostics sheet it opens does not exist yet, and an
            // enabled control with nothing behind it is A13a's own named
            // anti-pattern.
            label(proseButton, String(localized: "Try Again"), keyEquivalent: "\r") { [weak self] in
                self?.onRetry?()
            }
            proseAction = primaryAction
            // Show details first, always (D50) — the sheet exists now — then a
            // remedy that lives elsewhere, when the message has one.
            for (button, action) in zip([secondaryButton, tertiaryButton], message.actions) {
                button.isHidden = false
                button.title = Self.title(of: action)
                button.keyEquivalent = ""
                let run: () -> Void = { [weak self] in self?.perform(action) }
                if button === secondaryButton { secondaryAction = run } else { tertiaryAction = run }
            }

        case .disconnected:
            showNothing()
        }
    }

    /// Idle: nothing is promoted because nothing is happening, and **the
    /// region takes no space at all** — no card, no border, no padding. The
    /// grid is the content (A12's Idle, and the Main artboard has no container
    /// in it).
    func showNothing() {
        isEmpty = true
        needsDisplay = true
        shortForm.isHidden = true
        proseForm.isHidden = true
        gutter(.none)
        for constraint in padding { constraint.constant = 0 }
    }

    /// Setup and Blocked: the region carries the guidance, and **the reason is
    /// stated once here rather than repeated on every card** (D116).
    func show(
        guidance content: (title: String, body: String, action: (title: String, run: () -> Void)?),
        blocked: Bool, emphasis: String? = nil
    ) {
        isEmpty = false
        needsDisplay = true
        padding[0].constant = Metric.padding
        padding[1].constant = Metric.padding
        padding[2].constant = -Metric.padding
        padding[3].constant = -Metric.padding
        shortForm.isHidden = true
        proseForm.isHidden = false
        // Blocked is a warning — something is wrong and connecting will not
        // work. Setup is in progress, and the artboard spins for it.
        gutter(blocked ? .warning(Palette.stateWarning) : .busy)
        proseTitle.stringValue = content.title
        if let emphasis, let range = content.body.range(of: emphasis) {
            // "…this window will notice" — the Setup artboard's one bold
            // phrase, because it is a promise (D153).
            let text = NSMutableAttributedString(
                string: content.body,
                attributes: [.font: Type.body, .foregroundColor: Palette.textSecondary])
            text.addAttributes(
                [.font: Type.bodyEmphasis, .foregroundColor: Palette.textPrimary],
                range: NSRange(range, in: content.body))
            proseBody.attributedStringValue = text
        } else {
            proseBody.stringValue = content.body
        }
        proseBody.isHidden = false
        causesHeading.isHidden = true
        causesList.isHidden = true
        changedHeading.isHidden = true
        changedBody.isHidden = true
        secondaryButton.isHidden = true
        tertiaryButton.isHidden = true
        if let action = content.action {
            // Blocked's *Continue setup* is the accent button: it is the way
            // forward. Setup's *Open System Settings again* is a plain one —
            // the way forward is in System Settings, not here (the artboards).
            label(proseButton, action.title, keyEquivalent: blocked ? "\r" : "", run: action.run)
            proseAction = primaryAction
        } else {
            proseButton.isHidden = true
        }
    }

    /// **Prose wraps to the width it has, never to a constant** (D157, D314).
    /// A fixed `preferredMaxLayoutWidth` of 560 made every wrapping label
    /// claim 560 pt, and with the paddings that became a 666 pt floor under
    /// the window — in every language, because the constant was the same in
    /// all of them. The width is read after layout and fed back, and the
    /// labels yield horizontally so the window, not the text, decides.
    override func layout() {
        super.layout()
        let width = content.bounds.width
        guard width > 0 else { return }
        var changed = false
        let labels = [proseTitle, proseBody, changedBody] + causesList.views.compactMap { $0 as? NSTextField }
        for label in labels where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            changed = true
        }
        if changed { super.layout() }
    }

    private func width(_ button: NSButton, _ value: CGFloat) {
        button.setContentHuggingPriority(.required, for: .horizontal)
        for constraint in button.constraints where constraint.firstAttribute == .width {
            constraint.constant = value
        }
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
    @objc private func actProse() { proseAction?() }
    @objc private func actSecondary() { secondaryAction?() }
    @objc private func actTertiary() { tertiaryAction?() }

    /// *Common causes*: A7's third part, as the artboard's bulleted list.
    private func show(causes: [String]) {
        causesList.views.forEach { $0.removeFromSuperview() }
        guard !causes.isEmpty else { return }
        for cause in causes {
            let line = NSTextField.label(
                font: Type.body, colour: Palette.textSecondary, truncation: .byWordWrapping)
            line.stringValue = "· " + cause
            line.preferredMaxLayoutWidth = 560
            causesList.addArrangedSubview(line)
        }
        causesHeading.isHidden = false
        causesList.isHidden = false
    }

    /// *What changed since it last worked*: A7's fourth part (D46).
    private func show(changed: String?) {
        guard let changed else { return }
        changedBody.stringValue = changed
        changedHeading.isHidden = false
        changedBody.isHidden = false
    }

    private static func title(of action: FailureMessage.SecondaryAction) -> String {
        switch action {
        case .showDetails: String(localized: "Show Details")
        case .openDateAndTime: String(localized: "Open Date & Time")
        }
    }

    private func perform(_ action: FailureMessage.SecondaryAction) {
        switch action {
        case .showDetails:
            onShowDetails?()
        case .openDateAndTime:
            // The remedy lives in System Settings, so that is where the button
            // goes.
            if let url = URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
