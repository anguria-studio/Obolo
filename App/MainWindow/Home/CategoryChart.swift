import SwiftUI
import OboloCore

/// Category view: the IsoStack beside the category list.
///
/// Hovering a slab or a row lifts that slab out of the stack, dims the rest and moves
/// the orange call-out to it. Clicking either opens the category's list, which is what
/// clicking a donut slice did before.
struct CategoryChart: View {
    let model: AppModel
    let ledger: Ledger

    @State private var hovered: OboloCore.Category.ID?
    /// The category whose slab was last hovered, so the list can scroll its row into view.
    @State private var slabHovered: OboloCore.Category.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currency: String { model.document.settings.baseCurrency }

    private var entries: [IsoStack.Entry] {
        let counts = Dictionary(
            grouping: ledger.summaries.filter(\.countsInTotals),
            by: \.category.id
        ).mapValues(\.count)
        return ledger.categoryTotals
            .filter { $0.monthly > 0 }
            .sorted { $0.monthly > $1.monthly }
            .map {
                IsoStack.Entry(
                    id: $0.category.id,
                    name: $0.category.name,
                    color: DS.category($0.category.tint),
                    monthly: $0.monthly,
                    share: $0.share,
                    count: counts[$0.category.id] ?? 0
                )
            }
    }

