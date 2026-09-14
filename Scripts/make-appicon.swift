#!/usr/bin/env swift
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

/// Draws the app icon and writes every size the asset catalog asks for.
///
///     swift Scripts/make-appicon.swift [output-directory]
///
/// **The icon is source, not a binary someone once exported.** Every size is
/// drawn from this geometry at its own resolution rather than resampled from
/// a big one, so the mark stays crisp at 16 pt, and a change to the blue or
/// the arm weight is a line here rather than a round trip through a drawing
/// tool.
///
/// The mark is a plus — the product's name, and the only shape in the set
/// that cannot be misread at any size. The ground is light, which is how it
/// is found in a Dock of dark tiles.

import AppKit

// MARK: - The design

enum Design {
    /// Apple's icon canvas is 1024 with the body inset — the margin is where
    /// the system's own shadow and hover effects live.
    static let bodyFraction: CGFloat = 824.0 / 1024.0

    /// The superellipse exponent that matches macOS's icon shape. A rounded
    /// rectangle is visibly not it at large sizes.
    static let squircleExponent: CGFloat = 5

    /// Proportions of the body, from the approved direction: the arms are 18%
    /// of the body thick and span 58% of it.
    static let armThickness: CGFloat = 0.18
    static let armSpan: CGFloat = 0.58

    static let groundTop = NSColor(srgbRed: 0.969, green: 0.973, blue: 0.984, alpha: 1)
    static let groundBottom = NSColor(srgbRed: 0.867, green: 0.890, blue: 0.933, alpha: 1)
    static let markTop = NSColor(srgbRed: 0.235, green: 0.408, blue: 0.910, alpha: 1)
    static let markBottom = NSColor(srgbRed: 0.110, green: 0.224, blue: 0.651, alpha: 1)

    /// Below this pixel size the sheen, the hairline and the shadow are more
    /// mud than modelling, so the small slots get the mark and nothing else.
    static let detailFloor: CGFloat = 64
}

// MARK: - Geometry

/// The superellipse |x|^n + |y|^n = 1, sampled densely enough that the
/// straight segments between samples are far below one pixel at 1024.
func squircle(in rect: CGRect, exponent n: CGFloat, samples: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    let rx = rect.width / 2, ry = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0..<samples {
        let t = (CGFloat(i) / CGFloat(samples)) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// The plus: two rounded bars, crossed. Drawn as one path so the gradient
/// runs through the whole mark rather than restarting on each bar.
func plus(in body: CGRect) -> CGPath {
    let thickness = body.width * Design.armThickness
    let span = body.width * Design.armSpan
    let radius = thickness / 2
    let vertical = CGRect(
        x: body.midX - thickness / 2, y: body.midY - span / 2, width: thickness, height: span)
    let horizontal = CGRect(
        x: body.midX - span / 2, y: body.midY - thickness / 2, width: span, height: thickness)
    let path = CGMutablePath()
    path.addPath(CGPath(roundedRect: vertical, cornerWidth: radius, cornerHeight: radius, transform: nil))
    path.addPath(CGPath(roundedRect: horizontal, cornerWidth: radius, cornerHeight: radius, transform: nil))
    return path
}

// MARK: - Drawing

func drawIcon(size: CGFloat) -> CGImage {
    let pixels = Int(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not make a \(pixels)×\(pixels) context") }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let inset = size * (1 - Design.bodyFraction) / 2
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = squircle(in: body, exponent: Design.squircleExponent)
    let detailed = size >= Design.detailFloor

    /// `first` lands on the start point, `second` on the end point — the
    /// order the call sites read in.
    func gradient(_ first: NSColor, _ second: NSColor) -> CGGradient {
        CGGradient(
            colorsSpace: space, colors: [first.cgColor, second.cgColor] as CFArray,
            locations: [0, 1])!
    }

    // The body's own shadow. A light tile on a light desktop needs an edge,
    // and the system does not draw one for us.
    if detailed {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.022,
            color: NSColor(white: 0, alpha: 0.20).cgColor)
        context.addPath(shape)
        context.setFillColor(NSColor.white.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    // Ground.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient(Design.groundTop, Design.groundBottom),
        start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY),
        options: [])
    context.restoreGState()

    // The mark.
    let mark = plus(in: body)
    context.saveGState()
    context.addPath(mark)
    context.clip()
    context.drawLinearGradient(
        gradient(Design.markTop, Design.markBottom),
        start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY),
        options: [])
    context.restoreGState()

    if detailed {
        // A sliver of light down the vertical arm: the bar reads as formed
        // rather than printed. Invisible by 32 pt, which is why it stops.
        let thickness = body.width * Design.armThickness
        let span = body.width * Design.armSpan
        let sheen = CGRect(
            x: body.midX - thickness / 4, y: body.midY - span / 2 + thickness * 0.28,
            width: thickness / 2, height: span - thickness * 0.56)
        context.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
        context.addPath(
            CGPath(
                roundedRect: sheen, cornerWidth: sheen.width / 2, cornerHeight: sheen.width / 2,
                transform: nil))
        context.fillPath()

        // A hairline along the edge, so the tile keeps its shape on white.
        context.addPath(shape)
        context.setStrokeColor(NSColor(white: 0, alpha: 0.10).cgColor)
        context.setLineWidth(max(1, size * 0.0015))
        context.strokePath()
    }

    guard let image = context.makeImage() else { fatalError("could not render \(pixels)") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("could not open \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

// MARK: - The asset catalog

/// Every slot macOS asks a Mac app for, as (point size, scale).
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let arguments = CommandLine.arguments
let directory = URL(
    fileURLWithPath: arguments.count > 1
        ? arguments[1] : "VPNPlus/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

var entries: [String] = []
var drawn: [Int: CGImage] = [:]
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    let image = drawn[pixels] ?? drawIcon(size: CGFloat(pixels))
    drawn[pixels] = image
    write(image, to: directory.appendingPathComponent(name))
    entries.append(
        """
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.points)x\(slot.points)"
            }
        """)
    print("  \(name)  \(pixels)×\(pixels)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "make-appicon.swift",
    "version" : 1
  }
}

"""
try! contents.write(
    to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(slots.count) slots to \(directory.path)")
