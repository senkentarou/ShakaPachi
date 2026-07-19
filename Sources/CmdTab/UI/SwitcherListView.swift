// SwitcherListView.swift
// §7.3 (amended by user decision): native App-Switcher-style horizontal
// icon-tile row instead of the spec's vertical list. Each tile is ONE WINDOW
// (not an app) — windows of the same app repeat the app icon, AltTab-style —
// and the selected window's title is drawn beneath the row.
// Custom draw(_:) implementation (§7.3's fallback path): tiles plus a single
// title line, so a full pass is trivial and §7.5 selective redraw reduces to
// invalidating two tile rects plus the title strip.

import AppKit

// MARK: - SwitcherItem

/// Lightweight value type carrying display data for one row.
/// Step 7 uses dummy data; Step 8 wires this to real WindowInfo.
public struct SwitcherItem: Equatable {
    public let icon: NSImage?
    public let title: String

    public init(icon: NSImage?, title: String) {
        self.icon = icon
        self.title = title
    }
}

// MARK: - Layout constants shared with SwitcherPanel

/// Shared layout constants used by both the tile row and the panel.
/// All geometry functions are pure — unit-testable.
public enum SwitcherLayout {
    /// Square highlight tile per window (§7.4 amended).
    public static let tileSize: CGFloat = 76
    /// App icon drawn centered inside the tile.
    public static let iconSize: CGFloat = 60
    /// Gap between adjacent tiles.
    public static let tileSpacing: CGFloat = 8
    /// Left/right panel margin around the tile row.
    public static let horizontalMargin: CGFloat = 20
    /// Space above the tile row.
    public static let topPadding: CGFloat = 20
    /// Gap between the tile row and the title line.
    public static let titleGap: CGFloat = 6
    /// Height of the selected-window title line.
    public static let titleHeight: CGFloat = 20
    /// Space below the title line.
    public static let bottomPadding: CGFloat = 14

    /// Total panel size for a given window count.
    public static func panelSize(itemCount: Int) -> NSSize {
        let count = max(itemCount, 1)
        let width = horizontalMargin * 2
                  + CGFloat(count) * tileSize
                  + CGFloat(count - 1) * tileSpacing
        let height = topPadding + tileSize + titleGap + titleHeight + bottomPadding
        return NSSize(width: width, height: height)
    }

    /// Tile rect for the given index, in flipped (top-left origin) coordinates.
    public static func tileRect(index: Int) -> NSRect {
        NSRect(
            x: horizontalMargin + CGFloat(index) * (tileSize + tileSpacing),
            y: topPadding,
            width: tileSize,
            height: tileSize
        )
    }

    /// Advance the selection index by +1 with wrap-around (§6.2).
    public static func advanceIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// The tile indices needing redraw when the selection moves (§7.5).
    public static func indicesToRedraw(old: Int, new: Int) -> IndexSet {
        var set = IndexSet()
        set.insert(old)
        if new != old { set.insert(new) }
        return set
    }
}

// MARK: - Dummy data

/// Dummy windows used in Step 7 (replaced by real data in Step 8).
/// Two Safari entries demonstrate the window-level model: same app icon
/// repeated, distinguished by the title below the row.
public let dummySwitcherItems: [SwitcherItem] = {
    func sfImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
    }
    return [
        SwitcherItem(icon: sfImage("safari"),     title: "Safari — GitHub"),
        SwitcherItem(icon: sfImage("safari"),     title: "Safari — Qiita"),
        SwitcherItem(icon: sfImage("terminal"),   title: "ターミナル — ~/work/cmdtab"),
        SwitcherItem(icon: sfImage("envelope"),   title: "メール — 受信トレイ (3)"),
        SwitcherItem(icon: sfImage("music.note"), title: "ミュージック — 再生中"),
        SwitcherItem(icon: sfImage("doc.text"),   title: "テキストエディット — 仕様書.txt"),
        SwitcherItem(icon: sfImage("folder"),     title: "Finder — ダウンロード"),
        SwitcherItem(icon: sfImage("gearshape"),  title: "システム設定 — 一般"),
    ]
}()

// MARK: - SwitcherListView

/// Horizontal icon-tile row with the selected window's title beneath it.
/// Fully custom-drawn: no subviews, no Auto Layout in the hot path.
final class SwitcherListView: NSView {

    // MARK: State

    private var items: [SwitcherItem] = []
    private(set) var selectedIndex: Int = 0

    // Top-left origin so tile math matches SwitcherLayout directly.
    override var isFlipped: Bool { true }

    // MARK: Public API

    /// Replace the full item list and select the given index.
    func setItems(_ items: [SwitcherItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = clamp(selectedIndex, count: items.count)
        needsDisplay = true
    }

    /// Move the selection highlight, invalidating only the two affected tiles
    /// and the title strip (§7.5).
    func moveSelection(to newIndex: Int) {
        let old = selectedIndex
        let new = clamp(newIndex, count: items.count)
        guard new != old else { return }

        selectedIndex = new
        for index in SwitcherLayout.indicesToRedraw(old: old, new: new) {
            setNeedsDisplay(SwitcherLayout.tileRect(index: index).insetBy(dx: -2, dy: -2))
        }
        setNeedsDisplay(titleRect)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in items.enumerated() {
            let tile = SwitcherLayout.tileRect(index: index)
            guard tile.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }

            if index == selectedIndex {
                // Neutral rounded highlight like the native App Switcher.
                let highlight = NSBezierPath(roundedRect: tile, xRadius: 14, yRadius: 14)
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                highlight.fill()
            }

            let inset = (SwitcherLayout.tileSize - SwitcherLayout.iconSize) / 2
            let iconRect = tile.insetBy(dx: inset, dy: inset)
            item.icon?.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        }

        if titleRect.intersects(dirtyRect), items.indices.contains(selectedIndex) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle   // §7.4 middle truncation
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let textRect = titleRect.insetBy(dx: SwitcherLayout.horizontalMargin, dy: 0)
            (items[selectedIndex].title as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    // MARK: Private helpers

    private var titleRect: NSRect {
        NSRect(
            x: 0,
            y: SwitcherLayout.topPadding + SwitcherLayout.tileSize + SwitcherLayout.titleGap,
            width: bounds.width,
            height: SwitcherLayout.titleHeight
        )
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }
}
