// SwitcherListView.swift
// §7.3 (amended by user decision): native App-Switcher-style horizontal
// icon-tile row instead of the spec's vertical list. Each tile is ONE WINDOW
// (not an app) — windows of the same app repeat the app icon, AltTab-style —
// and the selected window's title is drawn beneath the row.
// Custom draw(_:) implementation (§7.3's fallback path): tiles plus a single
// title line, so a full pass is trivial and §7.5 selective redraw reduces to
// invalidating two tile rects plus the title strip.

import AppKit
import CoreGraphics

// MARK: - SwitcherItem

/// Lightweight value type carrying display data for one row.
/// Step 7 uses dummy data; Step 8 wires this to real WindowInfo.
public struct SwitcherItem: Equatable {
    public let icon: NSImage?
    public let title: String
    /// CGWindowID for the window preview cache lookup.
    /// 0 is a safe sentinel for items that have no associated window (e.g. tests).
    public let windowID: CGWindowID

    public init(icon: NSImage?, title: String, windowID: CGWindowID = 0) {
        self.icon = icon
        self.title = title
        self.windowID = windowID
    }
}

// MARK: - Layout constants shared with SwitcherPanel

/// Shared layout constants used by both the tile row and the panel.
/// All geometry functions are pure — unit-testable.
public enum SwitcherLayout {
    /// Square highlight tile per window (§7.4 amended) — the nominal (maximum) size.
    public static let tileSize: CGFloat = 76
    /// App icon drawn centered inside the nominal tile.
    public static let iconSize: CGFloat = 60
    /// Minimum tile edge when shrink-to-fit kicks in (Step 8).
    public static let minTileSize: CGFloat = 40
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

    // MARK: - Window preview constants

    /// Width of the optional live-preview pane (16:10 ratio with previewHeight).
    public static let previewWidth: CGFloat = 320
    /// Height of the optional live-preview pane.
    public static let previewHeight: CGFloat = 200
    /// Gap between the title line and the top of the preview pane.
    public static let previewTopGap: CGFloat = 10

    // MARK: - Shrink-to-fit (Step 8)

    /// Return the effective tile edge so that all `itemCount` tiles fit inside
    /// `availableWidth`.  The result is clamped to [minTileSize, tileSize].
    ///
    /// The formula solves for `t` in:
    ///   margin*2 + count*t + (count-1)*spacing ≤ availableWidth
    ///   → t ≤ (availableWidth - margin*2 + spacing) / (count + spacing/t)
    /// Simplified (spacing treated proportionally):
    ///   t = (availableWidth - margin*2 + spacing) / count - spacing
    ///   but clamped so it never goes below minTileSize.
    ///
    /// Below minTileSize the tiles are allowed to clip off-screen (acceptable,
    /// rare edge case per spec).
    public static func effectiveTileSize(itemCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard itemCount > 0 else { return tileSize }
        let natural = panelSize(itemCount: itemCount).width
        if natural <= availableWidth {
            return tileSize   // fits at full size — no shrink needed
        }
        // Largest t such that: margin*2 + count*t + (count-1)*spacing ≤ availableWidth
        //   t ≤ (availableWidth - margin*2 - (count-1)*spacing) / count
        let usable = availableWidth - horizontalMargin * 2
                     - CGFloat(itemCount - 1) * tileSpacing
        let fitted = usable / CGFloat(itemCount)
        return max(fitted, minTileSize)
    }

    /// Icon inset inside a tile of the given effective size (keeps same visual
    /// proportion as the nominal 76pt tile / 60pt icon).
    public static func effectiveIconSize(for effectiveTile: CGFloat) -> CGFloat {
        let ratio = iconSize / tileSize   // 60/76 ≈ 0.789
        return effectiveTile * ratio
    }

    /// Total panel size for a given window count, using nominal tile size.
    /// Use `panelSize(itemCount:effectiveTile:)` when shrinking is active.
    public static func panelSize(itemCount: Int) -> NSSize {
        let count = max(itemCount, 1)
        let width = horizontalMargin * 2
                  + CGFloat(count) * tileSize
                  + CGFloat(count - 1) * tileSpacing
        let height = topPadding + tileSize + titleGap + titleHeight + bottomPadding
        return NSSize(width: width, height: height)
    }

    /// Total panel size using the given effective tile edge (used when tiles are
    /// shrunk so all fit within the screen width).
    public static func panelSize(itemCount: Int, effectiveTile: CGFloat) -> NSSize {
        panelSize(itemCount: itemCount, effectiveTile: effectiveTile, previewEnabled: false)
    }

