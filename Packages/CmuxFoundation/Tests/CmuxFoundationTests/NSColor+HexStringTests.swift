import AppKit
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``AppKit/NSColor/hexString(includeAlpha:)``: round-trips known
/// sRGB component values to their `#RRGGBB` / `#RRGGBBAA` encoding.
@Suite struct NSColorHexStringTests {
    @Test func opaquePrimaryEncodesAsUppercaseRGB() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(red.hexString() == "#FF0000")
    }

    @Test func midGrayRoundsComponentsToBytes() {
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        // 0.5 * 255 = 127.5 -> Int truncates to 127 -> 0x7F
        #expect(gray.hexString() == "#7F7F7F")
    }

    @Test func includeAlphaAppendsAlphaByte() {
        let translucent = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        #expect(translucent.hexString(includeAlpha: true) == "#0000FF7F")
    }

    @Test func eightDigitHexParsesAlphaByte() throws {
        let color = try #require(NSColor(hex: "#33669980")?.usingColorSpace(.sRGB))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #expect(abs(red - (CGFloat(0x33) / 255.0)) < 0.001)
        #expect(abs(green - (CGFloat(0x66) / 255.0)) < 0.001)
        #expect(abs(blue - (CGFloat(0x99) / 255.0)) < 0.001)
        #expect(abs(alpha - (CGFloat(0x80) / 255.0)) < 0.001)
    }

    @Test func alphaIsOmittedByDefault() {
        let translucent = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.25)
        #expect(translucent.hexString() == "#00FF00")
    }
}
