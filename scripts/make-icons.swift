#!/usr/bin/env swift
//
// Generates the 18pt menu-bar icon from three solid isometric slabs.
// The 2:1 proportions keep diagonals crisp, with
// 1.4pt knocked-out gaps between them; the top slab at full opacity, the middle at 75%,
// the base at 55%. It is a template image, so macOS tints it black or white with the
// menu bar and the alpha steps carry through.
// The app icon itself is compiled directly from App/Resources/AppIcon.icon.
//
// Run with: swift scripts/make-icons.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appending(path: "App/Resources/Assets.xcassets")
let menuBarSet = assets.appending(path: "MenuBarIcon.imageset")

let fm = FileManager.default
for directory in [assets, menuBarSet] {
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
}

// MARK: - Geometry (18 × 18 points, y down)

/// A slab whose top face starts at `y`, `thickness` deep: the hexagon
/// (2, y+3) (9, y) (16, y+3) (16, y+3+t) (9, y+6+t) (2, y+3+t).
func slab(y: CGFloat, thickness t: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [
        CGPoint(x: 2, y: y + 3), CGPoint(x: 9, y: y), CGPoint(x: 16, y: y + 3),
        CGPoint(x: 16, y: y + 3 + t), CGPoint(x: 9, y: y + 6 + t), CGPoint(x: 2, y: y + 3 + t),
    ])
    path.closeSubpath()
    return path
}

let top = slab(y: 1.0, thickness: 1.8)
let middle = slab(y: 4.6, thickness: 1.8)
let base = slab(y: 8.2, thickness: 3.2)
/// The gap between slabs: each slab above is cleared with a 2.8pt round-joined stroke,
/// so 1.4pt beyond its edge.
let gap: CGFloat = 1.4

// MARK: - Render

let side = 18

for scale in [1, 2] {
    let pixels = side * scale
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(1) }

    // Points, y down.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    context.setShouldAntialias(true)

    /// Draws `shape` at `alpha` on its own layer, with each of `above` cleared from it
    /// along with a `gap`-wide margin.
    func draw(_ shape: CGPath, clearing above: [CGPath]) {
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(shape)
        context.fillPath()
        context.setBlendMode(.clear)
        context.setLineJoin(.round)
        context.setLineWidth(gap * 2)
        for path in above {
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
    }

    // Each slab on its own layer, then composited at its opacity.
    for (shape, alpha, above) in [
        (base, CGFloat(0.55), [top, middle]),
        (middle, CGFloat(0.75), [top]),
        (top, CGFloat(1.0), []),
    ] {
        context.saveGState()
        context.setAlpha(alpha)
        draw(shape, clearing: above)
        context.restoreGState()
    }

    guard let image = context.makeImage() else { exit(1) }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: side, height: side)
    guard let data = representation.representation(using: .png, properties: [:]) else { exit(1) }
    let name = scale == 1 ? "menubar.png" : "menubar@2x.png"
    try data.write(to: menuBarSet.appending(path: name))
}

let menuBarContents = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "filename" : "menubar.png" },
    { "idiom" : "mac", "scale" : "2x", "filename" : "menubar@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

"""
try menuBarContents.write(
    to: menuBarSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8
)

let assetsContents = """
{
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try assetsContents.write(
    to: assets.appending(path: "Contents.json"), atomically: true, encoding: .utf8
)

print("Wrote \(menuBarSet.path)")