    /// Total panel size using the given effective tile edge, with an optional
    /// preview pane below the title.
    ///
    /// When `previewEnabled` is true:
    ///   - Width is widened to at least (previewWidth + horizontalMargin*2) so
    ///     the preview box always fits without clipping.
    ///   - Height gains `previewTopGap + previewHeight` below the title.
    ///
    /// The two-argument overload without `previewEnabled` forwards here with
    /// `false` so all existing callers and tests remain source-compatible.
    public static func panelSize(itemCount: Int,
                                 effectiveTile: CGFloat,
                                 previewEnabled: Bool) -> NSSize {
        let count = max(itemCount, 1)
        let tileRowWidth = horizontalMargin * 2
                         + CGFloat(count) * effectiveTile
                         + CGFloat(count - 1) * tileSpacing
        let baseHeight = topPadding + effectiveTile + titleGap + titleHeight + bottomPadding
        if previewEnabled {
            let minPreviewPanelWidth = previewWidth + horizontalMargin * 2
            return NSSize(
                width:  max(tileRowWidth, minPreviewPanelWidth),
                height: baseHeight + previewTopGap + previewHeight
            )
        }
        return NSSize(width: tileRowWidth, height: baseHeight)
    }

    /// Preview pane rect in flipped (top-left origin) coordinates, consistent
    /// with `SwitcherListView.isFlipped == true`.
    ///
    /// - Parameters:
    ///   - width: The total panel width (used to center the pane horizontally).
    ///   - effectiveTile: The effective tile edge currently in use.
    public static func previewRect(inBoundsWidth width: CGFloat,
                                   effectiveTile: CGFloat) -> NSRect {
        let x = (width - previewWidth) / 2
        let y = topPadding + effectiveTile + titleGap + titleHeight + previewTopGap
        return NSRect(x: x, y: y, width: previewWidth, height: previewHeight)
    }

    /// Tile rect for the given index using the nominal tile size, in flipped
    /// (top-left origin) coordinates.
    public static func tileRect(index: Int) -> NSRect {
        tileRect(index: index, effectiveTile: tileSize)
    }

