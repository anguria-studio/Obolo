import SwiftUI
import OboloCore

/// This month as 100 thin ticks: each payment owns a run of ticks in proportion to its
/// amount, paid runs in orange, the rest still to come. The first tick of a run is
/// taller, so payments read as separate marks. Hovering a run names that payment.
struct TickMeterPanel: View {
    let progress: MonthProgress
    let currency: String
    let calendar: Calendar
    /// Name the year too, for a month outside the current one.
    var showsYear = false

    private static let tickCount = 100
    /// After 0.2 s, paid ticks turn orange from left to right at 14 ms intervals.
    private static let fillDelay: Duration = .milliseconds(200)
    private static let fillStep: Duration = .milliseconds(14)

    @State private var hotPayment: Int?
    /// How many paid ticks are orange so far while the fill runs; `nil` once it is done
    /// or when it does not run (shown before for this month, Reduce Motion).
    @State private var lit: Int? = 0
    @State private var fill: Task<Void, Never>?
    @Environment(\.homeBuildLog) private var buildLog

    /// Whether the paid tick at `ordinal` (its place among the paid ticks) is orange.
    private func isLit(_ ordinal: Int) -> Bool {
        guard let lit else { return true }
        return ordinal < lit
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The payment each tick belongs to, or `nil` for a month with nothing countable.
    private var owners: [Int?] {
        let runs = progress.tickRuns(count: Self.tickCount)
        var owners: [Int?] = []
        for (payment, run) in runs.enumerated() {
            owners += Array(repeating: payment, count: run)
        }
        return owners.isEmpty ? Array(repeating: nil, count: Self.tickCount) : owners
    }

    var body: some View {
        let owners = owners
        VStack(alignment: .leading, spacing: 12) {
            header
            ticks(owners)
                .padding(.top, -6)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: Labels

    private var header: some View {
        HStack {
            if let index = hotPayment, progress.payments.indices.contains(index) {
                let payment = progress.payments[index]
                Text("\(Text.ink(payment.occurrence.date.formatted(.dateTime.day().month(.abbreviated)))) · \(payment.name)")
                    .dsLabel()
                Spacer(minLength: 8)
                Text("\(Text.ink(amount(payment))) · \(share(payment)) · \(payment.isPaid ? "paid" : "to come")")
                    .dsLabel()
            } else {
                let count = progress.payments.count
                Text("\(showsYear ? DateFormatting.monthAndYear(progress.month, calendar: calendar) : DateFormatting.month(progress.month, calendar: calendar)) · \(Text.ink("\(count)")) \(count == 1 ? "payment" : "payments")")
                    .dsLabel()
                Spacer(minLength: 8)
                Text(MoneyFormatting.amount(progress.total, currency: currency))
                    .dsLabel()
                    .foregroundStyle(DS.Palette.ink)
            }
        }
        .lineLimit(1)
    }

    private var footer: some View {
        HStack {
            Text("\(Text.ink(MoneyFormatting.amount(progress.paid, currency: currency))) paid").dsLabel()
            Spacer(minLength: 8)
            if progress.excludedCount > 0 {
                Text("\(Text("\(progress.excludedCount)").foregroundStyle(DS.Palette.warning)) without a rate · ").dsLabel()
            }
            Text("\(Text.ink(MoneyFormatting.amount(progress.toCome, currency: currency))) to come").dsLabel()
        }
        .lineLimit(1)
    }

    private func amount(_ payment: MonthProgress.Payment) -> String {
        guard let base = payment.occurrence.amountInBase else {
            return MoneyFormatting.amount(payment.occurrence.amount, currency: payment.occurrence.currency)
        }
        return MoneyFormatting.amount(base, currency: currency)
    }

    private func share(_ payment: MonthProgress.Payment) -> String {
        guard let base = payment.occurrence.amountInBase, progress.total > 0 else { return MoneyFormatting.unknown }
        return SharePercent.text(Normalizer.share(base, of: progress.total))
    }

    // MARK: Ticks

    private func ticks(_ owners: [Int?]) -> some View {
        // The position of each paid tick among the paid ones, for the fill's stagger.
        var paidOrdinal: [Int: Int] = [:]
        for (index, owner) in owners.enumerated() {
            guard let owner, progress.payments.indices.contains(owner), progress.payments[owner].isPaid else { continue }
            paidOrdinal[index] = paidOrdinal.count
        }
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(owners.indices, id: \.self) { index in
                    let owner = owners[index]
                    let isRunStart = index == 0 || owners[index - 1] != owner
                    tick(owner: owner, isRunStart: isRunStart && owner != nil, isLit: isLit(paidOrdinal[index] ?? 0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let slot = Int(location.x / max(1, proxy.size.width) * CGFloat(owners.count))
                    let owner = owners.indices.contains(slot) ? owners[slot] : nil
                    if owner != hotPayment {
                        // A trackpad tick for each new run of ticks, not for the gaps.
                        if owner != nil { Haptics.tick() }
                        hotPayment = owner
                    }
                case .ended:
                    hotPayment = nil
                }
            }
        }
        .frame(height: 34)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hotPayment)
        // Fills the first time this window shows the meter, and again for each month the
        // picker moves to (see `HomeBuildLog`).
        .onAppear { startFill(paidTicks: paidOrdinal.count) }
        .onDisappear { fill?.cancel() }
        .accessibilityHidden(true)
    }

    /// Lights the paid ticks one by one, or all at once when the fill does not play.
    private func startFill(paidTicks: Int) {
        fill?.cancel()
        guard buildLog.claimTicks(for: progress.month), !reduceMotion, paidTicks > 0 else {
            lit = nil
            return
        }
        lit = 0
        fill = Task { @MainActor in
            try? await Task.sleep(for: Self.fillDelay)
            for count in 1...paidTicks {
                guard !Task.isCancelled else { return }
                lit = count
                try? await Task.sleep(for: Self.fillStep)
            }
            lit = nil
        }
    }

    private func tick(owner: Int?, isRunStart: Bool, isLit: Bool) -> some View {
        let payment = owner.flatMap { progress.payments.indices.contains($0) ? progress.payments[$0] : nil }
        let isPaid = payment?.isPaid ?? false
        let isHot = owner != nil && owner == hotPayment
        // A paid tick starts grey and switches to orange when the fill reaches it.
        let color: Color = isPaid ? (isLit ? DS.Palette.accent : DS.Palette.lineStrong)
            : isHot ? DS.Palette.inkMuted : DS.Palette.lineStrong
        let opacity: Double = hotPayment == nil ? (isPaid ? 1 : 0.6) : (isHot ? 1 : 0.2)

        return RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2, height: isRunStart ? 34 : 28)
            .opacity(opacity)
    }
}
