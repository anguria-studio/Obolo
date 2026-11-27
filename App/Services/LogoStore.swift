import AppKit
import Foundation
import Observation
import OSLog
import OboloCore

/// The folder of logo files, and the only thing that writes to it.
///
/// `Icon.image` names a *file*, not a path, and this is what turns one into the other:
/// `Application Support/Obolo/Icons/<subscription-uuid>.png`, inside the shared App
/// Group container, beside the store document it belongs to. Naming a file after the
/// subscription rather than after the domain means re-fetching replaces rather than
/// accumulates, and deleting a subscription has exactly one file to delete.
///
/// Everything that arrives — fetched, dropped, chosen in an open panel — goes through
/// `store(imageData:for:)`, which re-encodes it as a PNG no larger than 256 pixels. A
/// 900 KB Apple touch icon is not worth carrying around to draw at 22 points, and a
/// document whose icons folder is bigger than a photo library is a bug report waiting
/// to happen.
@MainActor
@Observable
final class LogoStore {

    /// One per process. `IconInitial` draws in a dozen places and has no model to reach
    /// through, and there is only ever one icons folder anyway.
    static let shared = LogoStore()

    /// The largest side a stored logo is kept at, in pixels. 256 covers the Detail's
    /// 52-point icon at 2× (104 pixels; a Mac has no 3× display) with room to spare.
    nonisolated static let maximumDimension: CGFloat = 256

    /// Below this an "icon" is a tracking pixel, a spacer GIF, or a 16-pixel favicon
    /// that would be a smear in an All row.
    nonisolated static let minimumDimension = 24

    private(set) var directory: URL

    /// Decoded images, by filename. A list of forty rows asks for the same handful of
    /// files on every scroll pass.
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var calendarCache: [String: [CalendarLogo.Canvas: CalendarLogo]] = [:]

    /// Bumped whenever a file is written or removed.
    ///
    /// Read by `image(named:)`, which is what makes the observation work: the filename
    /// in `Icon.image` does not change when a logo is re-fetched, so without something
    /// observable moving underneath it, a view that already drew the old file would have
    /// no reason to draw the new one.
    private(set) var revision = 0

    init(directory: URL? = nil) {
        self.directory = directory ?? LogoStore.defaultDirectory
    }

    static func configureSharedDirectory(_ directory: URL) {
        guard shared.directory != directory else { return }
        shared.directory = directory
        shared.cache.removeAll()
        shared.darkCache.removeAll()
        shared.calendarCache.removeAll()
        shared.revision += 1
    }

