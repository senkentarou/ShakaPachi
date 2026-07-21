// SwitcherLayoutPreviewTests.swift
// Verifies the preview-pane geometry additions to SwitcherLayout:
//   - panelSize with previewEnabled:true is taller and wide enough for the pane.
//   - panelSize with previewEnabled:false is identical to the baseline.
//   - previewRect is centered and positioned correctly.

import XCTest

@testable import ShakaPachi

final class SwitcherLayoutPreviewTests: XCTestCase {

    // MARK: - panelSize with previewEnabled

    func testPanelHeight_withPreview_isBaseHeightPlusPreviewBlock() {
        let tile: CGFloat = SwitcherLayout.tileSize
        let base = SwitcherLayout.panelSize(
            itemCount: 5, effectiveTile: tile,
            previewEnabled: false)
        let withPreview = SwitcherLayout.panelSize(
            itemCount: 5, effectiveTile: tile,
            previewEnabled: true)
        let expectedExtra = SwitcherLayout.previewTopGap + SwitcherLayout.previewHeight
        XCTAssertEqual(
            withPreview.height, base.height + expectedExtra,
            "Preview height must add previewTopGap + previewHeight")
    }

    func testPanelWidth_withPreview_atLeastPreviewWidthPlusMargins() {
        // 1 tile is narrower than the preview pane — panel must widen.
        let tile = SwitcherLayout.tileSize
        let withPreview = SwitcherLayout.panelSize(
            itemCount: 1, effectiveTile: tile,
            previewEnabled: true)
        let minPreviewWidth = SwitcherLayout.previewWidth + SwitcherLayout.horizontalMargin * 2
        XCTAssertGreaterThanOrEqual(
            withPreview.width, minPreviewWidth,
            "Panel must be at least wide enough to show the preview pane")
    }

    func testPanelWidth_withPreview_manyTilesWider_usesTileRowWidth() {
        // Many tiles produce a tile-row wider than the preview pane.
        let tile = SwitcherLayout.tileSize
        let many = 20
        let withPreview = SwitcherLayout.panelSize(
            itemCount: many, effectiveTile: tile,
            previewEnabled: true)
        let withoutPreview = SwitcherLayout.panelSize(
            itemCount: many, effectiveTile: tile,
            previewEnabled: false)
        // Width should be the tile-row width (already > preview), so unchanged.
        XCTAssertEqual(
            withPreview.width, withoutPreview.width,
            "When tile row is wider than preview pane, width should not grow further")
    }

    func testPanelSize_previewDisabled_matchesBaseline() {
        // previewEnabled:false must produce the same size as the two-argument overload.
        let tile: CGFloat = SwitcherLayout.tileSize
        let count = 8
        let legacy = SwitcherLayout.panelSize(itemCount: count, effectiveTile: tile)
        let explicit = SwitcherLayout.panelSize(
            itemCount: count, effectiveTile: tile,
            previewEnabled: false)
        XCTAssertEqual(
            legacy, explicit,
            "previewEnabled:false must be identical to the two-argument overload")
    }

    // MARK: - previewRect geometry

    func testPreviewRect_isCenteredHorizontally() {
        let panelWidth: CGFloat = 480
        let tile = SwitcherLayout.tileSize
        let rect = SwitcherLayout.previewRect(
            inBoundsWidth: panelWidth,
            effectiveTile: tile)
        let expectedX = (panelWidth - SwitcherLayout.previewWidth) / 2
        XCTAssertEqual(
            rect.origin.x, expectedX, accuracy: 0.001,
            "Preview pane must be centered horizontally")
    }

    func testPreviewRect_hasCorrectSize() {
        let rect = SwitcherLayout.previewRect(
            inBoundsWidth: 500,
            effectiveTile: SwitcherLayout.tileSize)
        XCTAssertEqual(rect.width, SwitcherLayout.previewWidth)
        XCTAssertEqual(rect.height, SwitcherLayout.previewHeight)
    }

    func testPreviewRect_topIsJustBelowTitleLine() {
        let tile = SwitcherLayout.tileSize
        let rect = SwitcherLayout.previewRect(inBoundsWidth: 500, effectiveTile: tile)
        let expectedY =
            SwitcherLayout.topPadding
            + tile
            + SwitcherLayout.titleGap
            + SwitcherLayout.titleHeight
            + SwitcherLayout.previewTopGap
        XCTAssertEqual(
            rect.origin.y, expectedY, accuracy: 0.001,
            "Preview top must be exactly titleLine.maxY + previewTopGap")
    }

