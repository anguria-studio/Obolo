import Foundation
import OboloCore
import SwiftUI
import Testing

/// Home › Subscriptions' ring: the segment under the pointer, by angle and distance.
/// Every segment took hover over the whole frame, so the top one won every time.
@MainActor
@Suite("Subscriptions ring hit test")
struct SubscriptionRingTests {
    private let big = UUID(), mid = UUID(), small = UUID()
    private let size = CGSize(width: 216, height: 216)

    /// 50% from twelve to six, 30% to about ten past seven, 20% back to twelve.
    private var segments: [(item: SubscriptionRingChart.Item, start: Angle, end: Angle)] {
        let category = UUID()
        let items = [
            SubscriptionRingChart.Item(id: big, name: "Big", categoryID: category, color: .red, monthly: 50, share: 0.5),
            SubscriptionRingChart.Item(id: mid, name: "Mid", categoryID: category, color: .blue, monthly: 30, share: 0.3),
            SubscriptionRingChart.Item(id: small, name: "Small", categoryID: category, color: .green, monthly: 20, share: 0.2),
        ]
        return SubscriptionRing.segments(items, total: 1)
    }

    /// A point `radius` from the centre at `degrees` clockwise from twelve o'clock.
    private func point(_ degrees: Double, radius: CGFloat = 90) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: 108 + radius * CGFloat(sin(radians)), y: 108 - radius * CGFloat(cos(radians)))
    }

    @Test("Each segment answers for its own angle, not only the last one drawn")
    func eachSegmentIsReachable() {
        #expect(SubscriptionRing.segmentID(at: point(90), in: size, segments: segments) == big)
        #expect(SubscriptionRing.segmentID(at: point(230), in: size, segments: segments) == mid)
        #expect(SubscriptionRing.segmentID(at: point(330), in: size, segments: segments) == small)
    }

    @Test("The hole, the outside and the gaps answer nothing")
    func holeOutsideAndGaps() {
        #expect(SubscriptionRing.segmentID(at: point(90, radius: 40), in: size, segments: segments) == nil)
        #expect(SubscriptionRing.segmentID(at: point(90, radius: 115), in: size, segments: segments) == nil)
        // Exactly at six o'clock sits the gap between Big and Mid.
        #expect(SubscriptionRing.segmentID(at: point(180), in: size, segments: segments) == nil)
        // A grown segment's edge, at 106, still counts.
        #expect(SubscriptionRing.segmentID(at: point(90, radius: 106), in: size, segments: segments) == big)
    }
}
