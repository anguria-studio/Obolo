import AppKit
import SwiftUI

/// A display-only rendition of a downloaded logo for a calendar cell.
struct CalendarLogo {
    struct Canvas: Hashable {
        let background: Color.Resolved
        let prefersDarkVariant: Bool
    }

    enum Treatment: Equatable {
        case mark
        case tile
        case needsBacking
    }

    let image: NSImage
    let treatment: Treatment

    init(_ original: NSImage, on background: Color.Resolved) {
        guard let pixels = LogoPixels(original) else {
            image = original
            treatment = .needsBacking
            return
        }

        if pixels.hasClearMargins {
            if let mark = pixels.readableMark(on: background) {
                image = mark
                treatment = .mark
            } else {
                image = original
                treatment = .needsBacking
            }
        } else if pixels.removeWhiteBackdrop(), let mark = pixels.readableMark(on: background) {
            image = mark
            treatment = .mark
        } else {
            image = original
            treatment = .tile
        }
    }

    /// Representative surfaces for fetching. Calendar rendering uses the actual cell fill.
    static var darkReference: Color.Resolved { .init(red: 0.14, green: 0.14, blue: 0.15) }
    static var lightReference: Color.Resolved { .init(red: 0.95, green: 0.95, blue: 0.96) }

    /// A site-provided mark with enough contrast on the requested surface, or in
    /// either appearance when choosing an icon from the site's general links.
    static func isClearMark(_ image: NSImage, on background: Color.Resolved? = nil) -> Bool {
        guard let pixels = LogoPixels(image), pixels.hasClearMargins else { return false }
        if let background { return pixels.readableBounds(on: background) != nil }
        return pixels.readableBounds(on: darkReference) != nil || pixels.readableBounds(on: lightReference) != nil
    }
}

private struct LogoPixels {
    private let bitmap: NSBitmapImageRep
    private let bytes: UnsafeMutablePointer<UInt8>
    private let width: Int
    private let height: Int
    private var count: Int { width * height }

    init?(_ image: NSImage) {
        // 96 pixels leaves room to trim padding and still draw sharp at 22 points.
        guard let bitmap = LogoImage.bitmap(from: image, maxDimension: 96),
              let bytes = bitmap.bitmapData else { return nil }
        self.bitmap = bitmap
        self.bytes = bytes
        width = bitmap.pixelsWide
        height = bitmap.pixelsHigh
    }

    private func offset(_ pixel: Int) -> Int {
        (pixel / width) * bitmap.bytesPerRow + (pixel % width) * 4
    }

    private func isClear(_ pixel: Int) -> Bool {
        bytes[offset(pixel) + 3] < 24
    }

    /// Inspect the middle of each edge. Transparent corners alone can belong to a
    /// rounded app tile. Transparent padding inside the canvas also counts.
    var hasClearMargins: Bool {
        var inspected = 0
        var clear = 0
        for y in 0..<height {
            for x in 0..<width where (x >= width / 4 && x < width - width / 4)
                || (y >= height / 4 && y < height - height / 4) {
                inspected += 1
                if isClear(y * width + x) { clear += 1 }
            }
        }
        return clear * 6 >= inspected
    }

    private func isWhite(_ pixel: Int) -> Bool {
        let i = offset(pixel)
        let low = min(bytes[i], bytes[i + 1], bytes[i + 2])
        let high = max(bytes[i], bytes[i + 1], bytes[i + 2])
        let alpha = Int(bytes[i + 3])
        return alpha >= 24 && Int(low) * 255 >= alpha * 239 && Int(high - low) * 255 <= alpha * 10
    }

    /// Remove a near-white matte only if it surrounds a substantial mark. Fill from
    /// the perimeter so enclosed white details survive. Colored tiles and gradients
    /// that reach the perimeter keep their source appearance.
    func removeWhiteBackdrop() -> Bool {
        var visited = Array(repeating: false, count: count)
        var region: [Int] = []

        func visit(_ pixel: Int) {
            guard !visited[pixel], isClear(pixel) || isWhite(pixel) else { return }
            visited[pixel] = true
            region.append(pixel)
        }

        func seed(_ pixel: Int) -> Bool {
            visit(pixel)
            return visited[pixel]
        }

        for x in 0..<width {
            guard seed(x), seed((height - 1) * width + x) else { return false }
        }
        for y in 0..<height {
            guard seed(y * width), seed(y * width + width - 1) else { return false }
        }

        var cursor = 0
        var backdropPixels = 0
        while cursor < region.count {
            let pixel = region[cursor]
            if isWhite(pixel) { backdropPixels += 1 }
            if pixel % width > 0 { visit(pixel - 1) }
            if pixel % width < width - 1 { visit(pixel + 1) }
            if pixel >= width { visit(pixel - width) }
            if pixel < count - width { visit(pixel + width) }
            cursor += 1
        }

        guard backdropPixels * 3 >= count, (count - region.count) * 12 >= count else { return false }
        for pixel in region {
            let i = offset(pixel)
            bytes[i] = 0
            bytes[i + 1] = 0
            bytes[i + 2] = 0
            bytes[i + 3] = 0
        }
        return true
    }

    private static let linearColor = (0...255).map { value in
        let component = Double(value) / 255
        return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    func readableBounds(on background: Color.Resolved) -> CGRect? {
        let backgroundLuminance = 0.2126 * Double(background.linearRed)
            + 0.7152 * Double(background.linearGreen) + 0.0722 * Double(background.linearBlue)
        let backgroundRed = Double(background.red) * 255
        let backgroundGreen = Double(background.green) * 255
        let backgroundBlue = Double(background.blue) * 255
        var left = width, right = -1, top = height, bottom = -1
        var solid = 0
        var readable = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = offset(y * width + x)
                let alpha = bytes[i + 3]
                guard alpha >= 32 else { continue }
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
                guard alpha >= 200 else { continue }
                solid += 1
                // The bitmap channels already include alpha. Blend in the uncovered
                // part of the cell before comparing luminance.
                let uncovered = Double(255 - alpha) / 255
                let red = Double(bytes[i]) + backgroundRed * uncovered
                let green = Double(bytes[i + 1]) + backgroundGreen * uncovered
                let blue = Double(bytes[i + 2]) + backgroundBlue * uncovered
                let luminance = 0.2126 * Self.linearComponent(red)
                    + 0.7152 * Self.linearComponent(green) + 0.0722 * Self.linearComponent(blue)
                let contrast = (max(luminance, backgroundLuminance) + 0.05)
                    / (min(luminance, backgroundLuminance) + 0.05)
                // On a pale cell, vivid marks also stand out by hue. Near-white
                // marks still need the stronger luminance difference.
                let channelSpread = max(red, green, blue) - min(red, green, blue)
                let hasColorContrast = backgroundLuminance > 0.5 && channelSpread >= 64
                let minimumContrast = hasColorContrast ? 1.8 : 2.5
                if contrast >= minimumContrast { readable += 1 }
            }
        }
        guard solid > 0, readable * 2 >= solid else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private static func linearComponent(_ byte: Double) -> Double {
        linearColor[min(255, max(0, Int(byte.rounded())))]
    }

    func readableMark(on background: Color.Resolved) -> NSImage? {
        guard let bounds = readableBounds(on: background),
              let cropped = bitmap.cgImage?.cropping(to: bounds) else { return nil }
        return NSImage(cgImage: cropped, size: bounds.size)
    }
}
