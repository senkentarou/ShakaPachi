// AccentColorTests.swift
// Verifies: .system returns NSColor.controlAccentColor, every case has a
// non-empty displayName, rawValue round-trips work for all cases, and the
// Settings.accentColor property defaults to .system and persists correctly.

import XCTest

@testable import ShakaPachi

@MainActor
final class AccentColorTests: XCTestCase {

    // MARK: - Helpers

    private func makeSuite(name: String = #function) -> (UserDefaults, Settings) {
        let suiteName = "com.shakapachi.tests.AccentColorTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, settings)
    }

    // MARK: - .system uses NSColor.controlAccentColor

    func testSystem_nsColor_isControlAccentColor() {
        XCTAssertEqual(
            AccentColor.system.nsColor,
            NSColor.controlAccentColor,
            ".system.nsColor must return NSColor.controlAccentColor"
        )
    }

    // MARK: - Every case has a non-empty displayName

    func testAllCases_displayNameNonEmpty() {
        for color in AccentColor.allCases {
            XCTAssertFalse(
                color.displayName.isEmpty,
                "displayName for .\(color) must not be empty"
            )
        }
    }

    // MARK: - rawValue round-trips for all cases

    func testRawValueRoundTrip_allCases() {
        for color in AccentColor.allCases {
            let raw = color.rawValue
            let recovered = AccentColor(rawValue: raw)
            XCTAssertEqual(
                recovered, color,
                "AccentColor(rawValue: \"\(raw)\") should round-trip to .\(color)"
            )
        }
    }

    // MARK: - Settings.accentColor defaults to .system

    func testDefault_accentColor_isSystem() {
        let (_, settings) = makeSuite()
        XCTAssertEqual(
            settings.accentColor, .system,
            "Default accentColor must be .system"
        )
    }

    // MARK: - Settings.accentColor persists a set value

    func testPersistence_accentColor_roundTrips() {
        let (_, settings) = makeSuite()
        for color in AccentColor.allCases {
            settings.accentColor = color
            XCTAssertEqual(
                settings.accentColor, color,
                "accentColor must persist .\(color) and read it back"
            )
        }
    }
}
