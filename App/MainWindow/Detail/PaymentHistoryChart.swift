import SwiftUI
import OboloCore

// The detail's payment history uses one of three drawings: year trays
// (a 4 × 3 tray of months per year) for a recent monthly plan, a
// year strip (a cell per year) for a plan billed once a year or less often, and coin
// columns (a stack of plates per year) for everything else. Every tray stands on
// Home's floor: a dashed `lineStrong` outline.

// `DetailChartKind` and `DetailHistory`, the rule and the data, live in OboloCore.

// MARK: - The scene

/// Boxes and outlines in isometric space, drawn in painter's order.
///
/// True 30° isometric, as Home's IsoStack and the app icon: screen x = (x − y)·cos 30,
/// screen y = (x + y)·0.5 − z.
struct IsoScene {
    enum Style: Equatable { case paid, next, toCome, floor, frame }

    struct Prism {
        var x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat, z: CGFloat, h: CGFloat
        var style: Style
        var id: Date?
        /// When it starts to build, in seconds from the build's start, and for how long.
        var delay: Double = 0
        var duration: Double = IsoScene.blockDuration
    }

    struct Outline {
        var rect: CGRect
        var delay: Double = 0
    }

    struct Label {
        var text: String
        var at: CGPoint
        var delay: Double = 0
    }

    /// Floor rectangles at z = 0: Home's floor, a dashed `lineStrong` outline.
    var outlines: [Outline] = []
    /// Solid `line` rules on the floor between a strip's cells.
    var dividers: [(from: CGPoint, to: CGPoint)] = []
    /// In painter's order.
    var prisms: [Prism] = []
    /// Year labels, hanging below a point in screen space (design units).
    var labels: [Label] = []

    var hasNext: Bool { prisms.contains { $0.style == .next } }

    // MARK: Build timing

    /// Outlines, floor tiles, frames and labels fade in over this.
    static let fadeDuration: Double = 0.4
    /// A block drops 22pt into place over this.
    static let blockDuration: Double = 0.55
    /// The next payment lands last, more slowly.
    static let nextDuration: Double = 0.7
    static let dropDistance: CGFloat = 22

    /// 0 before `delay`, 1 once `duration` has passed after it.
    static func progress(elapsed: Double, delay: Double, duration: Double) -> Double {
        guard duration > 0 else { return elapsed >= delay ? 1 : 0 }
        return min(1, max(0, (elapsed - delay) / duration))
    }

    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    /// Every block that isn't the next payment is placed; then the next one lands, 0.1 s
    /// after the last of them, over 0.7 s.
    mutating func landNextLast() {
        let others = prisms.filter { $0.style != .next && $0.id != nil }.map(\.delay).max() ?? 0
        for index in prisms.indices where prisms[index].style == .next {
            prisms[index].delay = others + 0.1
            prisms[index].duration = Self.nextDuration
        }
    }

    /// When the next payment has landed, and its breathing can start.
    var nextLandsAt: Double {
        prisms.filter { $0.style == .next }.map { $0.delay + $0.duration }.max() ?? 0
    }

    /// When everything is in place.
    var buildDuration: Double {
        let blocks = prisms.map { $0.delay + $0.duration }
        let fades = (outlines.map(\.delay) + labels.map(\.delay)).map { $0 + Self.fadeDuration }
        return (blocks + fades).max() ?? 0
    }

