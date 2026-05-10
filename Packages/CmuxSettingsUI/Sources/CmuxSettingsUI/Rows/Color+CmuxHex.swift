import AppKit
import SwiftUI

/// `#RRGGBB` / `#RRGGBBAA` hex conversion for `Color`, used by the
/// Workspace Colors pickers.
public extension Color {
    /// Creates a color from a `#RRGGBB`, `RRGGBB`, `#RRGGBBAA`, or
    /// `RRGGBBAA` hex string.
    init?(cmuxHex hex: String) {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard let intVal = UInt32(trimmed, radix: 16) else { return nil }
        switch trimmed.count {
        case 6:
            let r = Double((intVal >> 16) & 0xFF) / 255
            let g = Double((intVal >> 8) & 0xFF) / 255
            let b = Double(intVal & 0xFF) / 255
            self.init(red: r, green: g, blue: b)
        case 8:
            let r = Double((intVal >> 24) & 0xFF) / 255
            let g = Double((intVal >> 16) & 0xFF) / 255
            let b = Double((intVal >> 8) & 0xFF) / 255
            let a = Double(intVal & 0xFF) / 255
            self.init(red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }

    /// The color rendered as a `#RRGGBB` string in the sRGB color space.
    var cmuxHexString: String {
        cmuxHexString(includeAlpha: false)
    }

    /// The color rendered as a hex string in the sRGB color space.
    func cmuxHexString(includeAlpha: Bool) -> String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        if includeAlpha {
            let a = Int((rgb.alphaComponent * 255).rounded())
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
