// AppearancePreviewView.swift
// A live preview of the switcher panel colors shown in the Appearance (外観) settings tab.
//
// Design: the preview must faithfully reproduce the real panel's colors so the
// user sees exactly what they'll get. Color logic lives in a pure, testable
// enum (AppearancePreview) with no SwiftUI dependency; the view composes it.

import AppKit
import SwiftUI

// MARK: - Pure color helper (testable without SwiftUI)

/// Computes the preview colors that approximate the real switcher panel.
/// All methods are pure functions — no side effects, no SwiftUI, no @MainActor.
enum AppearancePreview {

    /// Opaque base color approximating the switcher panel's popover material
    /// for the given theme. `systemIsDark` is used only for Theme.system.
    ///
    /// These are opaque approximations of the translucent NSVisualEffectView
    /// .popover material — the actual material blends with whatever is behind
    /// the panel, so we pick representative sRGB values for a neutral desktop.
    static func backgroundBaseColor(theme: Theme, systemIsDark: Bool) -> NSColor {
        let isDark: Bool
        switch theme {
        case .light:  isDark = false
        case .dark:   isDark = true
        case .system: isDark = systemIsDark
        }
        if isDark {
            // Near-black — representative dark popover on a dark desktop.
            return NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
        } else {
            // Near-white — representative light popover on a light desktop.
            return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        }
    }

    /// The accent tint drawn over the panel base (accent at backgroundTintAlpha).
    static func tintColor(accent: AccentColor) -> NSColor {
        accent.nsColor.withAlphaComponent(AccentColor.backgroundTintAlpha)
    }

    /// The selected-tile highlight color (accent at selectionHighlightAlpha).
    static func selectionColor(accent: AccentColor) -> NSColor {
        accent.nsColor.withAlphaComponent(AccentColor.selectionHighlightAlpha)
    }
}

// MARK: - SwiftUI preview view

/// A mini mock of the switcher panel showing the chosen theme + accent color.
/// Passed as arguments rather than reading Settings directly so the struct
/// stays a pure, reusable view (the parent decides when to re-render).
struct AppearancePreviewView: View {

    let theme: Theme
    let accent: AccentColor

    // Used to resolve Theme.system to light or dark base color.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let systemIsDark = colorScheme == .dark
        let base = AppearancePreview.backgroundBaseColor(theme: theme, systemIsDark: systemIsDark)
        let tint = AppearancePreview.tintColor(accent: accent)
        let selection = AppearancePreview.selectionColor(accent: accent)

        // Resolve the preview's own color scheme from the chosen theme so the
        // foreground semantic colors (.secondary icon/title) flip to match the
        // mock panel's base — otherwise picking a theme opposite to the current
        // system appearance (e.g. Dark while the OS is Light) would render
        // low-contrast chrome on top of the flipped base color.
        let resolvedScheme: ColorScheme = {
            switch theme {
            case .light:  return .light
            case .dark:   return .dark
            case .system: return colorScheme
            }
        }()

        ZStack {
            // Panel background: base color overlaid with the accent tint, matching
            // how SwitcherPanel composites tintLayer over the NSVisualEffectView.
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: base))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: tint))
                )
            // Glass rim — 1px light border reads as the edge of a liquid pane,
            // matching the real panel's ev.layer?.borderColor.
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(AccentColor.glassBorderAlpha), lineWidth: 1)
                )

            // Content: icon row + title line
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        TileView(isSelected: index == 1, selectionColor: selection)
                    }
                }
                Text("ウィンドウ名")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 100)
        .environment(\.colorScheme, resolvedScheme)
    }
}

// MARK: - Tile subview

/// A single icon tile in the preview row.
private struct TileView: View {

    let isSelected: Bool
    let selectionColor: NSColor

    var body: some View {
        ZStack {
            if isSelected {
                // Highlight fill matching SwitcherListView's selection draw path.
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: selectionColor))
            }
            // Placeholder icon — uses a semantic color so it stays legible on
            // both light and dark base colors without forcing a colorScheme override.
            Image(systemName: "macwindow")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
        }
        .frame(width: 44, height: 44)
    }
}
