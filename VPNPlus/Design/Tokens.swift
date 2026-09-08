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
    /// Buttons and fields.
    static var control: NSFont { .preferredFont(forTextStyle: .body) }
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
    /// **The log, and nothing else.**
    static var mono: NSFont {
        .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
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
    static var border: NSColor { .separatorColor }

    static var accent: NSColor { .controlAccentColor }

    static var stateConnected: NSColor { .systemGreen }
    static var stateFailed: NSColor { .systemRed }
    static var stateBusy: NSColor { .secondaryLabelColor }
    static var stateWarning: NSColor { .systemOrange }
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
