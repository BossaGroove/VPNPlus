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

/// A11's type scale.
///
/// **Every one of these is a macOS text style, and none of them is a point
/// size.** That single decision carries the user's accessibility text-size
/// setting, correct per-language metrics for six languages, and Dynamic
/// Type-like scaling — which is most of commitment 5, obtained by not doing
/// anything clever. A2 found Tunnelblick's fixed 9- and 10-point text; the way
/// not to build that is to have no numbers here to get wrong.
enum Type {
    /// The connection state in the promoted region — the J1 answer.
    ///
    /// **Semibold**, from the artboard: at regular weight 22 pt reads as a
    /// heading rather than as the answer to a question.
    static var stateTitle: NSFont { semibold(.title1) }
    /// The title of a promoted region that carries prose — Failed, Blocked,
    /// Setup. Smaller than `stateTitle` on purpose: those states have a body
    /// paragraph under them, and a 22 pt line above a paragraph is a banner.
    static var promotedProse: NSFont { semibold(.title3) }
    /// A label over a block inside prose — "Common causes".
    static var proseLabel: NSFont { semibold(.subheadline) }

    /// A sheet's own title — the profile it is about. 14 pt semibold in the
    /// artboard's 50 pt header bar: enough to say where you are, and not a
    /// headline competing with the values below it.
    static var sheetTitle: NSFont { semibold(.body) }
    /// A section heading inside a sheet — "Profile", "Server", "Sign-in".
    /// Small and heavy, from the artboard: it separates groups without
    /// competing with the values in them.
    static var sectionLabel: NSFont { semibold(.subheadline) }
    /// A field's own label, **above** the field. Regular weight against
    /// `sectionLabel`'s bold, which is what keeps the two apart.
    static var fieldLabel: NSFont { .preferredFont(forTextStyle: .subheadline) }

    private static func semibold(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }
    /// Failure message titles.
    static var sectionTitle: NSFont { .preferredFont(forTextStyle: .title3) }
    /// Message bodies, descriptions.
    static var body: NSFont { .preferredFont(forTextStyle: .body) }
    /// One phrase in a body that is a promise (the Setup artboard's *this
    /// window will notice*).
    static var bodyEmphasis: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
    }
    /// Buttons and fields.
    static var control: NSFont { .preferredFont(forTextStyle: .body) }
    /// The selected item in a sidebar (Settings).
    static var controlEmphasis: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
    }
    /// A profile name on a card.
    static var cardTitle: NSFont { .preferredFont(forTextStyle: .headline) }
    /// Host, last-connected, elapsed.
    static var caption: NSFont { .preferredFont(forTextStyle: .subheadline) }
    /// **An annotation on a control**, one step below a caption.
    ///
    /// Its own style because a hint that shares a label's must be told apart
    /// some other way, and there was no other way — the owner could not
    /// separate "Port" from the line under it when both were secondary grey
    /// at the same size (D248). Size, not contrast: still a text style, so it
    /// scales, and it keeps a label's colour rather than fading out.
    static var hint: NSFont { .preferredFont(forTextStyle: .footnote) }
    /// A message sheet's title — "Remove “Work”?", "This profile needs a file
    /// that isn't here". 15 pt semibold, from the three M5.10 artboards; the
    /// same weight as a promoted region's prose title, because it does the
    /// same job over a paragraph.
    static var messageTitle: NSFont { semibold(.title3) }
    /// The small text of a report: a change row, a "kept" list, the footnote
    /// under a message. 12 pt — one step under `body`, one over `hint`.
    static var detail: NSFont { .preferredFont(forTextStyle: .callout) }
    /// The new value in a before → after row: `detail` at medium weight,
    /// from the ReplaceFile artboard, so the eye lands on what is true now.
    static var detailEmphasis: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
    }
    /// A name from a file, inline in prose — `ca.crt`, `.ovpn`, a directive.
    /// Monospaced at `detail`'s size so it sits in a sentence rather than
    /// jumping out of one.
    static var code: NSFont {
        .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    }
    /// **The log, and nothing else.** A step below the sheet's title, as the
    /// Diagnostics artboard draws it: many lines that are scanned, not read.
    static var mono: NSFont {
        .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    }

    /// A number that ticks, in the size it would otherwise have been.
    ///
    /// Elapsed times and attempt counts change while you are reading them, and
    /// proportional digits make the whole line jitter as they do. This is the
    /// same style with the digits held still.
    static func ticking(_ font: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
    }
}

