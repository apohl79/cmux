public import Foundation

/// Registers cmux's Sparkle preference defaults and performs the one-time migration that
/// keeps automatic update checks disabled by default.
///
/// The `SU…` keys are the standard Sparkle `UserDefaults` keys. The check intervals are
/// configuration, so this is a value type constructed with them (defaulting to cmux's
/// hourly check) and applied to a given `UserDefaults`.
public struct UpdateSettings: Sendable {
    /// Sparkle's "automatically check for updates" key.
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    /// Sparkle's "automatically download/install updates" key.
    public static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    /// Sparkle's scheduled-check-interval key.
    public static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    /// Sparkle's "send anonymous system profile" key.
    public static let sendProfileInfoKey = "SUSendProfileInfo"
    /// cmux's marker that the v2 automatic-checks migration already ran.
    public static let migrationKey = "cmux.sparkle.automaticChecksMigration.v2"

    /// The previous default scheduled-check interval (24h) that the migration upgrades from.
    public let previousDefaultScheduledCheckInterval: TimeInterval
    /// The scheduled-check interval cmux registers (1h by default).
    public let scheduledCheckInterval: TimeInterval

    /// Creates the settings with cmux's defaults.
    ///
    /// - Parameter scheduledCheckInterval: How often Sparkle checks for updates, in seconds.
    ///   Defaults to one hour.
    /// - Parameter previousDefaultScheduledCheckInterval: The legacy interval the migration
    ///   upgrades away from when it sees it persisted. Defaults to 24 hours.
    public init(scheduledCheckInterval: TimeInterval = 60 * 60,
                previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24) {
        self.scheduledCheckInterval = scheduledCheckInterval
        self.previousDefaultScheduledCheckInterval = previousDefaultScheduledCheckInterval
    }

    /// Registers the update defaults on `defaults` and runs the one-time migration.
    ///
    /// Registration is idempotent. The migration (guarded by ``migrationKey``) disables
    /// automatic checks/downloads and writes the configured scheduled check interval.
    public func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            Self.automaticChecksKey: false,
            Self.automaticallyUpdateKey: false,
            Self.scheduledCheckIntervalKey: scheduledCheckInterval,
            Self.sendProfileInfoKey: false,
        ])

        guard !defaults.bool(forKey: Self.migrationKey) else { return }

        defaults.set(false, forKey: Self.automaticChecksKey)
        defaults.set(false, forKey: Self.automaticallyUpdateKey)
        defaults.set(false, forKey: Self.sendProfileInfoKey)
        defaults.set(scheduledCheckInterval, forKey: Self.scheduledCheckIntervalKey)

        defaults.set(true, forKey: Self.migrationKey)
    }
}
