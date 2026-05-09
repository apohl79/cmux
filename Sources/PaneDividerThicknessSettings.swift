import AppKit
import Foundation

/// User-configurable thickness override for the divider drawn between panes.
/// Stored in points (CGFloat). Default is 1.0 to match the system thin style.
enum PaneDividerThicknessSettings {
    static let key = "paneDividerThicknessPoints"

    static let defaultPoints: CGFloat = 1
    static let minPoints: CGFloat = 1
    static let maxPoints: CGFloat = 6

    /// Effective thickness (clamped) for use in ThemedSplitView. Always returns
    /// a concrete value; when no override is configured returns `defaultPoints`.
    static func effectivePoints(defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return defaultPoints }
        let raw = defaults.double(forKey: key)
        return clamp(CGFloat(raw))
    }

    /// Override value if set, else nil. Used by bonsplit when deciding whether
    /// to override NSSplitView's dividerThickness.
    static func overridePoints(defaults: UserDefaults = .standard) -> CGFloat? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let raw = defaults.double(forKey: key)
        let clamped = clamp(CGFloat(raw))
        return clamped == defaultPoints ? nil : clamped
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minPoints), maxPoints)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
