// StatsStore.swift
// Lightweight switch-count statistics, persisted to UserDefaults.
//
// Design notes:
// - Backed by an injected UserDefaults so tests can isolate state cleanly.
// - todayCount resets at the local calendar midnight; comparison is done by
//   the "yyyy-MM-dd" string in the local timezone to avoid UTC skew.
// - Does NOT post .settingsDidChange — stats are decoupled from the settings
//   broadcast so observers don't redraw on every switch.
// - Stores only aggregate integers and a date string — never which apps or
//   windows were visited (privacy by design).

import Foundation

@MainActor
final class StatsStore {

    // MARK: - UserDefaults keys

    private enum Key {
        static let totalCount  = "statsTotalCount"
        static let todayCount  = "statsTodayCount"
        static let todayDate   = "statsTodayDate"
    }

    // MARK: - Backing store

    // nonisolated(unsafe) mirrors the pattern in Settings: StatsStore is
    // @MainActor-isolated, so all access happens on the main thread.
    // UserDefaults is thread-safe for simple reads/writes.
    nonisolated(unsafe) private let defaults: UserDefaults

    // MARK: - Shared instance

    /// The single production instance, backed by UserDefaults.standard.
    /// AppDelegate and SettingsWindow both read from this so they see the same counts.
    static let shared = StatsStore()

    // MARK: - Init

    /// Creates a StatsStore backed by the given UserDefaults.
    /// - Parameter defaults: Pass `.standard` in production; pass a test
    ///   suite in unit tests to avoid polluting the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public properties

    /// Lifetime switch count, persisted across launches.
    var totalCount: Int {
        defaults.integer(forKey: Key.totalCount)
    }

    /// Switches counted today (local calendar day). Resets at midnight.
    var todayCount: Int {
        defaults.integer(forKey: Key.todayCount)
    }

    // MARK: - Public API

    /// Record one window switch at the given instant.
    ///
    /// - Parameter now: The current time. Defaults to `Date()`.
    ///   Pass a synthetic date in tests to verify day-rollover behaviour.
    func recordSwitch(now: Date = Date()) {
        let today = Self.localDateString(from: now)
        let storedDate = defaults.string(forKey: Key.todayDate) ?? ""

        // Reset the daily counter when the calendar day has changed.
        if storedDate != today {
            defaults.set(0, forKey: Key.todayCount)
            defaults.set(today, forKey: Key.todayDate)
        }

        let newToday = defaults.integer(forKey: Key.todayCount) + 1
        let newTotal = defaults.integer(forKey: Key.totalCount) + 1
        defaults.set(newToday, forKey: Key.todayCount)
        defaults.set(newTotal, forKey: Key.totalCount)
    }

    // MARK: - Private helpers

    /// Format a Date as "yyyy-MM-dd" in the current locale/timezone.
    private static func localDateString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale.current
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }
}
