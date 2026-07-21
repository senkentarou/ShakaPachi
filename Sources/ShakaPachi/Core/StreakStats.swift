// StreakStats.swift
// Pure functions for computing streak and heatmap level from daily switch counts.
// AppKit-independent and @MainActor-free so they are easily unit-tested.

import Foundation

enum StreakStats {

    // MARK: - Thresholds

    /// Compute relative-scale thresholds (p25, p50, p75) from an array of counts.
    ///
    /// Only non-zero values participate so that inactive days don't compress the scale.
    /// Returns (1, 2, 3) when there are no active days to avoid division by zero.
    static func thresholds(for counts: [Int]) -> (Int, Int, Int) {
        let active = counts.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return (1, 2, 3) }
        func percentile(_ p: Double) -> Int {
            // Nearest-rank method.
            let idx = max(0, Int(ceil(p * Double(active.count))) - 1)
            return active[min(idx, active.count - 1)]
        }
        return (percentile(0.25), percentile(0.50), percentile(0.75))
    }

    // MARK: - Level

    /// Map a switch count to a display level 0–4.
    ///
    /// - 0: no activity
    /// - 1–4: increasing intensity based on relative thresholds
    static func level(for count: Int, thresholds t: (Int, Int, Int)) -> Int {
        guard count > 0 else { return 0 }
        if count <= t.0 { return 1 }
        if count <= t.1 { return 2 }
        if count <= t.2 { return 3 }
        return 4
    }

    // MARK: - Current streak

    /// Returns the number of consecutive active days ending at or before today.
    ///
    /// If today is active the streak includes today; otherwise we allow a one-day
    /// grace period so a streak stays alive if the user hasn't switched yet today.
    static func currentStreak(activeDays: Set<String>, today: String) -> Int {
        guard let todayDate = dateFromString(today) else { return 0 }

        // Decide start: today if active, yesterday otherwise (grace period).
        let startDate: Date
        if activeDays.contains(today) {
            startDate = todayDate
        } else {
            guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayDate),
                  activeDays.contains(stringFromDate(yesterday)) else { return 0 }
            startDate = yesterday
        }

        // Walk backwards counting consecutive active days.
        var count = 0
        var cursor = startDate
        while true {
            let key = stringFromDate(cursor)
            guard activeDays.contains(key) else { break }
            count += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    // MARK: - Longest streak

    /// Returns the length of the longest consecutive run of active days.
    static func longestStreak(activeDays: Set<String>) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        // Convert strings to day numbers (days since reference) and sort.
        let ref = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let dayNumbers: [Int] = activeDays.compactMap { s in
            guard let d = dateFromString(s) else { return nil }
            let comps = Calendar.current.dateComponents([.day], from: ref, to: d)
            return comps.day
        }.sorted()
        guard !dayNumbers.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1 ..< dayNumbers.count {
            if dayNumbers[i] == dayNumbers[i - 1] + 1 {
                current += 1
                longest = max(longest, current)
            } else if dayNumbers[i] != dayNumbers[i - 1] {
                current = 1
            }
        }
        return longest
    }

    // MARK: - Private helpers

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.calendar = Calendar.current
        return f
    }()

    static func dateFromString(_ s: String) -> Date? {
        formatter.date(from: s)
    }

    static func stringFromDate(_ d: Date) -> String {
        formatter.string(from: d)
    }
}
