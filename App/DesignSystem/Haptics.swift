import AppKit

/// Force Touch trackpad feedback, in one place so it is easy to tune.
///
/// Two kinds only, and nowhere else: `tick()` when scrubbing a chart lands on a new item
/// (a month bar, a ring segment, a category or subscription row, a run of ticks), and
/// `step()` when a calendar swipe or scroll commits to another month. No haptics on
/// clicks, on hovering lists outside the charts, or on builds, and no sounds.
@MainActor
enum Haptics {
    /// The shortest gap between two ticks: a fast sweep across many bars buzzes rather
    /// than clicks without it.
    private static let minimumTickInterval: TimeInterval = 0.04
    private static var lastTick: TimeInterval = 0

    /// A chart's pointer has moved onto a new item. Call it only when the hovered item
    /// changes; it drops ticks that come closer than 40 ms.
    static func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTick >= minimumTickInterval else { return }
        lastTick = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A calendar swipe or scroll has turned to the next or previous month.
    static func step() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
