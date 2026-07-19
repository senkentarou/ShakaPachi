// SwitcherPanelTests.swift
// Pure-logic tests for the Step 7 helpers in SwitcherListView / SwitcherLayout.
// No display connection or AppKit UI is required — all tested functions are
// stateless computations on plain values.

import XCTest
@testable import CmdTab

final class SwitcherPanelTests: XCTestCase {

    // MARK: - panelHeight

    func testPanelHeight_zeroItems() {
        // 0 items → visibleRows = min(0,20) = 0 → only padding.
        let h = SwitcherLayout.panelHeight(itemCount: 0)
        XCTAssertEqual(h, SwitcherLayout.verticalPadding * 2)
    }

    func testPanelHeight_oneItem() {
        let h = SwitcherLayout.panelHeight(itemCount: 1)
        XCTAssertEqual(h, SwitcherLayout.rowHeight + SwitcherLayout.verticalPadding * 2)
    }

    func testPanelHeight_exactlyMaxRows() {
        let h = SwitcherLayout.panelHeight(itemCount: SwitcherLayout.maxRows)
        let expected = CGFloat(SwitcherLayout.maxRows) * SwitcherLayout.rowHeight
                     + SwitcherLayout.verticalPadding * 2
        XCTAssertEqual(h, expected)
    }

    func testPanelHeight_exceedsMaxRows_clampedToMax() {
        // Items beyond maxRows do not increase the height (scroll handles overflow).
        let h20 = SwitcherLayout.panelHeight(itemCount: SwitcherLayout.maxRows)
        let h21 = SwitcherLayout.panelHeight(itemCount: SwitcherLayout.maxRows + 1)
        XCTAssertEqual(h20, h21,
            "Height must be capped at maxRows regardless of item count")
    }

    func testPanelHeight_manyItems_clampedToMax() {
        let h = SwitcherLayout.panelHeight(itemCount: 100)
        let expected = CGFloat(SwitcherLayout.maxRows) * SwitcherLayout.rowHeight
                     + SwitcherLayout.verticalPadding * 2
        XCTAssertEqual(h, expected)
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

    // MARK: - rowsToRedraw (§7.5 two-row optimisation)

    func testRowsToRedraw_differentIndices_returnsBoth() {
        let set = SwitcherLayout.rowsToRedraw(old: 1, new: 3)
        XCTAssertEqual(set, IndexSet([1, 3]),
            "Both old and new indices must be included")
    }

    func testRowsToRedraw_sameIndex_returnsSingleRow() {
        let set = SwitcherLayout.rowsToRedraw(old: 2, new: 2)
        XCTAssertEqual(set, IndexSet(integer: 2),
            "When old == new the set should contain exactly one index")
    }

    func testRowsToRedraw_adjacentRows() {
        let set = SwitcherLayout.rowsToRedraw(old: 4, new: 5)
        XCTAssertTrue(set.contains(4))
        XCTAssertTrue(set.contains(5))
        XCTAssertEqual(set.count, 2)
    }

    func testRowsToRedraw_zeroToLast() {
        let set = SwitcherLayout.rowsToRedraw(old: 0, new: 7)
        XCTAssertEqual(set, IndexSet([0, 7]))
    }
}
