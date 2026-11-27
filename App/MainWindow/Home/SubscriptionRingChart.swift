import SwiftUI
import OboloCore

/// Subscriptions view: the ring beside the subscription legend.
///
/// The outer ring is every counted subscription by its monthly cost, grouped by
/// category; the thin inner ring is those categories. Hovering a segment or a row previews
/// the subscription in the centre and highlights its segment. Clicking a segment toggles
/// its pin. Activating a legend row opens that subscription's detail.
///
/// Both rings sweep in clockwise from twelve o'clock each time the view appears.
struct SubscriptionRingChart: View {
    let model: AppModel
    let ledger: Ledger

    /// The subscription a click pinned.
    @State private var pinned: Subscription.ID?
    /// The subscription under the pointer, previewed over the pinned one.
    @State private var hovered: Subscription.ID?
    /// Set when the pointer is on a ring segment, so the list can bring that row into view
    /// (and does not scroll under a pointer that is on the list itself).
    @State private var ringHovered: Subscription.ID?

    /// What the ring, the centre and the list show.
    private var picked: Subscription.ID? { hovered ?? pinned }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currency: String { model.document.settings.baseCurrency }

    struct Item: Identifiable {
        let id: Subscription.ID
        let name: String
        let categoryID: OboloCore.Category.ID
        let color: Color
        let monthly: Decimal
        let share: Double
    }

