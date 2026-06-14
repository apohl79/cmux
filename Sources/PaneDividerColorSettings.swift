import AppKit
import Foundation

/// User-configurable override for the color of dividers between panes.
/// When unset, bonsplit derives the divider color from the chrome background.
enum PaneDividerColorSettings {
    static let lightHexKey = "paneDividerHexLight"
    static let darkHexKey = "paneDividerHexDark"

    /// Hex string (`#RRGGBB` or `#RRGGBBAA`) for the current effective appearance,
    /// or `nil` to fall back to bonsplit's auto-derived divider color.
    static func effectiveHex(
        defaults: UserDefaults = .standard,
        appAppearance: NSAppearance? = nil
    ) -> String? {
        let preference = AppearanceSettings.colorSchemePreference(
            appAppearance: appAppearance,
            defaults: defaults
        )
        let key: String = (preference == .dark) ? darkHexKey : lightHexKey
        guard let raw = defaults.string(forKey: key), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    static func hasOverride(defaults: UserDefaults = .standard) -> Bool {
        let light = defaults.string(forKey: lightHexKey) ?? ""
        let dark = defaults.string(forKey: darkHexKey) ?? ""
        return !light.isEmpty || !dark.isEmpty
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lightHexKey)
        defaults.removeObject(forKey: darkHexKey)
    }
}
