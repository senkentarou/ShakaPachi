// TrayIconRenderer.swift
// Shared rendering + copy for the four menu-bar icon states ("cards").
// Used by StatusItemController (the live menu-bar icon) and the Settings
// 「状態」 tab (preview + explanation), so the glyph geometry and the state
// colours are defined in exactly one place.

import AppKit

/// The four menu-bar icon states, framed as coloured "cards" for the user.
/// Live-icon precedence is permission > restricted > settings > normal
/// (see StatusItemController.refreshIcon); the case order here is the
/// explanation order shown to the user (normal → blue → yellow → red).
enum TrayIconState: CaseIterable {
    case normal      // ノーマルカード
    case settings    // ブルーカード
    case permission  // イエローカード
    case restricted  // レッドカード

    /// User-facing card name.
    var cardName: String {
        switch self {
        case .normal:     return "ノーマルカード"
        case .settings:   return "ブルーカード"
        case .permission: return "イエローカード"
        case .restricted: return "レッドカード"
        }
    }

    /// One-line explanation shown under the card name.
    var detail: String {
        switch self {
        case .normal:
            return "機能が有効な状態です。"
        case .settings:
            return "設定画面を開いている状態です。ShakaPachi ではウィンドウの移動ができないことがあるため、設定を閉じてください。"
        case .permission:
            return "利用に必要な権限が足りない状態です。mac の設定から権限を追加してください。"
        case .restricted:
            return "ShakaPachi の利用を一時的に制限している状態です。mac 標準のアプリ切り替え機能にフォールバックします。"
        }
    }

    /// Colour applied to the *filled* front window. Only the fill is tinted;
    /// the outline stays neutral (要件: 塗りつぶし部分のみ色を変える). Normal uses the
    /// adaptive label colour so the glyph matches the menu bar as before.
    var fillColor: NSColor {
        switch self {
        case .normal:     return .labelColor
        case .settings:   return NSColor(srgbRed: 0.52, green: 0.68, blue: 0.92, alpha: 1.0) // soft blue
        case .permission: return NSColor(srgbRed: 0.95, green: 0.81, blue: 0.45, alpha: 1.0) // soft amber
        case .restricted: return NSColor(srgbRed: 0.92, green: 0.53, blue: 0.51, alpha: 1.0) // soft coral
        }
    }
}

enum TrayIconRenderer {

    /// Menu-bar icon (18×18). Normal is a template image so it adapts to the
    /// menu-bar appearance exactly as before. Coloured states are non-template:
    /// only the front-window fill carries the state colour; the outline is the
    /// adaptive label colour.
    static func menuBarImage(for state: TrayIconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if state == .normal {
            let image = NSImage(size: size, flipped: false) { bounds in
                drawGlyph(in: bounds, outline: .black, fill: .black)
                return true
            }
            image.isTemplate = true
            return image
        }
        let fill = state.fillColor
        let image = NSImage(size: size, flipped: false) { bounds in
            drawGlyph(in: bounds, outline: .labelColor, fill: fill)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Larger preview used in the Settings 「状態」 tab. Always non-template and
    /// concrete: outline in the adaptive label colour, fill in the state colour.
    static func previewImage(for state: TrayIconState, size: CGFloat) -> NSImage {
        let px = NSSize(width: size, height: size)
        let fill = state.fillColor
        let image = NSImage(size: px, flipped: false) { bounds in
            drawGlyph(in: bounds, outline: .labelColor, fill: fill)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws the ShakaPachi glyph — two overlapping windows — with the back
    /// window as an outline (`outline`) and the front window as a solid fill
    /// (`fill`) with a matching-`outline` border. Splitting outline vs fill lets
    /// callers tint only the filled area. Geometry mirrors the app icon
    /// (back lower-left, front upper-right).
    static func drawGlyph(in bounds: NSRect, outline: NSColor, fill: NSColor) {
        let s = bounds.width / 16.0
        let w = 9.5 * s
        let r = 1.65 * s
        let line = 1.3 * s

        // Back window frame (outline) — lower-left.
        outline.setStroke()
        let backRect = NSRect(x: bounds.minX + 1.25 * s, y: bounds.minY + 1.25 * s, width: w, height: w)
        let back = NSBezierPath(roundedRect: backRect, xRadius: r, yRadius: r)
        back.lineWidth = line
        back.stroke()

        // Front window — upper-right: state-coloured fill, neutral outline border
        // so only the filled area carries the colour.
        let frontRect = NSRect(x: bounds.minX + 5.25 * s, y: bounds.minY + 5.25 * s, width: w, height: w)
        let front = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)
        fill.setFill()
        front.fill()
        outline.setStroke()
        front.lineWidth = line
        front.stroke()
    }
}