    // The chart colours adapt to the theme. The next payment uses the same orange in both.
    private static func color(_ hex: UInt32) -> Color { Color(hex: hex) }
    private static let paidTop = Color(dark: 0x5C5C61, light: 0xE2E2E7)
    private static let paidLeft = Color(dark: 0x2C2C2F, light: 0xB3B3BA)
    private static let paidRight = Color(dark: 0x3E3E42, light: 0xC9C9CF)
    private static let paidEdge = Color(dark: 0x808086, light: 0xA6A6AE)
    /// The legend's Paid square: a paid block's top.
    static let paidSwatch = paidTop
    private static let nextTop = color(0xF2703A), nextLeft = color(0x8F4322), nextRight = color(0xB8552C), nextEdge = color(0xFFA47C)
    /// Still to come this year: diagonal stripes in a solid outline.
    static let stripe = Color(dark: 0x77777D, light: 0xA6A6AE)
    static let toComeEdge = Color(dark: 0x3A3A3E, light: 0xD4D4DA)
    private static let floorTile = Color(dark: 0x232325, light: 0xEEEEF1)
    private static let frameEdge = Color(dark: 0x2F2F31, light: 0xD4D4DA)
    private static let labelInk = Color(dark: 0x6B6B70, light: 0x6B6B73)
    /// The most a drawing is enlarged to fill its space.
    private static let maxScale: CGFloat = 1.4
    /// Room under the drawing for the year labels.
    private static let labelRoom: CGFloat = 14
    /// Air above and below the drawing, so blocks never touch the header or the legend.
    private static let verticalAir: CGFloat = 8

    private static let cos30 = cos(CGFloat.pi / 6)

