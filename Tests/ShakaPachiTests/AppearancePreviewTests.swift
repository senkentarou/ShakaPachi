// AppearancePreviewTests.swift
// Verifies: alpha constants haven't drifted, tint/selection colors carry the
// correct alpha, selection shares the accent hue, and backgroundBaseColor
// produces distinct light/dark values and respects Theme.system.

import XCTest
@testable import ShakaPachi

@MainActor
final class AppearancePreviewTests: XCTestCase {

    // MARK: - Alpha constant drift guards

    func testBackgroundTintAlpha_isExact() {
        XCTAssertEqual(AccentColor.backgroundTintAlpha, 0.14,
                       "backgroundTintAlpha must be 0.14 — changing it drifts the preview from the real panel")
    }

    func testSelectionHighlightAlpha_isExact() {
        XCTAssertEqual(AccentColor.selectionHighlightAlpha, 0.30,
                       "selectionHighlightAlpha must be 0.30 — changing it drifts the preview from the real panel")
    }

    // MARK: - tintColor alpha

    func testTintColor_alpha_matchesConstant() throws {
        // Use .blue — a static sRGB color that reads back reliably (unlike
        // .system which is a dynamic catalog color and doesn't expose alpha).
        let color = AppearancePreview.tintColor(accent: .blue)
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB),
                                 "Failed to convert tintColor to sRGB")
        XCTAssertEqual(srgb.alphaComponent, AccentColor.backgroundTintAlpha, accuracy: 0.001,
                       "tintColor alpha must equal backgroundTintAlpha")
    }

    // MARK: - selectionColor alpha

    func testSelectionColor_alpha_matchesConstant() throws {
        let color = AppearancePreview.selectionColor(accent: .blue)
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB),
                                 "Failed to convert selectionColor to sRGB")
        XCTAssertEqual(srgb.alphaComponent, AccentColor.selectionHighlightAlpha, accuracy: 0.001,
                       "selectionColor alpha must equal selectionHighlightAlpha")
    }

    // MARK: - selectionColor shares the accent hue

    func testSelectionColor_sharesAccentHue_blue() throws {
        // Both colors must be in sRGB before comparing components; otherwise
        // dynamic catalog colors return arbitrary component values.
        let selSRGB = try XCTUnwrap(
            AppearancePreview.selectionColor(accent: .blue).usingColorSpace(.sRGB),
            "selectionColor(.blue) not representable in sRGB")
        let accentSRGB = try XCTUnwrap(
            AccentColor.blue.nsColor.usingColorSpace(.sRGB),
            "AccentColor.blue.nsColor not representable in sRGB")

        // Premultiplied vs straight: selectionColor has alpha < 1; nsColor has alpha = 1.
        // Compare the RGB triplet (alpha-independent) to confirm they share the same hue.
        XCTAssertEqual(selSRGB.redComponent,   accentSRGB.redComponent,   accuracy: 0.001)
        XCTAssertEqual(selSRGB.greenComponent, accentSRGB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.blueComponent,  accentSRGB.blueComponent,  accuracy: 0.001)
    }

    func testSelectionColor_sharesAccentHue_teal() throws {
        let selSRGB = try XCTUnwrap(
            AppearancePreview.selectionColor(accent: .teal).usingColorSpace(.sRGB),
            "selectionColor(.teal) not representable in sRGB")
        let accentSRGB = try XCTUnwrap(
            AccentColor.teal.nsColor.usingColorSpace(.sRGB),
            "AccentColor.teal.nsColor not representable in sRGB")

        XCTAssertEqual(selSRGB.redComponent,   accentSRGB.redComponent,   accuracy: 0.001)
        XCTAssertEqual(selSRGB.greenComponent, accentSRGB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(selSRGB.blueComponent,  accentSRGB.blueComponent,  accuracy: 0.001)
    }

    // MARK: - backgroundBaseColor light vs dark

    func testBackgroundBaseColor_lightAndDarkDiffer() {
        let light = AppearancePreview.backgroundBaseColor(theme: .light, systemIsDark: false)
        let dark  = AppearancePreview.backgroundBaseColor(theme: .dark,  systemIsDark: false)
        // Light base should have a higher red component than the dark base.
        let lightSRGB = light.usingColorSpace(.sRGB)!
        let darkSRGB  = dark.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(lightSRGB.redComponent, darkSRGB.redComponent,
                             "Light base must be brighter than dark base")
    }

    func testBackgroundBaseColor_system_followsSystemIsDark() {
        let dark  = AppearancePreview.backgroundBaseColor(theme: .dark,   systemIsDark: false)
        let light = AppearancePreview.backgroundBaseColor(theme: .light,  systemIsDark: false)

        let sysWhenDark  = AppearancePreview.backgroundBaseColor(theme: .system, systemIsDark: true)
        let sysWhenLight = AppearancePreview.backgroundBaseColor(theme: .system, systemIsDark: false)

        // .system resolves to the dark value when systemIsDark is true.
        XCTAssertEqual(sysWhenDark.usingColorSpace(.sRGB)!.redComponent,
                       dark.usingColorSpace(.sRGB)!.redComponent,
                       accuracy: 0.001,
                       "Theme.system + systemIsDark:true must equal the .dark base color")

        // .system resolves to the light value when systemIsDark is false.
        XCTAssertEqual(sysWhenLight.usingColorSpace(.sRGB)!.redComponent,
                       light.usingColorSpace(.sRGB)!.redComponent,
                       accuracy: 0.001,
                       "Theme.system + systemIsDark:false must equal the .light base color")
    }
}
