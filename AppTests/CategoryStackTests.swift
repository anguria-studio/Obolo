import Foundation
import SwiftUI
import Testing

/// The Category stack's slabs always add up to the height the stack is drawn for, so a
/// tower of many small categories never rises out of its frame into the header.
@Suite("Category stack")
struct CategoryStackTests {

    private static let total: CGFloat = 150
    private static let minimum: CGFloat = 2.5

    private static func heights(_ shares: [Double]) -> [CGFloat] {
        IsoStack.slabHeights(shares: shares, total: total, minimum: minimum)
    }

    /// The two things that hold in every case: the heights fill the stack exactly, and
    /// no slab is thinner than the floor for that many slabs.
    private static func expectFills(_ heights: [CGFloat], count: Int) {
        #expect(heights.count == count)
        let floor = IsoStack.slabFloor(count: count, total: total, minimum: minimum)
        #expect(abs(heights.reduce(0, +) - total) < 1e-9)
        for height in heights {
            #expect(height >= floor - 1e-9)
            #expect(height > 0)
        }
    }

    @Test("Ordinary data keeps share × height exactly")
    func ordinaryDataUnchanged() {
        // The sample data's categories: none is under the minimum.
        let monthly = [73.49, 13.99, 11.99, 9.41, 8.70, 7.00, 4.83]
        let sum = monthly.reduce(0, +)
        let shares = monthly.map { $0 / sum }
        let result = Self.heights(shares)
        // What the stack drew before: `max(minimum, share × height)`, to the bit.
        #expect(result == shares.map { max(Self.minimum, CGFloat($0) * Self.total) })
        Self.expectFills(result, count: shares.count)
    }