    static func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: (x - y) * cos30, y: (x + y) * 0.5 - z)
    }

    // MARK: Fit

    /// Aspect-fit into the space the card gives, centred, the labels below.
    struct Fit {
        let scale: CGFloat
        let dx: CGFloat
        let dy: CGFloat
        func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + dx, y: p.y * scale + dy) }
    }

    func fit(in size: CGSize) -> Fit {
        var points: [CGPoint] = labels.map(\.at)
        for rect in outlines.map(\.rect) {
            points += [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY)]
                .map { Self.project($0.0, $0.1, 0) }
        }
        for prism in prisms { points += Self.corners(prism) }
        guard let first = points.first else { return Fit(scale: 1, dx: 0, dy: 0) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let width = max(1, maxX - minX), height = max(1, maxY - minY)
        let room = CGSize(width: size.width, height: max(1, size.height - Self.labelRoom - 2 * Self.verticalAir))
        // Capped so a lone tray doesn't zoom to twice the size of two side by side.
        let scale = min(room.width / width, room.height / height, Self.maxScale)
        return Fit(
            scale: scale,
            dx: (room.width - width * scale) / 2 - minX * scale,
            dy: Self.verticalAir + (room.height - height * scale) / 2 - minY * scale
        )
    }

    // MARK: Geometry

    private static func corners(_ p: Prism) -> [CGPoint] {
        [project(p.x, p.y, p.z), project(p.x + p.w, p.y, p.z), project(p.x + p.w, p.y + p.d, p.z), project(p.x, p.y + p.d, p.z),
         project(p.x, p.y, p.z + p.h), project(p.x + p.w, p.y, p.z + p.h), project(p.x + p.w, p.y + p.d, p.z + p.h), project(p.x, p.y + p.d, p.z + p.h)]
    }

    private static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// The outline a box makes on screen.
    private static func silhouette(_ p: Prism, _ fit: Fit) -> Path {
        let c = corners(p).map(fit.apply)
        // Top back, top right, bottom right, bottom front, bottom left, top left.
        return polygon([c[4], c[5], c[1], c[2], c[3], c[7]])
    }

    // MARK: Drawing

    /// Draws the scene `elapsed` seconds into its build: `.infinity` is fully built.
    func draw(
        _ context: inout GraphicsContext,
        fit: Fit,
        nextOpacity: Double,
        elapsed: Double = .infinity,
        hovered: Date? = nil
    ) {
        // The floor: Home's dashed outline, and solid rules between a strip's cells.
        for outline in outlines {
            let rect = outline.rect
            let corners = [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.maxY), (rect.minX, rect.maxY)]
                .map { fit.apply(Self.project($0.0, $0.1, 0)) }
            var layer = context
            layer.opacity = Self.progress(elapsed: elapsed, delay: outline.delay, duration: Self.fadeDuration)
            layer.stroke(
                Self.polygon(corners),
                with: .color(DS.Palette.lineStrong),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        }
        if !dividers.isEmpty {
            var rules = Path()
            for divider in dividers {
                rules.move(to: fit.apply(divider.from))
                rules.addLine(to: fit.apply(divider.to))
            }
            var layer = context
            layer.opacity = Self.progress(elapsed: elapsed, delay: 0, duration: Self.fadeDuration)
            layer.stroke(rules, with: .color(DS.Palette.line), lineWidth: 1)
        }

        for prism in prisms {
            let p = Self.progress(elapsed: elapsed, delay: prism.delay, duration: prism.duration)
            guard p > 0 else { continue }
            // Frames and floor tiles have no id, so they never light up.
            let isHovered = prism.id != nil && prism.id == hovered
            var context = context
            context.opacity = p
            // A block drops into place; the floor and frames only fade.
            if prism.id != nil, p < 1 {
                context.translateBy(x: 0, y: -Self.dropDistance * (1 - Self.easeOutCubic(p)))
            }
            let c = Self.corners(prism).map(fit.apply)
            let top = Self.polygon([c[4], c[5], c[6], c[7]])
            let left = Self.polygon([c[7], c[6], c[2], c[3]])
            let right = Self.polygon([c[5], c[6], c[2], c[1]])
            switch prism.style {
            case .floor:
                context.fill(top, with: .color(Self.floorTile))
            case .paid, .next:
                guard let look = Self.look(for: prism.style, isHovered: isHovered, nextOpacity: nextOpacity) else { break }
                var layer = context
                layer.opacity *= look.opacity
                layer.fill(left, with: .color(look.left))
                layer.fill(right, with: .color(look.right))
                layer.fill(top, with: .color(look.top))
                layer.stroke(top, with: .color(look.edge), lineWidth: look.edgeWidth)
            case .toCome:
                guard let look = Self.look(for: .toCome, isHovered: isHovered) else { break }
                // 1pt lines at 45°, 4pt apart, clipped to each face; the faces fade
                // from top to left so the block still reads as a solid.
                for (face, opacity) in [(left, 0.45), (right, 0.6), (top, 0.9)] {
                    var layer = context
                    layer.clip(to: face)
                    layer.opacity *= opacity
                    layer.stroke(Self.stripes(in: face.boundingRect, pitch: 4), with: .color(look.top), lineWidth: 1)
                }
                for face in [left, right, top] {
                    context.stroke(face, with: .color(look.edge), lineWidth: look.edgeWidth)
                }
            case .frame:
                var edges = Path()
                for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
                    edges.move(to: c[a]); edges.addLine(to: c[b])
                }
                context.stroke(edges, with: .color(Self.frameEdge), lineWidth: 1)
            }
        }

        for label in labels {
            let at = fit.apply(label.at)
            var context = context
            context.opacity = Self.progress(elapsed: elapsed, delay: label.delay, duration: Self.fadeDuration)
            context.draw(
                Text(label.text)
                    .font(DSFonts.font(DSFonts.monoRegular, size: 9))
                    .foregroundColor(Self.labelInk),
                at: CGPoint(x: at.x, y: at.y + 4),
                anchor: .top
            )
        }
    }

    /// A block's colours. For a toCome block, `top` is the stripe
    /// colour and `edge` its outline.
    struct Look: Equatable {
        var top: Color
        var left: Color
        var right: Color
        var edge: Color
        var edgeWidth: CGFloat
        var opacity: Double = 1
    }

    /// Under the pointer a paid block turns light in dark, and dark ink in light.
    static let hoverTop = Color(dark: 0xF2F2F0, light: 0x46464C)
    static let hoverRight = Color(dark: 0xCFCFCC, light: 0x2B2B30)
    static let hoverLeft = Color(dark: 0xA9A9A6, light: 0x0F0F11)
    static let hoverEdge = Color(dark: 0xFFFFFF, light: 0x141416)

    /// How a payment block is drawn, plain or under the pointer. Under the pointer a
    /// paid block turns light (dark ink in the light theme) but stays shaded; the next one stops breathing, solid at
    /// full opacity with a stronger edge; one still to come has its stripes and outline
    /// in `ink`. The change is instant, as every hover in the app. `nil` for the floor
    /// and the current-year frame, which are not payments.
    static func look(for style: Style, isHovered: Bool, nextOpacity: Double = 1) -> Look? {
        switch style {
        case .paid:
            return isHovered
                ? Look(top: hoverTop, left: hoverLeft, right: hoverRight, edge: hoverEdge, edgeWidth: 0.6)
                : Look(top: paidTop, left: paidLeft, right: paidRight, edge: paidEdge, edgeWidth: 0.6)
        case .next:
            return Look(
                top: nextTop, left: nextLeft, right: nextRight, edge: nextEdge,
                edgeWidth: isHovered ? 0.8 : 0.6,
                opacity: isHovered ? 1 : nextOpacity
            )
        case .toCome:
            let ink = isHovered ? DS.Palette.ink : stripe
            return Look(top: ink, left: ink, right: ink, edge: isHovered ? DS.Palette.ink : toComeEdge, edgeWidth: 0.8)
        case .floor, .frame:
            return nil
        }
    }

    /// Parallel lines across `rect`, `pitch` apart measured square to them: rising to
    /// the right at 45°, or falling to the right when `rising` is false (135°).
    static func stripes(in rect: CGRect, pitch: CGFloat, rising: Bool = true) -> Path {
        var path = Path()
        let step = pitch * 2.squareRoot()
        var t = -rect.height
        while t <= rect.width {
            if rising {
                path.move(to: CGPoint(x: rect.minX + t, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + t + rect.height, y: rect.minY))
            } else {
                path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + t + rect.height, y: rect.maxY))
            }
            t += step
        }
        return path
    }

    /// The payment under the pointer: the frontmost box that contains it.
    func hit(_ point: CGPoint, fit: Fit) -> Date? {
        for prism in prisms.reversed() {
            guard let id = prism.id else { continue }
            if Self.silhouette(prism, fit).contains(point) { return id }
        }
        return nil
    }

    // MARK: Year trays

    /// One tray per year, oldest on the left: Jan–Apr in the back row, May–Aug in the
    /// middle, Sep–Dec at the front. A month at the lowest price is an 8pt block; a
    /// dearer one stands taller, so a rise reads as a ridge.
    static func yearTrays(_ history: DetailHistory) -> IsoScene {
        let tile: CGFloat = 18, pitch: CGFloat = 23, inset: CGFloat = 4
        let trayWidth = 4 * pitch - (pitch - tile) + 2 * inset
        let trayDepth = 3 * pitch - (pitch - tile) + 2 * inset
        // Along (+x, −y): the trays sit side by side straight across the screen.
        let step = trayWidth + 4
        let lowest = history.items.map(\.amount).filter { $0 > 0 }.min() ?? 1

        func height(_ amount: Decimal) -> CGFloat {
            let ratio = CGFloat(NSDecimalNumber(decimal: amount / lowest).doubleValue)
            return min(40, 8 + (ratio - 1) * 7)
        }

        var scene = IsoScene()
        var tiles: [Prism] = []
        for (index, year) in history.years.enumerated() {
            let ox = CGFloat(index) * step, oy = -CGFloat(index) * step
            // Each tray builds 0.22 s after the one before: its floor fades in, then its
            // blocks drop in back to front.
            let trayDelay = Double(index) * 0.22
            scene.outlines.append(Outline(rect: CGRect(x: ox, y: oy, width: trayWidth, height: trayDepth), delay: trayDelay))
            var trayTiles: [Prism] = []
            for month in 1...12 {
                let x = ox + inset + CGFloat((month - 1) % 4) * pitch
                let y = oy + inset + CGFloat((month - 1) / 4) * pitch
                if let item = history.item(year: year, month: month) {
                    let style: Style = switch item.state {
                    case .paid: .paid
                    case .next: .next
                    case .toCome: .toCome
                    }
                    trayTiles.append(Prism(x: x, y: y, w: tile, d: tile, z: 0, h: height(item.amount), style: style, id: item.id))
                } else {
                    trayTiles.append(Prism(
                        x: x, y: y, w: tile, d: tile, z: 0, h: 0, style: .floor, id: nil,
                        delay: trayDelay, duration: fadeDuration
                    ))
                }
            }
            // Blocks drop in the tray's own draw order, 35 ms apart.
            var rank = 0
            for tileIndex in trayTiles.indices.sorted(by: { Self.paintsBefore(trayTiles[$0], trayTiles[$1]) })
            where trayTiles[tileIndex].id != nil {
                trayTiles[tileIndex].delay = 0.12 + trayDelay + Double(rank) * 0.035
                rank += 1
            }
            tiles += trayTiles
            let centre = project(ox + trayWidth / 2, oy + trayDepth / 2, 0)
            let front = project(ox + trayWidth, oy + trayDepth, 0)
            scene.labels.append(Label(text: String(year), at: CGPoint(x: centre.x, y: front.y), delay: trayDelay))
        }
        scene.prisms = tiles.sorted(by: paintsBefore)
        scene.landNextLast()
        return scene
    }

    /// Painter's order: back to front by (x + y), then y.
    static func paintsBefore(_ a: Prism, _ b: Prism) -> Bool {
        (a.x + a.y, a.y) < (b.x + b.y, b.y)
    }

    // MARK: Year strip

    /// One cell per year, a square 46 wide.
    static let stripCell: CGFloat = 46

    /// One 1 × N tray of year cells for a plan billed once a year or less often, the
    /// last eight years, oldest on the left. Each year with a
    /// payment holds one block, 9 in from every side, 16 tall plus up to 30 more for the
    /// dearest year, so it never grows past a small cube. A year with no payment (every
    /// two years) is an empty cell.
    static func yearStrip(_ history: DetailHistory) -> IsoScene {
        let cell = stripCell, inset: CGFloat = 9
        let years = Array(history.years.suffix(maxColumns))
        func total(_ year: Int) -> Decimal { history.items(in: year).reduce(Decimal(0)) { $0 + $1.amount } }
        let largest = years.map(total).max() ?? 0

        var scene = IsoScene()
        scene.outlines.append(Outline(rect: CGRect(x: 0, y: 0, width: CGFloat(years.count) * cell, height: cell)))
        for index in 1..<max(1, years.count) {
            let x = CGFloat(index) * cell
            scene.dividers.append((project(x, 0, 0), project(x, cell, 0)))
        }
        for (index, year) in years.enumerated() {
            let x = CGFloat(index) * cell
            if let item = history.items(in: year).last {
                let ratio = largest > 0 ? CGFloat(NSDecimalNumber(decimal: total(year) / largest).doubleValue) : 1
                let style: Style = switch item.state {
                case .paid: .paid
                case .next: .next
                case .toCome: .toCome
                }
                scene.prisms.append(Prism(
                    x: x + inset, y: inset, w: cell - 2 * inset, d: cell - 2 * inset, z: 0,
                    h: 16 + 30 * min(1, ratio), style: style, id: item.id,
                    delay: 0.15 + Double(index) * 0.12
                ))
            }
            // Under the cell's front-left edge.
            let edge = project(x + cell / 2, cell, 0)
            scene.labels.append(Label(text: String(year), at: edge))
        }
        scene.landNextLast()
        return scene
    }

    // MARK: Coin columns

    /// The most columns drawn; older years are counted under the list.
    static let maxColumns = 8

    /// One column per year, a plate per payment, bottom-up. The current year stands in a
    /// faint frame as tall as a full year at today's price.
    static func coinColumns(_ history: DetailHistory, subscription: Subscription) -> IsoScene {
        let footprint: CGFloat = 40, pitch: CGFloat = 60, gap: CGFloat = 1.5
        let perYear = max(1, subscription.cycle.paymentsPerYear)
        let fullYear = subscription.price * Decimal(perYear)
        let largestYear = history.years.map { year in history.items(in: year).reduce(Decimal(0)) { $0 + $1.amount } }.max() ?? 0
        let reference = max(largestYear, fullYear)
        let k = reference > 0 ? 140 / CGFloat(NSDecimalNumber(decimal: reference).doubleValue) : 1

        func thickness(_ amount: Decimal) -> CGFloat {
            max(1.6, CGFloat(NSDecimalNumber(decimal: amount).doubleValue) * k)
        }

        var scene = IsoScene()
        for (index, year) in history.years.suffix(maxColumns).enumerated() {
            let x = CGFloat(index) * pitch
            // Each column builds 0.18 s after the one before, its plates bottom-up.
            let columnDelay = Double(index) * 0.18
            scene.outlines.append(Outline(rect: CGRect(x: x, y: 0, width: footprint, height: footprint), delay: columnDelay))
            if year == history.currentYear {
                let height = CGFloat(NSDecimalNumber(decimal: fullYear).doubleValue) * k + CGFloat(Int(perYear.rounded(.up)) - 1) * gap
                scene.prisms.append(Prism(
                    x: x, y: 0, w: footprint, d: footprint, z: 0, h: height, style: .frame, id: nil,
                    delay: columnDelay, duration: fadeDuration
                ))
            }
            var z: CGFloat = 0
            for (plate, item) in history.items(in: year).enumerated() {
                let style: Style = switch item.state {
                case .paid: .paid
                case .next: .next
                case .toCome: .toCome
                }
                let t = thickness(item.amount)
                scene.prisms.append(Prism(
                    x: x, y: 0, w: footprint, d: footprint, z: z, h: t, style: style, id: item.id,
                    delay: 0.12 + columnDelay + Double(plate) * 0.03
                ))
                z += t + gap
            }
            let front = project(x + footprint, footprint, 0)
            let centre = project(x + footprint / 2, footprint / 2, 0)
            scene.labels.append(Label(text: String(year), at: CGPoint(x: centre.x, y: front.y), delay: columnDelay))
        }
        scene.landNextLast()
        return scene
    }
}

