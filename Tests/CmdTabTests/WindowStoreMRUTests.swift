// WindowStoreMRUTests.swift
// Verifies §5.5 MRU ordering pure helpers in WindowStore.
// No AppKit, no TCC, no CGWindowList — all tests are deterministic.

import XCTest
@testable import CmdTab

final class WindowStoreMRUTests: XCTestCase {

    // MARK: - sortedByMRU

    /// When mruOrder is empty, z-order is returned unchanged.
    func testSortedByMRU_emptyOrder_returnsZOrder() {
        let ids: [CGWindowID] = [1, 2, 3]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [])
        XCTAssertEqual(result, [1, 2, 3])
    }

    /// When windowIDs is empty, result is also empty.
    func testSortedByMRU_emptyWindowIDs_returnsEmpty() {
        let result = WindowStore.sortedByMRU(windowIDs: [], mruOrder: [10, 20])
        XCTAssertTrue(result.isEmpty)
    }

    /// Known IDs come first in mruOrder sequence; unknowns follow in z-order.
    func testSortedByMRU_knownFirst_unknownsAppendedInZOrder() {
        // z-order from CGWindowList: [1, 2, 3, 4]
        // mruOrder: [3, 1]  (3 used most recently, then 1)
        let ids: [CGWindowID] = [1, 2, 3, 4]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [3, 1])
        // Expected: 3 (MRU[0]), 1 (MRU[1]), then unknowns 2 and 4 in z-order
        XCTAssertEqual(result, [3, 1, 2, 4])
    }

    /// An mruOrder entry that is no longer on-screen is silently skipped.
    func testSortedByMRU_staleMRUEntrySkipped() {
        let ids: [CGWindowID] = [1, 2]
        // 99 is in mruOrder but not in the current window list
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [99, 2, 1])
        XCTAssertEqual(result, [2, 1])
    }

    /// All on-screen windows are known in mruOrder — no unknowns to append.
    func testSortedByMRU_allKnown_returnsInMRUOrder() {
        let ids: [CGWindowID] = [10, 20, 30]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [30, 10, 20])
        XCTAssertEqual(result, [30, 10, 20])
    }

    /// All on-screen windows are unknown — returns z-order unchanged.
    func testSortedByMRU_allUnknown_returnsZOrder() {
        let ids: [CGWindowID] = [5, 6, 7]
        let result = WindowStore.sortedByMRU(windowIDs: ids, mruOrder: [1, 2, 3])
        XCTAssertEqual(result, [5, 6, 7])
    }

    /// Single window, known in mruOrder.
    func testSortedByMRU_singleWindowKnown() {
        let result = WindowStore.sortedByMRU(windowIDs: [42], mruOrder: [42])
        XCTAssertEqual(result, [42])
    }

    /// Single window, unknown in mruOrder.
    func testSortedByMRU_singleWindowUnknown() {
        let result = WindowStore.sortedByMRU(windowIDs: [42], mruOrder: [99])
        XCTAssertEqual(result, [42])
    }

    // MARK: - movedToFront

    /// Inserting into an empty order produces a one-element array.
    func testMovedToFront_emptyOrder_insertsAtFront() {
        let result = WindowStore.movedToFront(5, in: [], cap: 200)
        XCTAssertEqual(result, [5])
    }

    /// A new ID is prepended to an existing order.
    func testMovedToFront_newID_prependedWithoutDuplicate() {
        let result = WindowStore.movedToFront(1, in: [2, 3, 4], cap: 200)
        XCTAssertEqual(result, [1, 2, 3, 4])
    }

    /// An existing ID at the front is a no-op (still at front, count unchanged).
    func testMovedToFront_alreadyAtFront_noChange() {
        let result = WindowStore.movedToFront(1, in: [1, 2, 3], cap: 200)
        XCTAssertEqual(result, [1, 2, 3])
    }

    /// An existing ID not at the front is moved to the front without duplication.
    func testMovedToFront_existingMidID_movedToFrontNoDupe() {
        let result = WindowStore.movedToFront(2, in: [1, 2, 3, 4], cap: 200)
        XCTAssertEqual(result, [2, 1, 3, 4])
    }

    /// An existing ID at the tail is moved to the front without duplication.
    func testMovedToFront_existingTailID_movedToFront() {
        let result = WindowStore.movedToFront(4, in: [1, 2, 3, 4], cap: 200)
        XCTAssertEqual(result, [4, 1, 2, 3])
    }

    /// When the result would exceed cap, the tail is trimmed.
    func testMovedToFront_capEvictsFromTail() {
        // Fill with IDs 1…5, cap = 5
        let existing: [CGWindowID] = [1, 2, 3, 4, 5]
        let result = WindowStore.movedToFront(6, in: existing, cap: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first, 6)
        // Tail (ID 5) must be dropped
        XCTAssertFalse(result.contains(5))
    }

    /// Cap of 200 is enforced correctly when adding to a full list.
    func testMovedToFront_cap200_evictsTail() {
        let existing: [CGWindowID] = Array(1...200)
        let result = WindowStore.movedToFront(999, in: existing, cap: 200)
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first, 999)
        // The oldest entry (200) must be dropped
        XCTAssertFalse(result.contains(200))
        // All entries 1…199 are still present
        for i: CGWindowID in 1...199 {
            XCTAssertTrue(result.contains(i), "Entry \(i) should survive cap eviction")
        }
    }

    /// When cap == 1, only the most recent entry survives.
    func testMovedToFront_capOne_keepsOnlyFront() {
        let result = WindowStore.movedToFront(7, in: [1, 2, 3], cap: 1)
        XCTAssertEqual(result, [7])
    }

    /// Promotes an ID from the middle of a full-cap list; no duplication.
    func testMovedToFront_promoteFromMiddleInFullList_noExtraEntries() {
        let existing: [CGWindowID] = Array(1...200)
        // Promoting ID 100 (which already exists): no duplication, count stays 200
        let result = WindowStore.movedToFront(100, in: existing, cap: 200)
        XCTAssertEqual(result.count, 200)
        XCTAssertEqual(result.first, 100)
        // 100 appears exactly once
        XCTAssertEqual(result.filter { $0 == 100 }.count, 1)
    }

    // MARK: - Alternating activation round-trip

    /// Simulates alternating between window A and window B using the pure helpers.
    /// After each swap, "press once release" (initial index 1) returns to the
    /// other window — verifying the core MRU invariant for Step 11.
    func testAlternatingActivation_mruOrderStaysConsistent() {
        let a: CGWindowID = 100
        let b: CGWindowID = 200
        var order: [CGWindowID] = []
        let cap = 200

        // First: user activates A
        order = WindowStore.movedToFront(a, in: order, cap: cap)
        XCTAssertEqual(order.first, a)

        // Then: user activates B (e.g. via switcher choosing index 1)
        order = WindowStore.movedToFront(b, in: order, cap: cap)
        XCTAssertEqual(order, [b, a])

        // Now enumerate returns [b, a, ...]; index 1 = a → press-once-release goes to A.
        let sorted1 = WindowStore.sortedByMRU(windowIDs: [a, b], mruOrder: order)
        XCTAssertEqual(sorted1, [b, a])   // index 0=b (current), index 1=a (previous)

        // User activates A again
        order = WindowStore.movedToFront(a, in: order, cap: cap)
        XCTAssertEqual(order, [a, b])

        let sorted2 = WindowStore.sortedByMRU(windowIDs: [a, b], mruOrder: order)
        XCTAssertEqual(sorted2, [a, b])   // index 0=a (current), index 1=b (previous)
    }
}
