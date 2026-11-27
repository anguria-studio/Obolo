import AppKit
import EventKit
import SwiftUI
import UserNotifications
import OboloCore

/// Home before the first subscription.
///
/// The top card offers Add subscription and Import CSV. The bottom card offers notification
/// and calendar setup. Both settings remain available after the first subscription.
///
/// Right after the first subscription is saved, Home stays like this for a moment:
/// the slab fills in that subscription's category colour and the text says so
/// (`firstSlab`). Then Home moves on to its normal layout (`onFinish`).
struct EmptyHomeView: View {
    let model: AppModel
    /// The first subscription, just saved.
    var firstSlab: Subscription.ID?
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(spacing: DS.Size.gutter) {
            EmptySpendPanel(model: model, firstSlab: firstSlab, onFinish: onFinish)
                .frame(maxHeight: .infinity)
                .dsPanel()

            SetupPanel(model: model)
                .dsPanel()
        }
        .accessibilityIdentifier("home.empty")
    }

    /// The reminders step's line, with the default lead time from Settings:
    /// "Mac notifications, 2 days before by default."
    static func reminderStepDetail(leadDays: Int) -> String {
        "Mac notifications, \(OboloCore.Settings.reminderLeadText(days: leadDays)) by default."
    }
}

// MARK: - Spend panel

private struct EmptySpendPanel: View {
    let model: AppModel
    let firstSlab: Subscription.ID?
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the first-slab moment stays before Home moves on by itself.
    private static let beat: Duration = .seconds(4)

    private var currency: String { model.document.settings.baseCurrency }

    private var summary: SubscriptionSummary? {
        firstSlab.flatMap { id in model.ledger.summaries.first { $0.subscription.id == id } }
    }

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: 0) {
            Text("Monthly spend").dsLabel()
            HeroAmount(text: MoneyFormatting.amount(0, currency: currency), color: DS.Palette.inkDisabled)
                .padding(.top, 6)

            HStack(spacing: 8) {
                EmptySlab(layout: .home, fill: summary.map { DS.category($0.category.tint) })
                    .frame(width: EmptySlab.Layout.home.size.width, height: EmptySlab.Layout.home.size.height)

                ZStack(alignment: .leading) {
                    if let summary {
                        filledText(summary)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.25)),
                                removal: .identity
                            ))
                    } else {
                        emptyText
                            .transition(.identity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        // The moment holds for a beat, then Home moves on; "Go to Home" skips the wait.
        .task(id: firstSlab) {
            guard firstSlab != nil else { return }
            try? await Task.sleep(for: Self.beat)
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    private var emptyText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing stacked up yet")
                .dsStyle(.heading)
                .foregroundStyle(DS.Palette.ink)
            Text("Add your subscriptions and Obolo shows where the money goes, what renews when, and how prices change.")
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            EmptyStateActions(model: model)
                .padding(.top, 16)
        }
    }

    private func filledText(_ summary: SubscriptionSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                CategoryMarker(color: DS.category(summary.category.tint), size: 8)
                Text("\(summary.category.name) · \(MoneyFormatting.amount(summary.price, currency: summary.currency)) \(Self.unit(summary.cycle))")
                    .lineLimit(1)
            }
            .dsLabel()
            Text("\(summary.subscription.name) is your first slab")
                .dsStyle(.heading)
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("Every category you add stacks on top of it.")
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Button("Go to Home", action: onFinish)
                .buttonStyle(DSPrimaryButtonStyle(height: 32))
                .dsFocusRing(Capsule())
                .fixedSize()
                .padding(.top, 16)
        }
    }

    /// "/ mo", "/ 3 mo", "/ 2 yr": the label line's spaced form of the cycle. The count
    /// and unit come from `BillingCycle.compactPeriod`, as in the All list's "/2y".
    private static func unit(_ cycle: BillingCycle) -> String {
        let (count, unit) = cycle.compactPeriod
        return count == 1 ? "/ \(unit.abbreviation)" : "/ \(count) \(unit.abbreviation)"
    }
}