/// A11's 4 pt grid. Generous by default (commitment 5): A2 found Tunnelblick
/// simultaneously cramped and empty, because its space was allocated by
/// template rather than by need.
enum Space {
    /// Within a control.
    static let xs: CGFloat = 4
    /// Label to control.
    static let s: CGFloat = 8
    /// Between related rows.
    static let m: CGFloat = 12
    /// Card padding; between groups.
    static let l: CGFloat = 16
    /// Between regions.
    static let xl: CGFloat = 24
    /// Around the promoted region.
    static let xxl: CGFloat = 32

    /// Comfortable, not compact: nothing you can hit is shorter than this.
    static let hitTarget: CGFloat = 28
    /// The window's own margin, and the gap between its two zones. 20 rather
    /// than `xl` or `xxl` because that is what every artboard uses — 24 left
    /// the grid narrower than three columns need, and 32 above it put the
    /// promoted region adrift.
    static let gutter: CGFloat = 20
}

/// A11's semantic colours.
///
/// **No literal colour appears in layout code.** That is how light and dark,
/// Increase Contrast and Reduce Transparency stay correct without a second
/// implementation — and why there is no in-app theme picker (macOS has one).
///
/// Two rules that matter more than the palette:
///
/// - **The accent is the user's own** (`controlAccentColor`), whatever they
///   chose in System Settings. OpenVPN Connect paints its own blue everywhere,
///   and on a Mac that reads as a website.
/// - **Never colour alone.** Every state carries shape *and* colour *and*
///   text, which is what colour-blind users need and what makes the
///   monochrome status icon possible at all (D94).
enum Palette {
    static var textPrimary: NSColor { .labelColor }
    static var textSecondary: NSColor { .secondaryLabelColor }
    static var textTertiary: NSColor { .tertiaryLabelColor }

    static var surfaceWindow: NSColor { .windowBackgroundColor }
    static var surfaceCard: NSColor { .controlBackgroundColor }
    static var surfaceSelected: NSColor { .selectedContentBackgroundColor }
    /// A grouped card's fill — **lighter than whatever it sits on**, which is
    /// how System Settings raises a group off the window.
    ///
    /// `controlBackgroundColor` goes the other way in dark mode: it measured
    /// 30 against a 46 window, so the card read as a recess rather than a
    /// raised group. The dark value is the owner's, picked by eye against the
    /// sheet (2026-09-08); light mode gets white, which is what System
    /// Settings uses on its grey window. Dynamic rather than a constant,
    /// because a constant that suits dark mode is near-black in light.
    static var surfaceGrouped: NSColor {
        NSColor(name: "surfaceGrouped") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 52 / 255, green: 51 / 255, blue: 52 / 255, alpha: 1)
                : .white
        }
    }
    static var border: NSColor { .separatorColor }

    static var accent: NSColor { .controlAccentColor }

    static var stateConnected: NSColor { .systemGreen }
    static var stateFailed: NSColor { .systemRed }
    static var stateBusy: NSColor { .secondaryLabelColor }
    static var stateWarning: NSColor { .systemOrange }
    /// The one button that cannot be undone — Remove. The system's red, as
    /// the RemoveConfirm artboard has it, and never anywhere else.
    static var destructive: NSColor { .systemRed }
}

extension NSTextField {
    /// A label that does not steal the click meant for whatever is under it.
    ///
    /// The card's body click selects (D57), and a label on top of it that
    /// swallows the event turns a card into A1's dead card — the thing D55
    /// calls a trap rather than a neutral choice.
    static func label(
        _ text: String = "",
        font: NSFont,
        colour: NSColor,
        truncation: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = truncation
        field.usesSingleLineMode = truncation != .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
