// SwitcherListView.swift
// Native App-Switcher-style horizontal icon-tile row (user decision). Each tile
// is ONE WINDOW (not an app) — windows of the same app repeat the app icon,
// AltTab-style — and the selected window's title is drawn beneath the row.
// Custom draw(_:) implementation: tiles plus a single title line, so a full
// pass is trivial and selective redraw reduces to invalidating two tile rects
// plus the title strip.

import AppKit
import CoreGraphics

// MARK: - SwitcherItem

/// Lightweight value type carrying display data for one row.
struct SwitcherItem: Equatable {
    let icon: NSImage?
    let title: String
    /// CGWindowID for the window preview cache lookup.
    /// 0 is a safe sentinel for items that have no associated window (e.g. tests).
    let windowID: CGWindowID

    init(icon: NSImage?, title: String, windowID: CGWindowID = 0) {
        self.icon = icon
        self.title = title
        self.windowID = windowID
    }
}

// MARK: - Layout constants shared with SwitcherPanel

/// Shared layout constants used by both the tile row and the panel.
/// All geometry functions are pure — unit-testable.
enum SwitcherLayout {
    /// Square highlight tile per window — the nominal (maximum) size.
    static let tileSize: CGFloat = 76
    /// App icon drawn centered inside the nominal tile.
    static let iconSize: CGFloat = 60
    /// Minimum tile edge when shrink-to-fit kicks in.
    static let minTileSize: CGFloat = 40
    /// Gap between adjacent tiles.
    static let tileSpacing: CGFloat = 8
    /// Left/right panel margin around the tile row.
    static let horizontalMargin: CGFloat = 20
    /// Space above the tile row.
    static let topPadding: CGFloat = 20
    /// Gap between the tile row and the title line.
    static let titleGap: CGFloat = 6
    /// Height of the selected-window title line.
    static let titleHeight: CGFloat = 20
    /// Space below the title line.
    static let bottomPadding: CGFloat = 14

    // MARK: - Window preview constants

    /// Width of the optional live-preview pane (16:10 ratio with previewHeight).
    static let previewWidth: CGFloat = 320
    /// Height of the optional live-preview pane.
    static let previewHeight: CGFloat = 200
    /// Gap between the title line and the top of the preview pane.
    static let previewTopGap: CGFloat = 10

    // MARK: - Shrink-to-fit

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
    static func effectiveTileSize(
        itemCount: Int, availableWidth: CGFloat, baseTile: CGFloat = tileSize
    ) -> CGFloat {
        guard itemCount > 0 else { return baseTile }
        let natural = panelSize(itemCount: itemCount, baseTile: baseTile).width
        if natural <= availableWidth {
            return baseTile  // fits at full size — no shrink needed
        }
        // Largest t such that: margin*2 + count*t + (count-1)*spacing ≤ availableWidth
        //   t ≤ (availableWidth - margin*2 - (count-1)*spacing) / count
        let usable =
            availableWidth - horizontalMargin * 2
            - CGFloat(itemCount - 1) * tileSpacing
        let fitted = usable / CGFloat(itemCount)
        return max(fitted, minTileSize)
    }

    /// Icon inset inside a tile of the given effective size (keeps same visual
    /// proportion as the nominal 76pt tile / 60pt icon).
    static func effectiveIconSize(for effectiveTile: CGFloat) -> CGFloat {
        let ratio = iconSize / tileSize  // 60/76 ≈ 0.789
        return effectiveTile * ratio
    }

    /// Total panel size for a given window count.
    /// Pass `baseTile` to use a non-nominal tile edge (default = `tileSize` = 76).
    /// Use `panelSize(itemCount:effectiveTile:)` when shrinking is active.
    static func panelSize(itemCount: Int, baseTile: CGFloat = tileSize) -> NSSize {
        let count = max(itemCount, 1)
        let width =
            horizontalMargin * 2
            + CGFloat(count) * baseTile
            + CGFloat(count - 1) * tileSpacing
        let height = topPadding + baseTile + titleGap + titleHeight + bottomPadding
        return NSSize(width: width, height: height)
    }

