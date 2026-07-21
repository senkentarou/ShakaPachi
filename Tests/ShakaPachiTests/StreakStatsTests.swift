// StreakStatsTests.swift
// Verifies: thresholds compute correct percentiles, level mapping covers 0–4,
// currentStreak handles today-active / grace-period / gap / empty cases,
// longestStreak finds the longest consecutive run.

import XCTest
@testable import ShakaPachi

final class StreakStatsTests: XCTestCase {

    // MARK: - thresholds

    func testThresholds_emptyInput_returnsDefault() {
        let t = StreakStats.thresholds(for: [])
        XCTAssertEqual(t.0, 1)
        XCTAssertEqual(t.1, 2)
        XCTAssertEqual(t.2, 3)
    }

    func testThresholds_allSameNonZero_noAllocation() {
        // All values equal — still returns valid thresholds without crash.
        let t = StreakStats.thresholds(for: [5, 5, 5, 5])
        XCTAssertEqual(t.0, 5)
        XCTAssertEqual(t.1, 5)
        XCTAssertEqual(t.2, 5)
    }

    func testThresholds_heavyDistribution_differentLevels() {
        let counts = [50, 100, 150, 200, 250, 300, 350, 400, 450, 500]
        let t = StreakStats.thresholds(for: counts)
        // p25 < p50 < p75 must hold for a spread distribution.
        XCTAssertLessThanOrEqual(t.0, t.1, "p25 must be <= p50")
        XCTAssertLessThanOrEqual(t.1, t.2, "p50 must be <= p75")
        XCTAssertLessThan(t.0, t.2, "p25 and p75 must differ for a spread distribution")
    }

    func testThresholds_zeroCountsExcluded() {
        // Only non-zero values should participate.
        let t = StreakStats.thresholds(for: [0, 0, 0, 10, 20])
        // p25 of [10, 20] = 10
        XCTAssertEqual(t.0, 10)
    }

    // MARK: - level

    func testLevel_zeroCount_isZero() {
        let t = (1, 2, 3)
        XCTAssertEqual(StreakStats.level(for: 0, thresholds: t), 0)
    }

    func testLevel_belowP25_isOne() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 5, thresholds: t), 1)
        XCTAssertEqual(StreakStats.level(for: 10, thresholds: t), 1)
    }

    func testLevel_betweenP25andP50_isTwo() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 11, thresholds: t), 2)
        XCTAssertEqual(StreakStats.level(for: 20, thresholds: t), 2)
    }

    func testLevel_betweenP50andP75_isThree() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 21, thresholds: t), 3)
        XCTAssertEqual(StreakStats.level(for: 30, thresholds: t), 3)
    }

    func testLevel_aboveP75_isFour() {
        let t = (10, 20, 30)
        XCTAssertEqual(StreakStats.level(for: 31, thresholds: t), 4)
        XCTAssertEqual(StreakStats.level(for: 1000, thresholds: t), 4)
    }

    // MARK: - currentStreak

    func testCurrentStreak_todayActive_countsToday() {
        // Today + 2 prior consecutive days = streak of 3.
        let today = dateStr(2026, 7, 21)
        let active: Set<String> = [dateStr(2026, 7, 19), dateStr(2026, 7, 20), today]
        XCTAssertEqual(StreakStats.currentStreak(activeDays: active, today: today), 3)
    }

    func testCurrentStreak_todayInactive_grace_countsYesterday() {
        // Today inactive but yesterday active → grace period keeps streak alive.
        let today = dateStr(2026, 7, 21)
        let active: Set<String> = [dateStr(2026, 7, 19), dateStr(2026, 7, 20)]
        XCTAssertEqual(StreakStats.currentStreak(activeDays: active, today: today), 2)
    }

    func testCurrentStreak_gapBreaks() {
        // 2026-07-19 is missing → streak from today back to 2026-07-20 only = 1 before gap.
        let today = dateStr(2026, 7, 21)
        // active: 21, 20 (not 19) — streak should be 2.
        let active: Set<String> = [dateStr(2026, 7, 20), today]
        XCTAssertEqual(StreakStats.currentStreak(activeDays: active, today: today), 2)
    }

    func testCurrentStreak_empty_isZero() {
        let today = dateStr(2026, 7, 21)
        XCTAssertEqual(StreakStats.currentStreak(activeDays: [], today: today), 0)
    }

    func testCurrentStreak_bothTodayAndYesterdayInactive_isZero() {
        let today = dateStr(2026, 7, 21)
        // Only days before yesterday are active.
        let active: Set<String> = [dateStr(2026, 7, 19)]
        XCTAssertEqual(StreakStats.currentStreak(activeDays: active, today: today), 0)
    }

    // MARK: - longestStreak

    func testLongestStreak_empty_isZero() {
        XCTAssertEqual(StreakStats.longestStreak(activeDays: []), 0)
    }

    func testLongestStreak_singleDay_isOne() {
        XCTAssertEqual(StreakStats.longestStreak(activeDays: [dateStr(2026, 7, 21)]), 1)
    }

    func testLongestStreak_gapSelectsLongerRun() {
        // Run1: 7/1–7/3 = 3 days. Gap at 7/4. Run2: 7/5–7/9 = 5 days.
        var days: Set<String> = []
        for d in 1...3  { days.insert(dateStr(2026, 7, d)) }
        for d in 5...9  { days.insert(dateStr(2026, 7, d)) }
        XCTAssertEqual(StreakStats.longestStreak(activeDays: days), 5)
    }

    func testLongestStreak_allConsecutive() {
        var days: Set<String> = []
        for d in 1...14 { days.insert(dateStr(2026, 7, d)) }
        XCTAssertEqual(StreakStats.longestStreak(activeDays: days), 14)
    }

    // MARK: - Helpers

    private func dateStr(_ year: Int, _ month: Int, _ day: Int) -> String {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = 12
        let d = Calendar.current.date(from: c)!
        return StreakStats.stringFromDate(d)
    }
}