    @Test("One dominant category and many tiny ones stay in the frame")
    func dominantAndTiny() {
        // The stress data: one subscription of 1.234.567 a month, 30 small categories.
        let monthly = [1_234_567.0] + (0..<30).map { 10 + Double($0) * 0.7 }
        let sum = monthly.reduce(0, +)
        let result = Self.heights(monthly.map { $0 / sum })
        Self.expectFills(result, count: 31)
        // 31 minimums of 2.5 would take more than half, so the floor shrinks to 75 / 31.
        let floor = IsoStack.slabFloor(count: 31, total: Self.total, minimum: Self.minimum)
        #expect(abs(floor - 75.0 / 31) < 1e-12)
        for height in result.dropFirst() { #expect(abs(height - floor) < 1e-9) }
        #expect(abs(result[0] - (Self.total - 30 * floor)) < 1e-9)
        // Still biggest first.
        #expect(result[0] > result[1])
    }

    @Test("A few tiny categories take the minimum from the others, in proportion")
    func fewTiny() {
        let shares = [0.6, 0.39, 0.005, 0.005]
        let result = Self.heights(shares)
        Self.expectFills(result, count: 4)
        #expect(result[2] == Self.minimum)
        #expect(result[3] == Self.minimum)
        // The two big ones keep their ratio.
        #expect(abs(result[0] / result[1] - 0.6 / 0.39) < 1e-9)
    }

    @Test("Taking from the others can push one more under the minimum")
    func cascade() {
        // 0.0168 × 150 = 2.52, just over 2.5, until the 0.0001 one takes its minimum.
        let shares = [0.9831, 0.0168, 0.0001]
        let result = Self.heights(shares)
        Self.expectFills(result, count: 3)
        #expect(result[1] == Self.minimum)
        #expect(result[2] == Self.minimum)
        #expect(abs(result[0] - (Self.total - 2 * Self.minimum)) < 1e-9)
    }

    @Test("Equal shares get equal heights")
    func allEqual() {
        let result = Self.heights(Array(repeating: 1.0 / 8, count: 8))
        Self.expectFills(result, count: 8)
        for height in result { #expect(abs(height - Self.total / 8) < 1e-9) }
    }

    @Test("A single category is the whole stack")
    func single() {
        let result = Self.heights([1])
        #expect(result == [Self.total])
    }

    @Test("No categories, no slabs")
    func empty() {
        #expect(Self.heights([]).isEmpty)
    }

    @Test("Sixty categories: the minimum shrinks to fit half of the height")
    func sixty() {
        // Like the 60-category data: seven sample categories and 53 small ones.
        let monthly = [73.49, 13.99, 11.99, 9.41, 8.70, 7.00, 4.83] + (0..<53).map { 0.5 + 0.1 * Double($0) }
        let sum = monthly.reduce(0, +)
        let shares = monthly.map { $0 / sum }.sorted(by: >)
        let result = Self.heights(shares)
        Self.expectFills(result, count: 60)
        let floor = IsoStack.slabFloor(count: 60, total: Self.total, minimum: Self.minimum)
        #expect(abs(floor - 1.25) < 1e-12)
        // Biggest first still: the order never changes.
        for (upper, lower) in zip(result.dropFirst(), result) { #expect(upper <= lower + 1e-9) }
        // Sixty equal tiny shares: every slab is exactly the floor or more.
        Self.expectFills(Self.heights(Array(repeating: 1.0 / 60, count: 60)), count: 60)
    }

    @Test("Shares that do not add up to 1 still fill the stack")
    func notSummingToOne() {
        let under = Self.heights([0.5, 0.2, 0.1])
        Self.expectFills(under, count: 3)
        #expect(abs(under[0] / under[1] - 2.5) < 1e-9)

        let over = Self.heights([0.7, 0.5, 0.3])
        Self.expectFills(over, count: 3)
        #expect(abs(over[0] / over[2] - 0.7 / 0.3) < 1e-9)
    }

    @Test("A zero share still gets a visible slab")
    func zeroShare() {
        let result = Self.heights([0.8, 0.2, 0])
        Self.expectFills(result, count: 3)
        #expect(result[2] == Self.minimum)

        // All zero: equal slabs rather than nothing.
        let zeros = Self.heights([0, 0, 0])
        Self.expectFills(zeros, count: 3)
        #expect(abs(zeros[0] - Self.total / 3) < 1e-9)
    }
}

/// The slab under the pointer, through the slabs' outlines: hovering always picked the
/// top slab while every slab took events over the whole frame.
@MainActor
@Suite("Category stack hit test")
struct CategoryStackHitTests {
    private let bottom = UUID()
    private let top = UUID()

    /// Two slabs of half the stack each: `bottom` first, `top` above it.
    private var entries: [IsoStack.Entry] {
        [
            IsoStack.Entry(id: bottom, name: "Streaming", color: .red, monthly: 10, share: 0.5, count: 1),
            IsoStack.Entry(id: top, name: "Music", color: .blue, monthly: 10, share: 0.5, count: 1),
        ]
    }

    /// A design-unit point, as `IsoStack.point` maps it into the view (0.8 scale, 30 up).
    private func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * 0.8, y: (y - 30) * 0.8) }

    @Test("A point on the bottom slab finds the bottom category, not the top one")
    func bottomSlabIsReachable() {
        // Just above the stack's front-bottom vertex (130, 278): only the bottom slab.
        #expect(IsoStack.slabID(at: view(130, 270), in: entries) == bottom)
    }

    @Test("Where two outlines overlap, the slab on top wins; outside every slab, none")
    func topWinsAndGapsAreEmpty() {
        // (130, 150) is inside both outlines: the top slab is the one in front.
        #expect(IsoStack.slabID(at: view(130, 150), in: entries) == top)
        // (130, 100) is above the bottom slab's back corner: only the top one.
        #expect(IsoStack.slabID(at: view(130, 100), in: entries) == top)
        // The far left of the frame is outside both.
        #expect(IsoStack.slabID(at: CGPoint(x: 2, y: 2), in: entries) == nil)
    }
}