// MARK: - The view

/// Draws a scene, fitted to its space; the next payment breathes, hover reports the box
/// under the pointer.
///
/// The first time a window shows a detail chart, the blocks drop into place.
/// Floors and labels fade in, each block falls 22pt as it fades in, and the
/// next payment lands last, then starts to breathe. With Reduce Motion there is no
/// motion at all.
struct IsoHistoryCanvas: View {
    let scene: IsoScene
    @Binding var hovered: Date?
    let accessibilityText: String

    /// When the build started; `nil` when there is none to play.
    @State private var buildStart: Date?
    /// True while the build is running, so the clock runs only that long.
    @State private var isBuilding = false
    @State private var breathingSince = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.homeBuildLog) private var buildLog

    var body: some View {
        // The one loop: only while the window is key, and never with Reduce Motion.
        let breathes = scene.hasNext && !reduceMotion && activeState == .key
        GeometryReader { proxy in
            let fit = scene.fit(in: proxy.size)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !(isBuilding || breathes))) { context in
                let elapsed = buildStart.map { context.date.timeIntervalSince($0) } ?? .infinity
                // The breath starts once the next payment has landed; before that it is 1.
                let opacity = breathes ? Self.breath(at: max(0, context.date.timeIntervalSince(breathingSince))) : 1
                Canvas { graphics, _ in
                    scene.draw(&graphics, fit: fit, nextOpacity: opacity, elapsed: elapsed, hovered: hovered)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Gaps between boxes keep the last one, so the readout doesn't flicker.
                    if let id = scene.hit(location, fit: fit), id != hovered { hovered = id }
                case .ended:
                    hovered = nil
                }
            }
        }
        .onAppear(perform: startBuild)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Plays the build once per window, then hands the clock to the breathing.
    private func startBuild() {
        let now = Date()
        // Claimed with Reduce Motion too, so the build never plays later in this window.
        guard buildLog.claim(.detailChart), !reduceMotion else {
            buildStart = nil
            breathingSince = now
            return
        }
        buildStart = now
        breathingSince = now.addingTimeInterval(scene.nextLandsAt)
        isBuilding = true
        let duration = scene.buildDuration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            isBuilding = false
        }
    }

    /// 1 → 0.55 → 1 over 3.6 s.
    static func breath(at elapsed: TimeInterval) -> Double {
        let phase = elapsed.truncatingRemainder(dividingBy: 3.6) / 3.6
        return 1 - 0.45 * (0.5 - 0.5 * cos(2 * .pi * phase))
    }
}