    /// Subscriptions in ring order: categories biggest first, each category's
    /// subscriptions biggest first.
    private var items: [Item] {
        let categoryRank = Dictionary(
            ledger.categoryTotals.sorted { $0.monthly > $1.monthly }.enumerated().map { ($1.category.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ledger.summaries
            .compactMap { summary -> Item? in
                guard summary.countsInTotals, let monthly = summary.monthlyInBase, monthly > 0 else { return nil }
                return Item(
                    id: summary.id,
                    name: summary.name,
                    categoryID: summary.category.id,
                    color: DS.category(summary.category.tint),
                    monthly: monthly,
                    share: Normalizer.share(monthly, of: ledger.monthlyTotal)
                )
            }
            .sorted {
                let left = categoryRank[$0.categoryID] ?? .max, right = categoryRank[$1.categoryID] ?? .max
                if left != right { return left < right }
                if $0.monthly != $1.monthly { return $0.monthly > $1.monthly }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        let items = items
        if items.isEmpty {
            HomeEmptyState(text: "Add a subscription to see what each one costs.")
        } else {
            HStack(spacing: 32) {
                ZStack {
                    SubscriptionRing(
                        items: items,
                        picked: picked,
                        onHover: { id in
                            // A trackpad tick when the pointer reaches another
                            // subscription, from a segment or a row alike: a segment
                            // and its own row tick once between them.
                            if id != hovered { Haptics.tick() }
                            hovered = id
                            ringHovered = id
                        },
                        onPick: toggle
                    )
                    centre(items)
                        .allowsHitTesting(false)
                }
                .frame(width: 216, height: 216)

                list(items)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            // Segments and rows only ever set the preview; it clears when the pointer
            // leaves the ring and the list together.
            .onHover { inside in
                if !inside {
                    hovered = nil
                    ringHovered = nil
                }
            }
            .onChange(of: model.isShowingSubscriptionDetail) { _, isShowing in
                if isShowing {
                    hovered = nil
                    ringHovered = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: picked)
        }
    }

    /// The centre drops the cents from this amount up, in the currency's own units.
    static let wholeUnitsFrom: Decimal = 10_000

    @ViewBuilder
    private func centre(_ items: [Item]) -> some View {
        if let item = items.first(where: { $0.id == picked }) {
            VStack(spacing: 2) {
                Text(item.name)
                    .dsStyle(.bodySmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .lineLimit(1)
                    .frame(maxWidth: 112)
                // From 10.000 up, whole units ("23.457 €"); and never wider than the
                // inner ring: it steps down from 22pt to 15pt before it would overflow.
                Text(MoneyFormatting.amount(
                    item.monthly, currency: currency, wholeUnits: item.monthly >= Self.wholeUnitsFrom
                ))
                    .font(DSFonts.font(DSFonts.monoRegular, size: 22))
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(15.0 / 22.0)
                    .frame(maxWidth: 112)
                Text("\(SharePercent.text(item.share)) of total")
                    .dsStyle(.labelSmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .accessibilityLabel("\(SharePercent.text(item.share, spoken: true)) of total")
            }
        } else {
            VStack(spacing: 0) {
                Text("Active")
                    .dsStyle(.bodySmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                Text("\(ledger.activeCount)")
                    .font(DSFonts.font(DSFonts.sansRegular, size: 34))
                    .tracking(-0.68)
                    .foregroundStyle(DS.Palette.ink)
                Text("Subscriptions")
                    .dsStyle(.labelSmall)
                    .foregroundStyle(DS.Palette.inkMuted)
            }
        }
    }

    /// Every counted subscription, biggest first. The heading stays put and the rows
    /// scroll in the ring's height; a pick made in the ring scrolls its row into view.
    private func list(_ items: [Item]) -> some View {
        let sorted = items.sorted {
            $0.monthly != $1.monthly ? $0.monthly > $1.monthly
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return VStack(alignment: .leading, spacing: 0) {
            Text("Subscriptions · / month")
                .dsLabel()
                .padding(.leading, 8)
                .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sorted) { item in
                            row(item).id(item.id)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .dsScrollFade()
                .onChange(of: ringHovered ?? pinned) { _, id in
                    guard !model.isShowingSubscriptionDetail, let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        proxy.scrollTo(id)
                    }
                }
            }
            .frame(maxHeight: 216 - 22)
        }
    }

    private func row(_ item: Item) -> some View {
        let isOn = item.id == picked
        return Button { model.openHomeSubscriptionDetail(item.id) } label: {
            HStack(spacing: 10) {
                CategoryMarker(color: item.color)
                Text(item.name)
                    .dsStyle(.body)
                    .foregroundStyle(DS.Palette.ink)
                    .lineLimit(1)
                    .frame(minWidth: FittingAmount.nameMinimumWidth, maxWidth: .infinity, alignment: .leading)
                // The amount is never cut: the name gives way to it, down to its minimum,
                // and then the amount drops its decimals.
                FittingAmount(value: item.monthly, currency: currency)
                    .dsStyle(.data)
                    .foregroundStyle(isOn ? DS.Palette.ink : DS.Palette.inkMuted)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(isOn ? DS.Palette.bg300 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsFocusRing(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
        .accessibilityIdentifier("home.subscription.\(item.id.uuidString)")
        .onHover { inside in
            if inside {
                // A tick for a row too, as Category's rows do, only on a change.
                if item.id != hovered { Haptics.tick() }
                hovered = item.id
                ringHovered = nil
            }
        }
        .accessibilityAddTraits(item.id == pinned ? .isSelected : [])
    }

    private func toggle(_ id: Subscription.ID) {
        pinned = pinned == id ? nil : id
    }
}

// MARK: - Ring

/// Outer ring 76–102, inner category ring 66–71, in a 216 frame.
struct SubscriptionRing: View {
    let items: [SubscriptionRingChart.Item]
    let picked: Subscription.ID?
    let onHover: (Subscription.ID) -> Void
    let onPick: (Subscription.ID) -> Void

    private static let outer: (inner: CGFloat, outer: CGFloat) = (76, 102)
    private static let inner: (inner: CGFloat, outer: CGFloat) = (66, 71)
    /// The gap between segments, in degrees.
    private static let gap: Double = 0.9
    /// The previewed segment's outer edge: it grows outward in place rather than sliding
    /// along its middle, so even an 88% arc stays centred. The 216pt frame has a radius
    /// of 108pt and the sweep extends to 120pt.
    private static let pickedOuter: CGFloat = 108

    /// False until the rings have swept in.
    @State private var swept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.homeBuildLog) private var buildLog

    /// Swept already if this window has shown the ring before.
    private var isSwept: Bool { swept || buildLog.hasPlayed(.subscriptions) }

    private var pickedCategory: OboloCore.Category.ID? {
        items.first { $0.id == picked }?.categoryID
    }

    var body: some View {
        let total = items.reduce(0) { $0 + $1.share }
        ZStack {
            ForEach(Array(segments(total: total).enumerated()), id: \.element.item.id) { _, segment in
                let isPicked = segment.item.id == picked
                let shape = AnnularSector(start: segment.start, end: segment.end,
                                          innerRadius: Self.outer.inner,
                                          outerRadius: isPicked ? Self.pickedOuter : Self.outer.outer)
                shape
                    .fill(segment.item.color)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        $0.opacity(opacity(for: segment.item))
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0), value: isPicked)
                    // Hover and clicks go through the ring's hit test below: each segment
                    // is a full-frame layer, and the top one would take every event.
                    .allowsHitTesting(false)
            }

            ForEach(categorySegments(total: total), id: \.id) { segment in
                AnnularSector(start: segment.start, end: segment.end,
                              innerRadius: Self.inner.inner, outerRadius: Self.inner.outer)
                    .fill(segment.color)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        $0.opacity(pickedCategory == nil ? 0.85 : pickedCategory == segment.id ? 0.9 : 0.18)
                    }
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 216, height: 216)
        .contentShape(Rectangle())
        // One hover and one click for the ring, by the pointer's angle and distance from
        // the centre. Gaps and the hole keep the last segment; leaving the ring and the
        // list together clears it (outside).
        .onContinuousHover { phase in
            guard case .active(let location) = phase,
                  let id = Self.segmentID(at: location, in: CGSize(width: 216, height: 216), segments: segments(total: total))
            else { return }
            onHover(id)
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if let id = Self.segmentID(at: value.location, in: CGSize(width: 216, height: 216), segments: segments(total: total)) {
                onPick(id)
            }
        })
        // Sweep: a thick circle traced clockwise from twelve o'clock reveals both rings.
        // Its band (radius 58 ± 62) covers the outer ring and a grown segment.
        .mask {
            Circle()
                .trim(from: 0, to: isSwept ? 1 : 0)
                .stroke(Color.black, lineWidth: 124)
                .rotationEffect(.degrees(-90))
                .frame(width: 116, height: 116)
                .animation(reduceMotion ? nil : DSMotion.easeOutCubic(1.2), value: isSwept)
        }
        // Sweeps the first time this window shows the ring (see `HomeBuildLog`).
        .onAppear { if buildLog.claim(.subscriptions) { swept = true } }
        // Data changes: segments resize in place.
        .animation(reduceMotion ? nil : DSMotion.easeOutCubic(0.6), value: items.map(\.share))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly spend by subscription, grouped by category")
    }

    private func opacity(for item: SubscriptionRingChart.Item) -> Double {
        guard let picked else { return 0.5 }
        return item.id == picked ? 1 : 0.18
    }

    /// The segment under `point` in a frame of `size`: its angle clockwise from twelve
    /// o'clock picks the segment, and its distance from the centre must fall on the
    /// outer ring (out to a grown segment's edge). `nil` in the hole, outside, or in a
    /// gap between segments.
    static func segmentID(
        at point: CGPoint,
        in size: CGSize,
        segments: [(item: SubscriptionRingChart.Item, start: Angle, end: Angle)]
    ) -> Subscription.ID? {
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= outer.inner, radius <= pickedOuter else { return nil }
        var degrees = atan2(Double(dx), Double(-dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return segments.first { $0.start.degrees <= degrees && degrees <= $0.end.degrees }?.item.id
    }

    private func segments(total: Double) -> [(item: SubscriptionRingChart.Item, start: Angle, end: Angle)] {
        Self.segments(items, total: total)
    }

    /// Each subscription's arc, clockwise from twelve o'clock, with a gap between them.
    static func segments(
        _ items: [SubscriptionRingChart.Item],
        total: Double
    ) -> [(item: SubscriptionRingChart.Item, start: Angle, end: Angle)] {
        var cursor = 0.0
        return items.map { item in
            let sweep = total > 0 ? item.share / total * 360 : 0
            defer { cursor += sweep }
            let gap = min(Self.gap, sweep / 3)
            return (item, .degrees(cursor + gap / 2), .degrees(cursor + sweep - gap / 2))
        }
    }

    private struct CategorySegment {
        let id: OboloCore.Category.ID
        let color: Color
        let start: Angle
        let end: Angle
    }

    private func categorySegments(total: Double) -> [CategorySegment] {
        var result: [CategorySegment] = []
        var cursor = 0.0
        var index = 0
        while index < items.count {
            let category = items[index].categoryID
            var sweep = 0.0
            while index < items.count, items[index].categoryID == category {
                sweep += total > 0 ? items[index].share / total * 360 : 0
                index += 1
            }
            let gap = min(Self.gap * 2, sweep / 3)
            result.append(CategorySegment(
                id: category,
                color: items[index - 1].color,
                start: .degrees(cursor + gap / 2),
                end: .degrees(cursor + sweep - gap / 2)
            ))
            cursor += sweep
        }
        return result
    }
}

/// A ring segment, angles measured clockwise from twelve o'clock.
struct AnnularSector: Shape {
    var start: Angle
    var end: Angle
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    /// The angles and the outer edge animate, so a segment resizes, and grows when
    /// previewed, rather than jumps.
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { AnimatablePair(AnimatablePair(start.degrees, end.degrees), outerRadius) }
        set {
            start = .degrees(newValue.first.first)
            end = .degrees(newValue.first.second)
            outerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let from = start - .degrees(90), to = end - .degrees(90)
        var path = Path()
        path.addArc(center: centre, radius: outerRadius, startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: centre, radius: innerRadius, startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }
}