    /// The isolated fallback for tests and previews. The production app configures the
    /// shared instance with `AppPaths` before it creates `AppModel`.
    static var defaultDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support
            .appending(path: DocumentStore.directoryName, directoryHint: .isDirectory)
            .appending(path: "Icons", directoryHint: .isDirectory)
    }

    // MARK: - Containment
    //
    // `Icon.image` carries a filename out of the store document, and a store document is
    // not trusted input: it can be hand-edited, restored from somewhere else, or written
    // by a build that had a bug. A row naming `image:../obolo.json` must not let a
    // delete take the document with it, so every read, write and delete below resolves
    // its path through `containedURL(for:)` and does nothing at all when it says no.

    /// Where a fault is written when a filename fails either test. A fault rather than an
    /// error: nothing in normal use produces one, so one in the log is a bug or an
    /// attempt at something.
    private static let log = Logger(subsystem: "studio.anguria.obolo", category: "LogoStore")

    /// The file this filename names, or `nil` when it names something outside the Icons
    /// folder.
    ///
    /// Two tests, both of which have to pass. `Icon.isValidImageFilename` rejects the
    /// shapes a filename must never have — a separator, a `..`, an empty string. The
    /// prefix check is the backstop: whatever the first test let through, the resolved
    /// path still has to be inside the folder this store owns.
    private func containedURL(for filename: String) -> URL? {
        guard Icon.isValidImageFilename(filename) else {
            Self.log.fault("Rejected a logo filename that is not a plain file name.")
            return nil
        }
        let candidate = directory
            .appending(path: filename, directoryHint: .notDirectory)
            .standardizedFileURL
        var folder = directory.standardizedFileURL.path(percentEncoded: false)
        if !folder.hasSuffix("/") { folder += "/" }
        guard candidate.path(percentEncoded: false).hasPrefix(folder) else {
            Self.log.fault("Rejected a logo path that resolves outside the Icons folder.")
            return nil
        }
        return candidate
    }

    // MARK: - Reading

    /// The logo, or `nil` when the file is missing — which is a normal state, not an
    /// error: a document restored from a backup names files this Mac has never had. A
    /// rejected filename answers the same way, so `IconInitial` draws the initial.
    func image(named filename: String) -> NSImage? {
        _ = revision
        if let cached = cache[filename] { return cached }
        guard let url = containedURL(for: filename), let image = NSImage(contentsOf: url) else { return nil }
        cache[filename] = image
        return image
    }

    /// Cache the rendition for each cell fill and appearance. A theme change can
    /// select a different variant and make a previously legible mark need backing.
    func calendarLogo(named filename: String, on canvas: CalendarLogo.Canvas) -> CalendarLogo? {
        _ = revision
        if let cached = calendarCache[filename]?[canvas] { return cached }

        let dark = canvas.prefersDarkVariant
            ? darkImage(for: filename).map { CalendarLogo($0, on: canvas.background) }
            : nil
        if let dark, dark.treatment == .mark {
            calendarCache[filename, default: [:]][canvas] = dark
            return dark
        }

        let regular = image(named: filename).map { CalendarLogo($0, on: canvas.background) }
        let selected = regular?.treatment == .mark ? regular : dark ?? regular
        if let selected { calendarCache[filename, default: [:]][canvas] = selected }
        return selected
    }

    // MARK: - Dark variants

    /// The file a logo's dark-mode version is kept in, beside it: `<id>.png` →
    /// `<id>-dark.png`. Only the site's own dark icon ever lands there (see
    /// `LogoFetcher.fetchWithDarkVariant`); most logos have none.
    nonisolated static func darkFilename(for filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return "\(stem)-dark.png"
    }

    /// The dark version's file, beside a logo this store would accept. The logo's own
    /// name is what is checked — the strict `<UUID>.png` rule still guards every name a
    /// document can carry — and the dark name is derived from it, never read from one.
    private func darkURL(besideLogo filename: String) -> URL? {
        guard containedURL(for: filename) != nil else { return nil }
        return directory.appending(path: Self.darkFilename(for: filename), directoryHint: .notDirectory)
    }

    /// Dark versions looked up so far, including the ones that are not there, so a
    /// missing file is not asked for again on every draw.
    @ObservationIgnored private var darkCache: [String: NSImage?] = [:]

    /// The site's own dark-mode version of a logo, or `nil` when it has none.
    func darkImage(for filename: String) -> NSImage? {
        _ = revision
        let dark = Self.darkFilename(for: filename)
        if let cached = darkCache[dark] { return cached }
        let image = darkURL(besideLogo: filename).flatMap { NSImage(contentsOf: $0) }
        darkCache[dark] = .some(image)
        return image
    }

    /// Writes a dark-mode version beside the logo `filename` names.
    func storeDark(imageData: Data, besideLogo filename: String) throws {
        let png = try encoded(imageData)
        guard let url = darkURL(besideLogo: filename) else { throw StoreError.couldNotEncode }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url, options: [.atomic])
        darkCache[Self.darkFilename(for: filename)] = NSImage(data: png)
        calendarCache[filename] = nil
        revision += 1
    }

    /// Removes a logo's dark-mode version, if it has one.
    private func deleteDark(besideLogo filename: String) {
        let dark = Self.darkFilename(for: filename)
        darkCache[dark] = nil
        calendarCache[filename] = nil
        if let url = darkURL(besideLogo: filename) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Writing

    enum StoreError: LocalizedError {
        case notAnImage
        case tooSmall(Int)
        case couldNotEncode

        var errorDescription: String? {
            switch self {
            case .notAnImage: "Obolo cannot read that file as an image."
            case .tooSmall(let side): "That image is only \(side) pixels wide. It is too small to use as a logo."
            case .couldNotEncode: "Obolo cannot convert that image to a PNG."
            }
        }
    }

    /// Writes `imageData` as `<subscriptionID>.png` and returns the filename to put in
    /// `Icon.image`.
    ///
    /// Rejects anything whose larger side is under 24 pixels, which is the whole of the
    /// quality bar: a favicon that small is what a site serves when it does not really
    /// have one, and drawing it stretched looks worse than the letter it replaced.
    @discardableResult
    func store(imageData: Data, for subscriptionID: UUID) throws -> String {
        try write(encoded(imageData), for: subscriptionID)
    }

    /// A logo that arrived through iCloud, from a fetch on another Mac. Answers whether
    /// it was written.
    ///
    /// iCloud carries the logo but not its dark version, and it carries the logo again
    /// with every change to the subscription, a new price as much as a new logo. So the
    /// image already on disk is left as it is, with its dark version beside it. Only a
    /// different one is written, through the same door as `store`, which removes the old
    /// logo's dark version; then `logoDidArrive` is told, so the new logo's dark version
    /// can be fetched on this Mac.
    @discardableResult
    func storeArrived(imageData: Data, for subscriptionID: UUID) throws -> Bool {
        let png = try encoded(imageData)
        let filename = Self.filename(for: subscriptionID)
        // The bytes as they came, or as this store wrote them the last time they came:
        // either way the same image.
        if let current = containedURL(for: filename).flatMap({ try? Data(contentsOf: $0) }),
           current == png || current == imageData {
            return false
        }
        _ = try write(png, for: subscriptionID)
        logoDidArrive?(subscriptionID)
        return true
    }

    /// Told the subscription's id when `storeArrived` writes a new logo. `AppModel` sets
    /// it, and fetches the dark version.
    @ObservationIgnored var logoDidArrive: (@MainActor (UUID) -> Void)?

    /// The bytes as the PNG a logo file holds: no larger than 256 pixels, and refused
    /// below 24.
    private func encoded(_ imageData: Data) throws -> Data {
        guard let image = NSImage(data: imageData) else { throw StoreError.notAnImage }
        let side = LogoImage.largestSide(of: image)
        guard side >= LogoStore.minimumDimension else { throw StoreError.tooSmall(side) }
        guard let png = LogoImage.png(from: image, maxDimension: LogoStore.maximumDimension) else {
            throw StoreError.couldNotEncode
        }
        return png
    }

    private func write(_ png: Data, for subscriptionID: UUID) throws -> String {
        // The name is this store's own — a UUID and an extension — so the check below
        // cannot fail in practice. It runs anyway: one door, one rule, and a build that
        // ever changes the naming does not get to skip the test.
        let filename = Self.filename(for: subscriptionID)
        guard let url = containedURL(for: filename) else { throw StoreError.couldNotEncode }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: url, options: [.atomic])
        cache[filename] = NSImage(data: png)
        // A new logo may have no dark version; an old one must not linger beside it.
        deleteDark(besideLogo: filename)
        revision += 1
        return filename
    }

    /// The file a subscription's own logo is kept in: `<subscription-uuid>.png`.
    nonisolated static func filename(for subscriptionID: UUID) -> String {
        "\(subscriptionID.uuidString).png"
    }

    /// Copies the logo `filename` names, and its dark version if it has one, to the file
    /// of `subscriptionID`, and returns the new filename. `nil` when there is no file to
    /// copy. A duplicate gets its own file this way: sharing one would mean deleting
    /// either row took the other's logo with it.
    func copy(_ filename: String, to subscriptionID: UUID) -> String? {
        guard filename != Self.filename(for: subscriptionID),
              let source = containedURL(for: filename),
              let data = try? Data(contentsOf: source),
              let copied = try? store(imageData: data, for: subscriptionID)
        else { return nil }
        if let dark = darkURL(besideLogo: filename).flatMap({ try? Data(contentsOf: $0) }) {
            try? storeDark(imageData: dark, besideLogo: copied)
        }
        return copied
    }

    /// Removes one logo file. A filename this store will not touch is a no-op: nothing
    /// is deleted and the caches are left alone, because there is nothing of ours there.
    func delete(filename: String) {
        guard let url = containedURL(for: filename) else { return }
        cache[filename] = nil
        try? FileManager.default.removeItem(at: url)
        deleteDark(besideLogo: filename)
        revision += 1
    }
}

