// SwitcherPanelTests.swift
// Pure-logic tests for the Step 7 helpers in SwitcherListView / SwitcherLayout.
// No display connection or AppKit UI is required — all tested functions are
// stateless computations on plain values.

import XCTest
@testable import CmdTab

final class SwitcherPanelTests: XCTestCase {

    // MARK: - panelSize (horizontal tile row)

    func testPanelSize_oneItem() {
        let size = SwitcherLayout.panelSize(itemCount: 1)
        XCTAssertEqual(size.width,
                       SwitcherLayout.horizontalMargin * 2 + SwitcherLayout.tileSize)
        XCTAssertEqual(size.height,
                       SwitcherLayout.topPadding + SwitcherLayout.tileSize
                       + SwitcherLayout.titleGap + SwitcherLayout.titleHeight
                       + SwitcherLayout.bottomPadding)
    }

    func testPanelSize_zeroItems_treatedAsOne() {
        // An empty list never shows the panel, but the math must not break.
        XCTAssertEqual(SwitcherLayout.panelSize(itemCount: 0),
                       SwitcherLayout.panelSize(itemCount: 1))
    }

    func testPanelSize_widthGrowsPerItem() {
        let one = SwitcherLayout.panelSize(itemCount: 1)
        let two = SwitcherLayout.panelSize(itemCount: 2)
        XCTAssertEqual(two.width - one.width,
                       SwitcherLayout.tileSize + SwitcherLayout.tileSpacing,
                       "Each additional window adds one tile plus one gap")
    }

    func testPanelSize_heightIndependentOfCount() {
        XCTAssertEqual(SwitcherLayout.panelSize(itemCount: 1).height,
                       SwitcherLayout.panelSize(itemCount: 30).height,
                       "A single-row layout has constant height")
    }

    // MARK: - tileRect

    func testTileRect_firstTileAtMargin() {
        let rect = SwitcherLayout.tileRect(index: 0)
        XCTAssertEqual(rect.origin.x, SwitcherLayout.horizontalMargin)
        XCTAssertEqual(rect.origin.y, SwitcherLayout.topPadding)
        XCTAssertEqual(rect.size, NSSize(width: SwitcherLayout.tileSize,
                                         height: SwitcherLayout.tileSize))
    }

    func testTileRect_advancesByTileAndSpacing() {
        let r0 = SwitcherLayout.tileRect(index: 0)
        let r1 = SwitcherLayout.tileRect(index: 1)
        XCTAssertEqual(r1.origin.x - r0.origin.x,
                       SwitcherLayout.tileSize + SwitcherLayout.tileSpacing)
        XCTAssertEqual(r0.origin.y, r1.origin.y, "Single row: same y for all tiles")
    }

    func testTileRect_lastTileFitsInsidePanelWidth() {
        let count = 8
        let last = SwitcherLayout.tileRect(index: count - 1)
        let size = SwitcherLayout.panelSize(itemCount: count)
        XCTAssertEqual(last.maxX + SwitcherLayout.horizontalMargin, size.width,
                       "Panel width must exactly wrap the last tile plus margin")
    }

    // MARK: - advanceIndex (wrap-around)

    func testAdvanceIndex_normalAdvance() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 5), 1)
        XCTAssertEqual(SwitcherLayout.advanceIndex(3, count: 5), 4)
    }

    func testAdvanceIndex_wrapsAround() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(4, count: 5), 0,
            "Advancing past the last item must wrap to 0")
    }

    func testAdvanceIndex_singleItem_staysAtZero() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 1), 0,
            "Single-item list must always return 0")
    }

    func testAdvanceIndex_zeroCount_returnsZero() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 0), 0,
            "Empty list must return 0 without crashing")
    }

    func testAdvanceIndex_twoItems_cycles() {
        XCTAssertEqual(SwitcherLayout.advanceIndex(0, count: 2), 1)
        XCTAssertEqual(SwitcherLayout.advanceIndex(1, count: 2), 0)
    }

    // MARK: - indicesToRedraw (§7.5 two-tile optimisation)

    func testIndicesToRedraw_differentIndices_returnsBoth() {
        let set = SwitcherLayout.indicesToRedraw(old: 1, new: 3)
        XCTAssertEqual(set, IndexSet([1, 3]),
            "Both old and new indices must be included")
    }

    func testIndicesToRedraw_sameIndex_returnsSingleTile() {
        let set = SwitcherLayout.indicesToRedraw(old: 2, new: 2)
        XCTAssertEqual(set, IndexSet(integer: 2),
            "When old == new the set should contain exactly one index")
    }

    func testIndicesToRedraw_adjacentTiles() {
        let set = SwitcherLayout.indicesToRedraw(old: 4, new: 5)
        XCTAssertTrue(set.contains(4))
        XCTAssertTrue(set.contains(5))
        XCTAssertEqual(set.count, 2)
    }

    func testIndicesToRedraw_zeroToLast() {
        let set = SwitcherLayout.indicesToRedraw(old: 0, new: 7)
        XCTAssertEqual(set, IndexSet([0, 7]))
    }
}