    var body: some View {
        let entries = entries
        if entries.isEmpty {
            HomeEmptyState(text: "Add a subscription to see where the money goes.")
        } else {
            HStack(spacing: 40) {
                IsoStack(entries: entries, hovered: $hovered, onSelect: open, onHoverSlab: { slabHovered = $0 })
                    .frame(width: 240, height: 216)

                list(entries)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            // Rows and slabs only ever *set* the hovered category; it clears when the
            // pointer leaves the whole chart. Clearing per row left a dead strip between
            // rows (and between lifted slabs) where the stack dropped back and jumped.
            .onHover { inside in if !inside { hovered = nil } }
            // A trackpad tick each time a slab or row takes over.
            .onChange(of: hovered) { _, id in if id != nil { Haptics.tick() } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: hovered)
        }
    }

    /// Every category, biggest first, scrolling in the stack's height. Hovering a slab
    /// scrolls its row into view.
    private func list(_ entries: [IsoStack.Entry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry).id(entry.id)
                    }
                }
                // The pills reach 8pt past the text column on both sides.
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.automatic)
            .dsScrollFade()
            .frame(maxHeight: 216)
            .onChange(of: slabHovered) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
        .padding(.horizontal, -8)
    }

    private func row(_ entry: IsoStack.Entry) -> some View {
        Button { open(entry.id) } label: {
            HStack(spacing: 10) {
                CategoryMarker(color: entry.color)
                Text(entry.name)
                    .dsStyle(.body)
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .frame(minWidth: FittingAmount.nameMinimumWidth, maxWidth: .infinity, alignment: .leading)
                // The amount is never cut: the name gives way to it, down to its minimum,
                // and then the amount drops its decimals.
                FittingAmount(value: entry.monthly, currency: currency)
                    .dsStyle(.data)
                    .foregroundStyle(DS.Palette.ink)
                    .layoutPriority(1)
                Text(SharePercent.text(entry.share))
                    .dsStyle(.data)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(hovered == entry.id ? DS.Palette.bg300 : .clear)
            )
            // The 4pt between rows belongs to the rows, so the pointer is always over
            // one of them.
            .padding(.vertical, 2)
            .opacity(hovered == nil || hovered == entry.id ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        .onHover { inside in
            if inside { hovered = entry.id }
        }
        .help("Show \(entry.name)")
        .accessibilityLabel("\(entry.name), \(MoneyFormatting.amount(entry.monthly, currency: currency)) a month, \(SharePercent.text(entry.share, spoken: true))")
    }

    private func open(_ id: OboloCore.Category.ID) {
        model.section = .category(id)
    }
}

// MARK: - IsoStack

/// Isometric slabs, one per category, stacked biggest first; height is the share.
///
/// Drawn in the design's own 300 × 270 coordinate space (viewBox `0 30 300 270`) and
/// scaled to the 240 × 216 frame, so the numbers below can be checked against the
/// prototype. Hairline edges in the category colour, faces at 20–38% of it, a floor
/// grid in `line`, and one orange call-out.
struct IsoStack: View {
    struct Entry: Identifiable {
        let id: OboloCore.Category.ID
        let name: String
        let color: Color
        let monthly: Decimal
        let share: Double
        let count: Int
    }

    let entries: [Entry]
    @Binding var hovered: OboloCore.Category.ID?
    let onSelect: (OboloCore.Category.ID) -> Void
    var onHoverSlab: (OboloCore.Category.ID) -> Void = { _ in }

    /// False until the stack has been built: each slab then drops 40 units into place,
    /// biggest first, 180 ms apart, and the call-out fades in once they have landed.
    @State private var built = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeBuildLog) private var buildLog

    /// Built already if this window has shown the stack before: then it appears whole.
    private var isBuilt: Bool { built || buildLog.hasPlayed(.category) }

    // Geometry, in design units.
    nonisolated private static let scale: CGFloat = 0.8
    nonisolated private static let originY: CGFloat = 30
    private static let centerX: CGFloat = 130
    /// The front-bottom vertex of the lowest slab.
    private static let baseY: CGFloat = 278
    /// Slab half-width and half-depth.
    private static let halfWidth: CGFloat = 76.2
    private static let halfDepth: CGFloat = 44
    /// The stack's height at 100%, and always its height: the slabs share it out.
    private static let stackHeight: CGFloat = 150
    /// A slab's height when its share would draw it thinner (see `slabHeights`).
    private static let minimumSlab: CGFloat = 2.5

    /// Nonisolated, so the floor's `Canvas` can draw with it.
    nonisolated private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: (y - originY) * scale)
    }

    /// Bottom vertex and height of each slab, in design units.
    private var slabs: [(entry: Entry, bottom: CGFloat, height: CGFloat)] { Self.layout(entries) }

    /// Bottom vertex and height of each slab, bottom slab first, in design units.
    static func layout(_ entries: [Entry]) -> [(entry: Entry, bottom: CGFloat, height: CGFloat)] {
        let heights = slabHeights(shares: entries.map(\.share), total: stackHeight, minimum: minimumSlab)
        var bottom = baseY
        return zip(entries, heights).map { entry, height in
            defer { bottom -= height }
            return (entry, bottom, height)
        }
    }

    /// A slab's six-sided outline in the view's points: front-bottom vertex, right,
    /// right top, back top, left top, left.
    static func outline(bottom b: CGFloat, height h: CGFloat) -> Path {
        let c = centerX, w = halfWidth, d = halfDepth
        let points = [CGPoint(x: c, y: b), CGPoint(x: c + w, y: b - d), CGPoint(x: c + w, y: b - d - h),
                      CGPoint(x: c, y: b - h - 2 * d), CGPoint(x: c - w, y: b - d - h), CGPoint(x: c - w, y: b - d)]
        var path = Path()
        path.addLines(points.map { point($0.x, $0.y) })
        path.closeSubpath()
        return path
    }

    /// The slab under `point` (in the view's points), top slab first, as the eye reads
    /// the stack. Outlines are taken at rest, with no hover lift or build offset, so the
    /// target doesn't move under a still pointer while the slabs lift.
    static func slabID(at point: CGPoint, in entries: [Entry]) -> OboloCore.Category.ID? {
        for slab in layout(entries).reversed() where outline(bottom: slab.bottom, height: slab.height).contains(point) {
            return slab.entry.id
        }
        return nil
    }

    /// The thinnest a slab can be with `count` slabs: `minimum`, unless that many
    /// minimums would take more than half of `total`; then the share of half of it.
    nonisolated static func slabFloor(count: Int, total: CGFloat, minimum: CGFloat) -> CGFloat {
        guard count > 0 else { return minimum }
        return min(minimum, total / 2 / CGFloat(count))
    }

    /// Each slab's height: its share of `total`, never under `slabFloor`, and together
    /// always `total`, so the stack stays in its frame however many categories it has.
    ///
    /// A slab raised to the floor takes that height from the others, in proportion to
    /// their shares; that can push another one under the floor, so this repeats until
    /// none changes. Shares that already fill the stack with no slab under the floor
    /// give `share × total` exactly, as before. A share of zero or less counts as zero.
    nonisolated static func slabHeights(shares: [Double], total: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty else { return [] }
        guard total > 0 else { return shares.map { _ in 0 } }
        let floor = slabFloor(count: shares.count, total: total, minimum: minimum)
        let weights = shares.map { CGFloat(max(0, $0)) }
        var atFloor = Array(repeating: false, count: shares.count)

        // The height a slab not at the floor gets, from what the floored ones leave.
        func heights() -> [CGFloat] {
            let free = weights.indices.filter { !atFloor[$0] }
            let freeWeight = free.reduce(CGFloat(0)) { $0 + weights[$1] }
            let room = total - floor * CGFloat(shares.count - free.count)
            let fillsStack = free.count == shares.count && abs(freeWeight - 1) < 1e-9
            return weights.indices.map { index in
                if atFloor[index] { return floor }
                if fillsStack { return weights[index] * total }
                if freeWeight > 0 { return weights[index] / freeWeight * room }
                return room / CGFloat(free.count)
            }
        }

        // The floors take at most half of `total`, so the slabs left free always have
        // room for more than the floor: at least one stays free and the loop ends.
        while true {
            let current = heights()
            let under = current.indices.filter { !atFloor[$0] && current[$0] < floor }
            if under.isEmpty { return current }
            for index in under { atFloor[index] = true }
        }
    }

    private var hoveredIndex: Int? {
        hovered.flatMap { id in entries.firstIndex { $0.id == id } }
    }

    var body: some View {
        let slabs = slabs
        ZStack(alignment: .topLeading) {
            floor

            ForEach(Array(slabs.enumerated()), id: \.element.entry.id) { index, slab in
                SlabView(color: slab.entry.color, bottom: slab.bottom, height: slab.height)
                    // Data changes: a slab that grows, shrinks or moves eases into place.
                    .animation(reduceMotion ? nil : DSMotion.easeOutCubic(0.6), value: slab.height)
                    .animation(reduceMotion ? nil : DSMotion.easeOutCubic(0.6), value: slab.bottom)
                    // Hover: 0.4 s to move, 0.25 s to dim.
                    .animation(reduceMotion ? nil : DSMotion.glide) {
                        $0.offset(y: lift(index) * Self.scale)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        $0.opacity(hoveredIndex == nil || hoveredIndex == index ? 1 : 0.3)
                    }
                    // Build: drop from 40 above, slow, no overshoot.
                    .offset(y: isBuilt ? 0 : -40 * Self.scale)
                    .opacity(isBuilt ? 1 : 0)
                    .animation(reduceMotion ? nil : DSMotion.settle.delay(0.18 * Double(index)), value: isBuilt)
                    // A category that appears later drops in on its own.
                    .transition(.opacity.combined(with: .offset(y: -40 * Self.scale)))
                    // Hover and taps go through the stack's hit test below: each slab is
                    // a full-frame layer, so the top one would take every event.
                    .allowsHitTesting(false)
            }

            callout(slabs)
                .opacity(isBuilt ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(1.8), value: isBuilt)
                .allowsHitTesting(false)
        }
        .frame(width: 240, height: 216, alignment: .topLeading)
        .contentShape(Rectangle())
        // One hover and one tap for the stack, through the slabs' outlines. Gaps keep
        // the last slab, as the detail charts do; leaving the chart clears it (outside).
        .onContinuousHover { phase in
            guard case .active(let location) = phase,
                  let id = Self.slabID(at: location, in: entries),
                  id != hovered
            else { return }
            hovered = id
            onHoverSlab(id)
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if let id = Self.slabID(at: value.location, in: entries) { onSelect(id) }
        })
        .animation(reduceMotion ? nil : DSMotion.easeOutCubic(0.6), value: entries.map(\.id))
        // Builds the first time this window shows the stack (see `HomeBuildLog`).
        .onAppear { if buildLog.claim(.category) { built = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The hovered slab rises 8; the ones above it 16, to open a gap.
    private func lift(_ index: Int) -> CGFloat {
        guard let hot = hoveredIndex else { return 0 }
        if index < hot { return 0 }
        return index == hot ? -8 : -16
    }

    private var accessibilityText: String {
        let parts = entries.prefix(3).map { "\($0.name) \(SharePercent.text($0.share, spoken: true))" }
        return "Monthly spend stacked by category: " + parts.joined(separator: ", ")
    }

    // MARK: Floor

    private var floor: some View {
        Canvas { context, _ in
            let top = CGPoint(x: 130, y: 174), right = CGPoint(x: 233.9, y: 234)
            let bottom = CGPoint(x: 130, y: 294), left = CGPoint(x: 26.1, y: 234)
            func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                Self.point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
            }
            var grid = Path()
            for step in 0...6 {
                let t = CGFloat(step) / 6
                grid.move(to: lerp(top, right, t)); grid.addLine(to: lerp(left, bottom, t))
                grid.move(to: lerp(top, left, t)); grid.addLine(to: lerp(right, bottom, t))
            }
            context.stroke(grid, with: .color(DS.Palette.line), lineWidth: 1)

            var outline = Path()
            outline.addLines([top, right, bottom, left].map { Self.point($0.x, $0.y) })
            outline.closeSubpath()
            context.stroke(outline, with: .color(DS.Palette.lineStrong), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
        .frame(width: 240, height: 216)
        .allowsHitTesting(false)
    }

    // MARK: Call-out

    /// The orange dot on the slab's right face with a dashed leader, and the number of
    /// subscriptions inside it: the one thing the list does not say. At rest it sits on
    /// the largest category; on hover it follows the lifted slab.
    @ViewBuilder
    private func callout(_ slabs: [(entry: Entry, bottom: CGFloat, height: CGFloat)]) -> some View {
        let index = hoveredIndex ?? 0
        if slabs.indices.contains(index) {
            let slab = slabs[index]
            // The right face's centre, in design units, following the slab's lift.
            let y = slab.bottom - Self.halfDepth / 2 - slab.height / 2 + lift(index)
            // Drawn with the leader's end at the top edge, then moved into place, so the
            // move is one animatable offset and the call-out glides between slabs.
            let dot = CGPoint(x: 168.1 * Self.scale, y: 24 * Self.scale)
            let elbow = CGPoint(x: 208.1 * Self.scale, y: 0)
            let end = CGPoint(x: 298 * Self.scale, y: 0)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: dot)
                    path.addLine(to: elbow)
                    path.addLine(to: end)
                }
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                Circle()
                    .fill(DS.Palette.accent)
                    .overlay(Circle().strokeBorder(DS.Palette.bg200, lineWidth: 2))
                    .frame(width: 11, height: 11)
                    .position(dot)

                Text("\(slab.entry.count) \(slab.entry.count == 1 ? "sub" : "subs")")
                    // The count swaps at once; only its position moves.
                    .contentTransition(.identity)
                    .font(DSFonts.font(DSFonts.monoMedium, size: 11))
                    .tracking(0.88)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Palette.ink)
                    .fixedSize()
                    .frame(width: end.x, alignment: .trailing)
                    .offset(y: -17)
            }
            .frame(width: 240, height: 216, alignment: .topLeading)
            // One motion for every reason the call-out moves (hover, a slab resizing),
            // and one that picks up from wherever it is when the pointer moves on, so a
            // quick sweep across the categories never stacks animations.
            .offset(y: Self.point(0, y - 24).y)
            .animation(reduceMotion ? nil : DSMotion.glide, value: y)
        }
    }

    // MARK: Slab

    /// Animatable, so a change in a category's share reshapes the slab smoothly.
    private struct SlabView: View, Animatable {
        let color: Color
        var bottom: CGFloat
        var height: CGFloat

        nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(bottom, height) }
            set { bottom = newValue.first; height = newValue.second }
        }

        var body: some View {
            let c = IsoStack.centerX, w = IsoStack.halfWidth, d = IsoStack.halfDepth
            let b = bottom, h = height
            let right = [CGPoint(x: c + w, y: b - d), CGPoint(x: c, y: b), CGPoint(x: c, y: b - h), CGPoint(x: c + w, y: b - d - h)]
            let left = [CGPoint(x: c - w, y: b - d), CGPoint(x: c, y: b), CGPoint(x: c, y: b - h), CGPoint(x: c - w, y: b - d - h)]
            let top = [CGPoint(x: c, y: b - h - 2 * d), CGPoint(x: c + w, y: b - d - h), CGPoint(x: c, y: b - h), CGPoint(x: c - w, y: b - d - h)]
            let outline = [CGPoint(x: c, y: b), CGPoint(x: c + w, y: b - d), CGPoint(x: c + w, y: b - d - h),
                           CGPoint(x: c, y: b - h - 2 * d), CGPoint(x: c - w, y: b - d - h), CGPoint(x: c - w, y: b - d)]

            ZStack {
                face(right, opacity: 0.38)
                face(left, opacity: 0.2)
                face(top, opacity: 0.3)
            }
            .frame(width: 240, height: 216, alignment: .topLeading)
            .contentShape(polygon(outline))
        }

        private func polygon(_ points: [CGPoint]) -> Path {
            var path = Path()
            path.addLines(points.map { IsoStack.point($0.x, $0.y) })
            path.closeSubpath()
            return path
        }

        private func face(_ points: [CGPoint], opacity: Double) -> some View {
            let path = polygon(points)
            return ZStack {
                path.fill(color.opacity(opacity))
                path.stroke(color, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }
    }
}

/// A quiet sentence where a chart has nothing to draw.
struct HomeEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .dsStyle(.bodySmall)
            .foregroundStyle(DS.Palette.inkMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
