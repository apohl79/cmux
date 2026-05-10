import AppKit
import Foundation

/// User-configurable height for the shared chrome bar that backs the app
/// titlebar (workspace tabs), the bonsplit per-pane tab bar, and the
/// secondary titlebar. Stored in points (CGFloat). Default is 28 to match
/// the previous hardcoded value.
enum ChromeBarHeightSettings {
    static let key = "chromeBarHeightPoints"

    static let defaultPoints: CGFloat = 28
    static let minPoints: CGFloat = 20
    static let maxPoints: CGFloat = 50

    /// Effective chrome bar height for use in WindowChromeMetrics. Always
    /// returns a concrete value clamped to the configured range; when no
    /// override is configured returns `defaultPoints`.
    static func effectivePoints(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return defaultPoints }
        let raw = defaults.double(forKey: key)
        return clamp(CGFloat(raw))
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minPoints), maxPoints)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