    // MARK: - Backward compatibility (one-argument panelSize unchanged)

    func testPanelSize_oneArg_heightUnchanged() {
        // The one-argument overload (no effectiveTile, no previewEnabled) must
        // remain identical to what it was before the preview feature was added.
        let size = SwitcherLayout.panelSize(itemCount: 3)
        let expected =
            SwitcherLayout.topPadding
            + SwitcherLayout.tileSize
            + SwitcherLayout.titleGap
            + SwitcherLayout.titleHeight
            + SwitcherLayout.bottomPadding
        XCTAssertEqual(
            size.height, expected,
            "One-argument panelSize must not include preview height")
    }

    // MARK: - tileRowOffsetX

    func testTileRowOffsetX_zeroWhenBoundsMatchesNaturalWidth() {
        // When the panel width equals the natural tile-row width (previewEnabled:false),
        // offset must be 0 — backward-compatible: left-aligned == centered for exact fit.
        let tile = SwitcherLayout.tileSize
        let count = 5
        let naturalWidth = SwitcherLayout.panelSize(
            itemCount: count, effectiveTile: tile, previewEnabled: false
        ).width
        let offset = SwitcherLayout.tileRowOffsetX(
            itemCount: count,
            effectiveTile: tile,
            boundsWidth: naturalWidth
        )
        XCTAssertEqual(
            offset, 0, accuracy: 0.001,
            "Offset must be 0 when boundsWidth equals the natural tile-row width")
    }

    func testTileRowOffsetX_centersRowInPreviewPanel() {
        // When the preview pane widens the panel (1 tile is narrower than the preview),
        // the row center must align with the panel center.
        let tile = SwitcherLayout.tileSize
        let count = 1
        let panelWidth = SwitcherLayout.panelSize(
            itemCount: count, effectiveTile: tile, previewEnabled: true
        ).width
        let offset = SwitcherLayout.tileRowOffsetX(
            itemCount: count,
            effectiveTile: tile,
            boundsWidth: panelWidth
        )
        XCTAssertGreaterThan(offset, 0, "Offset must be positive when preview widens panel")
        // Derive the natural row width and verify the row center lines up with panelWidth/2.
        let rowWidth =
            SwitcherLayout.horizontalMargin * 2
            + CGFloat(count) * tile
            + CGFloat(count - 1) * SwitcherLayout.tileSpacing
        let rowCenter = offset + rowWidth / 2
        XCTAssertEqual(
            rowCenter, panelWidth / 2, accuracy: 0.001,
            "Tile-row center must align with panel center (matches centered preview pane)")
    }

    func testTileRowOffsetX_neverNegativeWhenRowWiderThanBounds() {
        // When boundsWidth is smaller than the row width, offset must be 0 (not negative).
        let tile = SwitcherLayout.tileSize
        let count = 20
        let tinyBounds: CGFloat = 100  // much smaller than the 20-tile row
        let offset = SwitcherLayout.tileRowOffsetX(
            itemCount: count,
            effectiveTile: tile,
            boundsWidth: tinyBounds
        )
        XCTAssertEqual(
            offset, 0, accuracy: 0.001,
            "Offset must be 0 (not negative) when row is wider than bounds")
    }

    func testTileRect_offsetXOverload_shiftsXPreservesYWidthHeight() {
        // The 3-arg overload must shift x by exactly offsetX and leave y/width/height identical.
        let tile = SwitcherLayout.tileSize
        let index = 2
        let offsetX: CGFloat = 37.5
        let base = SwitcherLayout.tileRect(index: index, effectiveTile: tile)
        let shifted = SwitcherLayout.tileRect(index: index, effectiveTile: tile, offsetX: offsetX)
        XCTAssertEqual(
            shifted.origin.x, base.origin.x + offsetX, accuracy: 0.001,
            "x must be shifted by exactly offsetX")
        XCTAssertEqual(
            shifted.origin.y, base.origin.y, accuracy: 0.001,
            "y must be unchanged")
        XCTAssertEqual(
            shifted.width, base.width, accuracy: 0.001,
            "width must be unchanged")
        XCTAssertEqual(
            shifted.height, base.height, accuracy: 0.001,
            "height must be unchanged")
    }
}