/// "Add subscription" and "Import CSV", the two ways into an empty list: on Home and
/// on All.
struct EmptyStateActions: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button("Add subscription") { model.presentAdd() }
                .buttonStyle(DSPrimaryButtonStyle(height: 32))
                .dsFocusRing(Capsule())
            Button("Import CSV") { ImportCoordinator.chooseAndPreview(model: model) }
                .buttonStyle(DSSecondaryButtonStyle(height: 32))
                .dsFocusRing(Capsule())
        }
        .fixedSize()
    }
}

// MARK: - The empty slab

/// The empty slab uses dashed outlines in `inkMuted` and an orange dot. Its floor is centred
/// at (120, 132) in a 240 × 200 coordinate space. All uses a smaller scale.
///
/// On Home it builds once per window (see `HomeBuildLog`): the floor fades in (0.4 s),
/// the slab draws itself left to right (0.8 s from 0.25 s), the dot pops in at 1.05 s,
/// then a soft orange halo breathes around it every 3.6 s, the current-month glow's
/// rhythm, only while the window is key. With Reduce Motion it is all simply there and
/// the halo never runs. All's copy is still.
///
/// With `fill`, the first subscription is in: the outline turns solid in its category
/// colour, the faces fill (sides 24% and 17%, top 40%), the slab settles 8pt and the dot
/// fades out.
struct EmptySlab: View {
    struct Layout {
        /// The drawing area before scaling.
        let size: CGSize
        /// The floor's centre in that box.
        let center: CGPoint
        let scale: CGFloat

        /// Home: 240 × 200.
        static let home = Layout(size: CGSize(width: 240, height: 200), center: CGPoint(x: 120, y: 132), scale: 1)
        /// All: 220 × 150, the same drawing at 76%.
        static let list = Layout(size: CGSize(width: 220, height: 150), center: CGPoint(x: 110, y: 99), scale: 0.7631)
    }