    /// Tile rect for the given index using a specified effective tile edge.
    public static func tileRect(index: Int, effectiveTile: CGFloat) -> NSRect {
        NSRect(
            x: horizontalMargin + CGFloat(index) * (effectiveTile + tileSpacing),
            y: topPadding,
            width: effectiveTile,
            height: effectiveTile
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

// MARK: - SwitcherListView

/// Horizontal icon-tile row with the selected window's title beneath it.
/// Fully custom-drawn: no subviews, no Auto Layout in the hot path.
final class SwitcherListView: NSView {

    // MARK: State

    private var items: [SwitcherItem] = []
    private(set) var selectedIndex: Int = 0
    // Effective tile edge, set by setItems; may be < tileSize when shrink-to-fit
    // kicks in for wide lists.
    private var effectiveTile: CGFloat = SwitcherLayout.tileSize

    // Pushed by SwitcherPanel before each show so draw() stays pure — it reads
    // a stored value rather than calling into Settings during the draw pass.
    var accentColor: NSColor = .controlAccentColor

    // When true, a live preview pane is drawn below the title.
    // Pushed by the panel on each show(); never changes during a session.
    var previewEnabled: Bool = false

    // Owned by the panel; injected once in SwitcherPanel.init().
    // Weak to avoid a retain cycle: panel → cache ← listView.
    weak var previewCache: WindowPreviewCache?

    // Top-left origin so tile math matches SwitcherLayout directly.
    override var isFlipped: Bool { true }

    // MARK: Public API

    /// Number of items currently displayed (the snapshot taken at show time).
    var count: Int { items.count }

    /// Replace the full item list and select the given index.
    /// Pass the available panel width so the shrink-to-fit tile size can be
    /// computed; when zero the nominal tile size is used.
    func setItems(_ items: [SwitcherItem], selectedIndex: Int, availableWidth: CGFloat = 0) {
        self.items = items
        self.selectedIndex = clamp(selectedIndex, count: items.count)
        if availableWidth > 0 {
            effectiveTile = SwitcherLayout.effectiveTileSize(
                itemCount: items.count, availableWidth: availableWidth)
        } else {
            effectiveTile = SwitcherLayout.tileSize
        }
        needsDisplay = true
        if previewEnabled { requestPreviews() }
    }

    /// Move the selection highlight, invalidating only the two affected tiles
    /// and the title strip (§7.5).
    func moveSelection(to newIndex: Int) {
        let old = selectedIndex
        let new = clamp(newIndex, count: items.count)
        guard new != old else { return }

        selectedIndex = new
        for index in SwitcherLayout.indicesToRedraw(old: old, new: new) {
            setNeedsDisplay(SwitcherLayout.tileRect(index: index,
                                                    effectiveTile: effectiveTile)
                            .insetBy(dx: -2, dy: -2))
        }
        setNeedsDisplay(titleRect)
        if previewEnabled {
            setNeedsDisplay(previewRect)
            requestPreviews()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let tile = effectiveTile
        let iconEdge = SwitcherLayout.effectiveIconSize(for: tile)
        for (index, item) in items.enumerated() {
            let tileRect = SwitcherLayout.tileRect(index: index, effectiveTile: tile)
            guard tileRect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }

            if index == selectedIndex {
                // Accent-tinted rounded highlight (α≈0.30) — clearly shows the
                // chosen accent colour while staying tasteful. Color is pushed by
                // the panel before each show so this path stays pure/fast.
                let highlight = NSBezierPath(roundedRect: tileRect, xRadius: 14, yRadius: 14)
                accentColor.withAlphaComponent(AccentColor.selectionHighlightAlpha).setFill()
                highlight.fill()
            }

            let inset = (tile - iconEdge) / 2
            let iconRect = tileRect.insetBy(dx: inset, dy: inset)
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

        // Live preview pane — only drawn when enabled and the dirty rect overlaps.
        // draw() is kept pure/fast: only reads from the cache dict, never triggers
        // a capture (that happens in requestPreviews, called from setItems/moveSelection).
        if previewEnabled,
           previewRect.intersects(dirtyRect),
           items.indices.contains(selectedIndex) {
            drawPreview(in: previewRect, for: items[selectedIndex])
        }
    }

    /// Draw the preview pane for the given item.
    /// Called only from draw(_:); assumes previewEnabled is already checked.
    private func drawPreview(in rect: NSRect, for item: SwitcherItem) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let borderColor = NSColor.white.withAlphaComponent(0.18)

        if let img = previewCache?.cachedImage(for: item.windowID) {
            // Aspect-fit the capture inside the preview rect (letterbox if needed).
            let fitRect = aspectFitRect(imageSize: img.size, inRect: rect)
            clip.setClip()
            img.draw(
                in: fitRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            // Faint glass-rim border drawn over the image.
            borderColor.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        } else {
            // Placeholder: translucent filled box + dimmed app icon.
            // The box has the same geometry as the real preview, so no layout
            // reflow occurs when the real image arrives — minimises flicker.
            NSColor.white.withAlphaComponent(0.05).setFill()
            clip.fill()

            if let icon = item.icon {
                let iconEdge: CGFloat = 64
                let iconRect = NSRect(
                    x: rect.midX - iconEdge / 2,
                    y: rect.midY - iconEdge / 2,
                    width: iconEdge,
                    height: iconEdge
                )
                icon.draw(
                    in: iconRect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.25,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue]
                )
            }

            borderColor.setStroke()
            clip.lineWidth = 1
            clip.stroke()
        }
    }

    /// Returns the largest rect that fits `imageSize` aspect-fitted inside `container`,
    /// centered on both axes.
    private func aspectFitRect(imageSize: NSSize, inRect container: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let fitW = imageSize.width * scale
        let fitH = imageSize.height * scale
        return NSRect(
            x: container.midX - fitW / 2,
            y: container.midY - fitH / 2,
            width: fitW,
            height: fitH
        )
    }

    // MARK: - Preview callbacks

    /// Called by the panel when the cache delivers a new image.
    /// Invalidates only the preview rect so a full tile-row redraw is avoided.
    func previewDidArrive(for id: CGWindowID) {
        guard items.indices.contains(selectedIndex),
              items[selectedIndex].windowID == id else { return }
        setNeedsDisplay(previewRect)
    }

    // MARK: - Private helpers

    /// Preview rect in flipped (top-left origin) coordinates.
    private var previewRect: NSRect {
        SwitcherLayout.previewRect(inBoundsWidth: bounds.width, effectiveTile: effectiveTile)
    }

    /// Kick off (or refresh) captures for the selected window and its neighbors.
    private func requestPreviews() {
        guard previewEnabled, items.indices.contains(selectedIndex) else { return }
        // Force-refresh the currently-visible window so it's always fresh.
        previewCache?.prefetch(items[selectedIndex].windowID, force: true)
        // Prefetch neighbors with force:false so cached images are reused.
        if selectedIndex > 0 {
            previewCache?.prefetch(items[selectedIndex - 1].windowID, force: false)
        }
        if selectedIndex < items.count - 1 {
            previewCache?.prefetch(items[selectedIndex + 1].windowID, force: false)
        }
    }

    private var titleRect: NSRect {
        NSRect(
            x: 0,
            y: SwitcherLayout.topPadding + effectiveTile + SwitcherLayout.titleGap,
            width: bounds.width,
            height: SwitcherLayout.titleHeight
        )
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(index, count - 1))
    }
}