    /// Converts a user-chosen icon-size (in points) to the corresponding nominal
    /// tile edge, preserving the canonical icon/tile ratio (60/76 ≈ 0.789).
    /// Example: nominalTile(forIconSize: 60) == 76.
    static func nominalTile(forIconSize iconPoints: CGFloat) -> CGFloat {
        iconPoints * tileSize / iconSize  // 60 → 76
    }

    /// Total panel size using the given effective tile edge (used when tiles are
    /// shrunk so all fit within the screen width).
    static func panelSize(itemCount: Int, effectiveTile: CGFloat) -> NSSize {
        panelSize(itemCount: itemCount, effectiveTile: effectiveTile, previewEnabled: false)
    }

    /// Total panel size using the given effective tile edge, with an optional
    /// preview pane below the title.
    ///
    /// When `previewEnabled` is true:
    ///   - Width is widened to at least (previewPaneWidth + horizontalMargin*2) so
    ///     the preview box always fits without clipping.
    ///   - Height gains `previewTopGap + previewPaneHeight` below the title.
    ///
    /// The two-argument overload without `previewEnabled` forwards here with
    /// `false` so all existing callers and tests remain source-compatible.
    /// `previewPaneWidth`/`previewPaneHeight` default to the static constants so
    /// zero-arg and existing callers remain byte-identical.
    static func panelSize(
        itemCount: Int,
        effectiveTile: CGFloat,
        previewEnabled: Bool,
        previewPaneWidth: CGFloat = previewWidth,
        previewPaneHeight: CGFloat = previewHeight
    ) -> NSSize {
        let count = max(itemCount, 1)
        let tileRowWidth =
            horizontalMargin * 2
            + CGFloat(count) * effectiveTile
            + CGFloat(count - 1) * tileSpacing
        let baseHeight = topPadding + effectiveTile + titleGap + titleHeight + bottomPadding
        if previewEnabled {
            let minPreviewPanelWidth = previewPaneWidth + horizontalMargin * 2
            return NSSize(
                width: max(tileRowWidth, minPreviewPanelWidth),
                height: baseHeight + previewTopGap + previewPaneHeight
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
    ///   - previewPaneWidth: Width of the preview pane (default: `previewWidth` constant).
    ///   - previewPaneHeight: Height of the preview pane (default: `previewHeight` constant).
    static func previewRect(
        inBoundsWidth width: CGFloat,
        effectiveTile: CGFloat,
        previewPaneWidth: CGFloat = previewWidth,
        previewPaneHeight: CGFloat = previewHeight
    ) -> NSRect {
        let x = (width - previewPaneWidth) / 2
        let y = topPadding + effectiveTile + titleGap + titleHeight + previewTopGap
        return NSRect(x: x, y: y, width: previewPaneWidth, height: previewPaneHeight)
    }

    /// Returns the preview pane size for a given width, maintaining 16:10 aspect ratio.
    /// Example: previewPaneSize(forWidth: 320) == 320×200, previewPaneSize(forWidth: 480) == 480×300.
    static func previewPaneSize(forWidth w: CGFloat) -> NSSize {
        NSSize(width: w, height: w * previewHeight / previewWidth)
    }

    /// Tile rect for the given index using the nominal tile size, in flipped
    /// (top-left origin) coordinates.
    static func tileRect(index: Int) -> NSRect {
        tileRect(index: index, effectiveTile: tileSize)
    }

    /// Tile rect for the given index using a specified effective tile edge.
    static func tileRect(index: Int, effectiveTile: CGFloat) -> NSRect {
        NSRect(
            x: horizontalMargin + CGFloat(index) * (effectiveTile + tileSpacing),
            y: topPadding,
            width: effectiveTile,
            height: effectiveTile
        )
    }

    /// Tile rect shifted right by `offsetX` relative to the 2-arg overload.
    /// Used to center the tile row when the panel is wider than the natural
    /// tile-row width (e.g. when the preview pane widens the panel).
    static func tileRect(index: Int, effectiveTile: CGFloat, offsetX: CGFloat) -> NSRect {
        let base = tileRect(index: index, effectiveTile: effectiveTile)
        return NSRect(
            x: base.origin.x + offsetX,
            y: base.origin.y,
            width: base.width,
            height: base.height
        )
    }

    /// Returns the horizontal offset needed to center the whole tile row within
    /// `boundsWidth`. When the preview pane widens the panel, the tile row
    /// would otherwise cluster at the left margin; this offset shifts the entire
    /// row rightward so its center aligns with the panel center (matching the
    /// already-centered preview pane and title). Never returns a negative value:
    /// if the row is wider than `boundsWidth`, returns 0 so nothing shifts
    /// left off-screen.
    static func tileRowOffsetX(
        itemCount: Int,
        effectiveTile: CGFloat,
        boundsWidth: CGFloat
    ) -> CGFloat {
        let count = max(itemCount, 1)
        let rowWidth =
            horizontalMargin * 2
            + CGFloat(count) * effectiveTile
            + CGFloat(count - 1) * tileSpacing
        let offset = (boundsWidth - rowWidth) / 2
        return max(offset, 0)
    }

    /// Advance the selection index by +1 with wrap-around.
    static func advanceIndex(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// The tile indices needing redraw when the selection moves.
    static func indicesToRedraw(old: Int, new: Int) -> IndexSet {
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

    // Preview pane dimensions — pushed by the panel on each show() from Settings.
    // Defaults match the static constants so a zero-push scenario draws identically.
    var previewPaneWidth: CGFloat = SwitcherLayout.previewWidth
    var previewPaneHeight: CGFloat = SwitcherLayout.previewHeight

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
    /// Pass `baseTile` when the user has configured a non-default icon size.
    func setItems(
        _ items: [SwitcherItem],
        selectedIndex: Int,
        availableWidth: CGFloat = 0,
        baseTile: CGFloat = SwitcherLayout.tileSize
    ) {
        self.items = items
        self.selectedIndex = clamp(selectedIndex, count: items.count)
        if availableWidth > 0 {
            effectiveTile = SwitcherLayout.effectiveTileSize(
                itemCount: items.count, availableWidth: availableWidth, baseTile: baseTile)
        } else {
            effectiveTile = baseTile
        }
        needsDisplay = true
        if previewEnabled { requestPreviews() }
    }

    /// Move the selection highlight, invalidating only the two affected tiles
    /// and the title strip.
    func moveSelection(to newIndex: Int) {
        let old = selectedIndex
        let new = clamp(newIndex, count: items.count)
        guard new != old else { return }

        selectedIndex = new
        let offsetX = tileRowOffsetX
        for index in SwitcherLayout.indicesToRedraw(old: old, new: new) {
            setNeedsDisplay(
                SwitcherLayout.tileRect(
                    index: index,
                    effectiveTile: effectiveTile,
                    offsetX: offsetX
                )
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
        let offsetX = tileRowOffsetX
        for (index, item) in items.enumerated() {
            let tileRect = SwitcherLayout.tileRect(index: index, effectiveTile: tile, offsetX: offsetX)
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
            paragraph.lineBreakMode = .byTruncatingMiddle  // middle-truncate long titles
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
            items.indices.contains(selectedIndex)
        {
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
        let scale = min(
            container.width / imageSize.width,
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
            items[selectedIndex].windowID == id
        else { return }
        setNeedsDisplay(previewRect)
    }

    // MARK: - Private helpers

    /// Horizontal offset to center the tile row within the current panel width.
    /// Returns 0 when preview is disabled (panel width equals the natural tile-row
    /// width, so no shift is needed).
    private var tileRowOffsetX: CGFloat {
        SwitcherLayout.tileRowOffsetX(
            itemCount: items.count,
            effectiveTile: effectiveTile,
            boundsWidth: bounds.width
        )
    }

    /// Preview rect in flipped (top-left origin) coordinates.
    private var previewRect: NSRect {
        SwitcherLayout.previewRect(
            inBoundsWidth: bounds.width,
            effectiveTile: effectiveTile,
            previewPaneWidth: previewPaneWidth,
            previewPaneHeight: previewPaneHeight)
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