    var layout: Layout = .home
    var fill: Color?
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.homeBuildLog) private var buildLog

    @State private var floorShown = false
    @State private var drawn: CGFloat = 0
    @State private var dotScale: CGFloat = 0
    @State private var settle: CGFloat = 0
    /// When the halo's first breath starts; `nil` while it never runs.
    @State private var haloSince: Date?

    private var isFilled: Bool { fill != nil }

    // MARK: Geometry (canvas units around the floor's centre)

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: layout.center.x + x * layout.scale, y: layout.center.y + y * layout.scale)
    }

    private var floorCorners: [CGPoint] {
        [point(0, -77), point(133.4, 0), point(0, 77), point(-133.4, 0)]
    }

    private var leftFace: [CGPoint] { [point(-104.8, 0), point(0, 60.5), point(0, 22), point(-104.8, -38.5)] }
    private var rightFace: [CGPoint] { [point(104.8, 0), point(0, 60.5), point(0, 22), point(104.8, -38.5)] }
    private var topFace: [CGPoint] { [point(0, -99), point(104.8, -38.5), point(0, 22), point(-104.8, -38.5)] }
    private var dot: CGPoint { point(0, -32.4) }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            floor
                .opacity(floorShown ? 1 : 0)

            slab
                .mask(alignment: .leading) {
                    Rectangle().frame(width: layout.size.width * drawn)
                }
                .offset(y: settle)

            halo
            dotView
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear(perform: build)
        .onChange(of: isFilled) { _, filled in
            guard filled, !reduceMotion else { return }
            // From 8pt up, settling into place.
            settle = -8
            withAnimation(DSMotion.easeOutCubic(0.45)) { settle = 0 }
        }
    }

    private var floor: some View {
        // The floor overhangs the box and a `Canvas` clips to its
        // frame, so it draws in a larger one, shifted back into place.
        let margin: CGFloat = 24
        return Canvas { context, _ in
            context.translateBy(x: margin, y: margin)
            let c = floorCorners
            func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            var grid = Path()
            for t in [0.25, 0.5, 0.75] as [CGFloat] {
                grid.move(to: lerp(c[0], c[1], t)); grid.addLine(to: lerp(c[3], c[2], t))
                grid.move(to: lerp(c[0], c[3], t)); grid.addLine(to: lerp(c[1], c[2], t))
            }
            context.stroke(grid, with: .color(DS.Palette.line), lineWidth: 1)

            var outline = Path()
            outline.addLines(c)
            outline.closeSubpath()
            context.stroke(
                outline,
                with: .color(DS.Palette.lineStrong.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
        }
        .frame(width: layout.size.width + 2 * margin, height: layout.size.height + 2 * margin)
        .offset(x: -margin, y: -margin)
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private var slab: some View {
        let stroke = StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: isFilled ? [] : [5, 4])
        let faces: [([CGPoint], Double)] = [(leftFace, 0.24), (rightFace, 0.17), (topFace, 0.4)]
        return ZStack(alignment: .topLeading) {
            ForEach(faces.indices, id: \.self) { index in
                let (points, opacity) = faces[index]
                Polygon(points: points)
                    .fill((fill ?? .clear).opacity(isFilled ? opacity : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.15), value: isFilled)
                Polygon(points: points)
                    .stroke(fill ?? DS.Palette.inkMuted, style: stroke)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isFilled)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private var dotView: some View {
        Circle()
            .fill(DS.Palette.accent)
            .overlay(Circle().stroke(DS.Palette.bg200, lineWidth: 2))
            .frame(width: 10, height: 10)
            .scaleEffect(dotScale)
            .position(dot)
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .opacity(isFilled ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFilled)
    }

    @ViewBuilder
    private var halo: some View {
        if let haloSince {
            let running = activeState == .key && !isFilled
            TimelineView(.animation(paused: !running)) { context in
                Circle()
                    .fill(DS.Palette.accent)
                    .frame(width: 22, height: 22)
                    .blur(radius: 4)
                    .opacity(running ? 0.35 * NowHalo.breath(at: context.date.timeIntervalSince(haloSince)) : 0)
                    .position(dot)
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
    }

    // MARK: Build

    private func build() {
        let plays = animated && !reduceMotion && !isFilled && buildLog.claim(.emptySlab)
        guard plays else {
            floorShown = true
            drawn = 1
            dotScale = 1
            if animated && !reduceMotion { haloSince = .now }
            return
        }
        withAnimation(.easeOut(duration: 0.4)) { floorShown = true }
        withAnimation(DSMotion.easeOutCubic(0.8).delay(0.25)) { drawn = 1 }
        haloSince = .now.addingTimeInterval(1.6)
        Task { @MainActor in
            // 0 → 1.15 → 1 in 0.3 s, from 1.05 s.
            try? await Task.sleep(for: .milliseconds(1050))
            withAnimation(.easeOut(duration: 0.21)) { dotScale = 1.15 }
            try? await Task.sleep(for: .milliseconds(210))
            withAnimation(.easeOut(duration: 0.09)) { dotScale = 1 }
        }
    }

    private struct Polygon: Shape {
        let points: [CGPoint]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            return path
        }
    }
}

// MARK: - Set-up panel

/// "SET UP · N OF 2": the first-run window's two steps, both optional. Each answers
/// with "ON" or "CONNECTED" once done; Settings › Reminders holds them for later.
private struct SetupPanel: View {
    let model: AppModel

    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var calendarStatus = CalendarSync.authorizationStatus

    private var settings: OboloCore.Settings { model.document.settings }

    private var notificationsOn: Bool {
        guard settings.notificationsEnabled, let notificationStatus else { return false }
        return notificationStatus == .authorized || notificationStatus == .provisional
    }

    private var calendarOn: Bool {
        settings.calendarSyncEnabled && settings.calendarIdentifier != nil && calendarStatus == .fullAccess
    }

    var body: some View {
        let done = (notificationsOn ? 1 : 0) + (calendarOn ? 1 : 0)
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up · \(Text("\(done) of 2").foregroundStyle(DS.Palette.ink))")
                .dsLabel()

            SetupRow(
                title: "Remind me before renewals",
                detail: EmptyHomeView.reminderStepDetail(leadDays: settings.defaultReminderLeadDays),
                button: "Allow",
                doneText: "On",
                isDone: notificationsOn,
                action: allowNotifications
            )
            .padding(.top, 6)

            SetupRow(
                title: "Add payments to a calendar",
                detail: "One repeating event per subscription, in a calendar you pick.",
                button: "Connect",
                doneText: "Connected",
                isDone: calendarOn,
                action: connectCalendar
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .task { await refresh() }
        // A permission granted in System Settings shows here when the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        calendarStatus = CalendarSync.authorizationStatus
        notificationStatus = await NotificationScheduler.authorizationStatus()
    }

    /// Asks for permission, the one place besides Settings that does. Denied before:
    /// only System Settings can change that, so it opens there.
    private func allowNotifications() {
        if notificationStatus == .denied {
            open(NotificationScheduler.settingsURL)
            return
        }
        Task {
            let granted = await NotificationScheduler.requestAuthorization()
            update {
                $0.hasCompletedFirstRun = true
                if granted { $0.notificationsEnabled = true }
            }
            // A fresh grant: whatever was skipped for want of permission can be queued.
            model.notifyServices()
            await refresh()
        }
    }

    /// Asks for calendar access and syncs into the first calendar, iCloud first so the
    /// alerts reach the phone; Settings › Reminders picks another.
    private func connectCalendar() {
        switch calendarStatus {
        case .denied, .restricted, .writeOnly:
            open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")
        default:
            Task {
                guard await CalendarSync.requestAccess() else {
                    await refresh()
                    return
                }
                let calendarID = CalendarSync.calendars().first?.calendarIdentifier
                update {
                    $0.hasCompletedFirstRun = true
                    $0.calendarIdentifier = calendarID
                    $0.calendarSyncEnabled = calendarID != nil
                }
                await refresh()
            }
        }
    }

    private func update(_ change: (inout OboloCore.Settings) -> Void) {
        var settings = model.document.settings
        change(&settings)
        model.updateSettings(settings)
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// One step: the ring (filled with a check once done), the title and its line, and the
/// button, or the word that says it is done.
private struct SetupRow: View {
    let title: String
    let detail: String
    let button: String
    let doneText: String
    let isDone: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(isDone ? DS.Palette.accent : .clear)
                Circle().strokeBorder(isDone ? DS.Palette.accent : DS.Palette.lineStrong, lineWidth: DS.hairline)
                Check()
                    .stroke(DS.Palette.accentInk, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    .frame(width: 10, height: 10)
                    .opacity(isDone ? 1 : 0)
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(isDone ? DS.Palette.inkMuted : DS.Palette.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDone {
                Text(doneText)
                    .dsStyle(.label)
                    .foregroundStyle(DS.Palette.positive)
            } else {
                Button(button, action: action)
                    .buttonStyle(DSSecondaryButtonStyle(height: 30, mono: true))
                    .dsFocusRing(Capsule())
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    /// The checkmark path in a 24-unit box.
    private struct Check: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            var path = Path()
            path.move(to: CGPoint(x: 5 * s, y: 12 * s))
            path.addLine(to: CGPoint(x: 10 * s, y: 17 * s))
            path.addLine(to: CGPoint(x: 19 * s, y: 7 * s))
            return path
        }
    }
}

// MARK: - Previews

#Preview("Home · empty") {
    MainWindow(model: .handoffPreview { $0.subscriptions = [] })
}
