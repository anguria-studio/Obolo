import AppKit
import Foundation
import Testing

@Suite("Logo images")
struct LogoImageTests {
    /// A 16 × 16 SVG, the size 1Password declares for its dark icon.
    private let smallSVG = Data(#"""
    <svg width="16" height="16" xmlns="http://www.w3.org/2000/svg"><circle cx="8" cy="8" r="8" fill="#fff"/></svg>
    """#.utf8)

    @Test("A small SVG counts as scalable, not too small")
    func vectorIsLargeEnough() throws {
        let side = try #require(LogoImage.largestSide(ofData: smallSVG))
        #expect(side >= LogoStore.minimumDimension)
    }

    @Test("A vector is drawn at the largest kept size")
    func vectorRendersSharp() throws {
        let image = try #require(NSImage(data: smallSVG))
        let png = try #require(LogoImage.png(from: image, maxDimension: LogoStore.maximumDimension))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == Int(LogoStore.maximumDimension))
        #expect(rep.pixelsHigh == Int(LogoStore.maximumDimension))
    }

    @Test("A bitmap is never scaled up")
    func bitmapStaysItsSize() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(rep)
        #expect(LogoImage.largestSide(of: image) == 32)
        let png = try #require(LogoImage.png(from: image, maxDimension: LogoStore.maximumDimension))
        #expect(NSBitmapImageRep(data: png)?.pixelsWide == 32)
    }

    @Test("The calendar trims an existing transparent margin")
    func clearMark() throws {
        let original = try #require(NSImage(data: svg(mark)))
        let logo = CalendarLogo(original, on: darkCanvas.background)
        #expect(CalendarLogo.isClearMark(original))
        #expect(logo.treatment == .mark)
        #expect(logo.image.size.width < 96)
        #expect(logo.image.size.height < 96)
    }

    @Test("A light matte is removed without taking enclosed white detail with it")
    func whiteBackdrop() throws {
        let original = try #require(NSImage(data: svg(whiteTile + mark)))
        #expect(!CalendarLogo.isClearMark(original))
        let logo = CalendarLogo(original, on: darkCanvas.background)
        #expect(logo.treatment == .mark)
        let bitmap = try #require(LogoImage.bitmap(from: logo.image, maxDimension: 96))
        let corner = try #require(bitmap.colorAt(x: 0, y: 0))
        let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(corner.alphaComponent < 0.1)
        #expect(center.alphaComponent == 1)
        #expect(center.redComponent > 0.98)
    }

    @Test("Colored tiles keep their baked background and dark glyphs get a backing")
    func preservesSourceAndContrast() throws {
        let tile = try #require(NSImage(data: svg(##"<rect width="96" height="96" rx="15" fill="#b82544"/>"## + mark)))
        #expect(!CalendarLogo.isClearMark(tile))
        #expect(CalendarLogo(tile, on: darkCanvas.background).treatment == .tile)
        #expect(CalendarLogo(tile, on: lightCanvas.background).treatment == .tile)

        let dark = try #require(NSImage(data: svg(darkMark)))
        let darkOnWhite = try #require(NSImage(data: svg(whiteTile + darkMark)))
        let light = try #require(NSImage(data: svg(lightMark)))

        #expect(CalendarLogo.isClearMark(dark))
        #expect(!CalendarLogo.isClearMark(dark, on: darkCanvas.background))
        #expect(CalendarLogo(dark, on: darkCanvas.background).treatment == .needsBacking)
        #expect(CalendarLogo(dark, on: lightCanvas.background).treatment == .mark)
        #expect(CalendarLogo(darkOnWhite, on: darkCanvas.background).treatment == .tile)
        #expect(CalendarLogo(darkOnWhite, on: lightCanvas.background).treatment == .mark)
        #expect(CalendarLogo(light, on: darkCanvas.background).treatment == .mark)
        #expect(CalendarLogo(light, on: lightCanvas.background).treatment == .needsBacking)
    }

    @Test("Light shows vivid marks directly and gives pale marks a backing")
    func lightColorContrast() throws {
        let blueMark = lightMark.replacingOccurrences(of: "white", with: "#64bdf9")
        let paleMark = lightMark.replacingOccurrences(of: "white", with: "#e6f4fa")
        let blue = try #require(NSImage(data: svg(whiteTile + blueMark)))
        let pale = try #require(NSImage(data: svg(paleMark)))
        #expect(CalendarLogo(blue, on: lightCanvas.background).treatment == .mark)
        #expect(CalendarLogo(pale, on: lightCanvas.background).treatment == .needsBacking)
    }

    @MainActor
    @Test("The calendar cache refreshes when original or dark logo files change")
    func storeKeepsOriginalAndRefreshesCalendarVariant() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LogoStore(directory: directory)
        let id = UUID()
        let filename = try store.store(imageData: svg(whiteTile + mark), for: id)
        let url = directory.appending(path: filename)
        let stored = try Data(contentsOf: url)

        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .mark)
        #expect(try Data(contentsOf: url) == stored)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [filename])

        let tile = svg(##"<rect width="96" height="96" fill="#b82544"/>"## + mark)
        try store.storeDark(imageData: tile, besideLogo: filename)
        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .mark)
        try store.store(imageData: tile, for: id)
        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .tile)
        try store.storeDark(imageData: svg(mark), besideLogo: filename)
        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .mark)
        store.delete(filename: filename)
        #expect(store.calendarLogo(named: filename, on: darkCanvas) == nil)
    }

    @MainActor
    @Test("Switching appearance selects the appropriate logo without reusing the other rendition")
    func storeSelectsThemedVariant() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LogoStore(directory: directory)
        let id = UUID()
        let filename = try store.store(imageData: svg(lightMark), for: id)
        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .mark)
        #expect(store.calendarLogo(named: filename, on: lightCanvas)?.treatment == .needsBacking)

        try store.store(imageData: svg(darkMark), for: id)
        try store.storeDark(imageData: svg(lightMark), besideLogo: filename)
        #expect(store.calendarLogo(named: filename, on: darkCanvas)?.treatment == .mark)
        #expect(store.calendarLogo(named: filename, on: lightCanvas)?.treatment == .mark)
    }

    private func svg(_ body: String) -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"96\">\(body)</svg>".utf8)
    }

    private var mark: String {
        ##"<circle cx="45" cy="49" r="29" fill="#489df8"/><circle cx="45" cy="49" r="9" fill="white"/>"##
    }

    private var whiteTile: String {
        #"<rect width="96" height="96" rx="15" fill="white"/>"#
    }

    private var darkMark: String {
        ##"<circle cx="48" cy="48" r="28" fill="#121212"/>"##
    }

    private var lightMark: String {
        #"<circle cx="48" cy="48" r="28" fill="white"/>"#
    }

    private var darkCanvas: CalendarLogo.Canvas {
        .init(background: CalendarLogo.darkReference, prefersDarkVariant: true)
    }

    private var lightCanvas: CalendarLogo.Canvas {
        .init(background: CalendarLogo.lightReference, prefersDarkVariant: false)
    }
}