// MARK: - Pixels

/// The two image questions the store and the fetcher both ask. Not on `LogoStore`
/// because the fetcher runs off the main actor and only needs the arithmetic.
enum LogoImage {

    /// The larger side of the largest representation, in *pixels*.
    ///
    /// Representations, not `NSImage.size`: a `.ico` carries several images at once and
    /// `size` reports whichever one AppKit picked, so a file holding a 16 and a 256
    /// would be judged on the 16 and thrown away.
    static func largestSide(of image: NSImage) -> Int {
        // A vector (an SVG, a PDF) has no pixels and draws sharp at any size, however
        // small it says it is: 1Password's dark icon is a "16 × 16" SVG. It counts as
        // big as a logo is ever kept.
        if isVector(image) { return Int(LogoStore.maximumDimension) }
        return image.representations
            .map { max($0.pixelsWide, $0.pixelsHigh) }
            .max() ?? 0
    }

    /// Whether `image` is drawn from vectors alone: it has a size but no pixels.
    static func isVector(_ image: NSImage) -> Bool {
        !image.representations.isEmpty
            && image.representations.allSatisfy { $0.pixelsWide <= 0 && $0.pixelsHigh <= 0 }
            && image.size.width > 0 && image.size.height > 0
    }

    /// The same measurement, straight from bytes — what the fetcher scores candidates
    /// with before any of them is worth keeping.
    static func largestSide(ofData data: Data) -> Int? {
        guard let image = NSImage(data: data) else { return nil }
        let side = largestSide(of: image)
        return side > 0 ? side : nil
    }

    /// Re-encodes as a PNG, scaled down so neither side exceeds `maxDimension`, drawing
    /// from the largest representation the source had.
    static func png(from image: NSImage, maxDimension: CGFloat) -> Data? {
        bitmap(from: image, maxDimension: maxDimension)?.representation(using: .png, properties: [:])
    }

    /// Draws into an 8-bit, alpha-last RGBA bitmap. In-memory logo treatments can use
    /// this directly without encoding and decoding another PNG.
    static func bitmap(from image: NSImage, maxDimension: CGFloat) -> NSBitmapImageRep? {
        let vector = isVector(image)
        let sourceWidth = vector ? image.size.width
            : CGFloat(image.representations.map(\.pixelsWide).max() ?? Int(image.size.width))
        let sourceHeight = vector ? image.size.height
            : CGFloat(image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height))
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Pixels are only ever scaled down; a vector is drawn at the largest size kept.
        let fit = maxDimension / max(sourceWidth, sourceHeight)
        let scale = vector ? fit : min(1, fit)
        let width = max(1, Int((sourceWidth * scale).rounded()))
        let height = max(1, Int((sourceHeight * scale).rounded()))

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [],
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        target.size = NSSize(width: width, height: height)

        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return target
    }
}
