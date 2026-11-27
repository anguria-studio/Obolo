import AppKit
import Foundation
import OboloCore
import SwiftUI
import Testing

/// Settings › General › Appearance: Dynamic follows macOS, Light and Dark set every window.
@MainActor
@Suite("Appearance")
struct AppearanceTests {
    @Test("Dynamic follows macOS; Light and Dark name the app's appearance")
    func mapping() {
        #expect(AppearanceSetting.auto.nsAppearanceName == nil)
        #expect(AppearanceSetting.light.nsAppearanceName == .aqua)
        #expect(AppearanceSetting.dark.nsAppearanceName == .darkAqua)
        #expect(AppearanceSetting.allCases.map(\.displayName) == ["Dark", "Light", "Dynamic"])
    }

    @Test("Applying a choice sets the app's appearance, and Dynamic clears it")
    func applying() {
        let before = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = before }

        AppModel.apply(Settings().appearance)
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        AppModel.apply(.light)
        #expect(NSApplication.shared.appearance?.name == .aqua)
        AppModel.apply(.auto)
        #expect(NSApplication.shared.appearance == nil)
    }

    @Test("A palette colour resolves to its own value in each theme")
    func paletteFollowsTheAppearance() throws {
        func resolved(_ name: NSAppearance.Name) throws -> String {
            let appearance = try #require(NSAppearance(named: name))
            var hex = ""
            appearance.performAsCurrentDrawingAppearance {
                let color = NSColor(DS.Palette.bg200).usingColorSpace(.sRGB)!
                hex = String(format: "%02X%02X%02X", Int(round(color.redComponent * 255)),
                             Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
            }
            return hex
        }
        #expect(try resolved(.darkAqua) == "1A1A1B")
        #expect(try resolved(.aqua) == "FFFFFF")
    }
}
