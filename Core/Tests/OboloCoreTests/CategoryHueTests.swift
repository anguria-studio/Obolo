import Foundation
import Testing
@testable import OboloCore

/// The twelve-hue category palette and how a category stores it.
@Suite("Category hues")
struct CategoryHueTests {

    @Test("Every seeded category has its own hue, and none is orange")
    func seededAreDistinct() {
        let hues = Category.seeded.map(\.tint)
        #expect(Set(hues).count == hues.count)
        #expect(Category.seeded.first { $0.name == "Software" }?.tint == .teal)
        #expect(Category.seeded.first { $0.name == "Utilities & telecom" }?.tint == .mint)
        #expect(Category.seeded.first { $0.name == "Insurance" }?.tint == .slate)
    }

    @Test("A category is stored with its hue alone")
    func encodesHue() throws {
        let category = Category(name: "Work", tint: .magenta, sortOrder: 0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(category)) as? [String: Any]
        #expect(json?["hue"] as? String == "magenta")
        #expect(json?["tint"] == nil)
        #expect(try JSONDecoder().decode(Category.self, from: JSONEncoder().encode(category)) == category)
    }

    @Test("Without a known hue: a seeded category takes its own, anyone else grey")
    func missingHue() throws {
        let music = #"{"id": "C0000002-0000-4000-A000-000000000002", "name": "Music", "sortOrder": 1}"#
        #expect(try JSONDecoder().decode(Category.self, from: Data(music.utf8)).tint == .magenta)
        let custom = #"{"id": "A0000000-0000-4000-A000-000000000003", "name": "X", "hue": "ultraviolet", "sortOrder": 0}"#
        #expect(try JSONDecoder().decode(Category.self, from: Data(custom.utf8)).tint == .gray)
    }
}
