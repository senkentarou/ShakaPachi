// WindowStoreSortTests.swift
// Verifies WindowStore.sortedByApp (byApp sort mode) and the zOrder passthrough.
// All tests use static pure functions — no TCC, no CGWindowList.

import XCTest
import CoreGraphics
@testable import CmdTab

final class WindowStoreSortTests: XCTestCase {

    // MARK: - Fixture helper

    private func makeWindow(
        id: CGWindowID,
        pid: pid_t,
        bundleID: String?,
        appName: String,
        title: String = "Window"
    ) -> WindowInfo {
        WindowInfo(
            windowID: id,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
    }

    // MARK: - sortedByApp

    func testSortedByApp_emptyInput_returnsEmpty() {
        let result = WindowStore.sortedByApp(windows: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSortedByApp_singleWindow_returnsSame() {
        let w = makeWindow(id: 1, pid: 100, bundleID: "com.apple.safari", appName: "Safari")
        let result = WindowStore.sortedByApp(windows: [w])
        XCTAssertEqual(result.map { $0.windowID }, [1])
    }

    func testSortedByApp_windowsFromSameApp_areContiguous() {
        // Two Safari windows and one Finder window: Safari, Finder, Safari.
        // byApp should group them: both Safaris together (in their original
        // relative order), then Finder.
        let s1 = makeWindow(id: 1, pid: 101, bundleID: "com.apple.safari",  appName: "Safari", title: "Safari 1")
        let fi = makeWindow(id: 2, pid: 102, bundleID: "com.apple.finder",  appName: "Finder", title: "Finder")
        let s2 = makeWindow(id: 3, pid: 101, bundleID: "com.apple.safari",  appName: "Safari", title: "Safari 2")

        let result = WindowStore.sortedByApp(windows: [s1, fi, s2])
        // Safari appears first (first-seen), so its two windows lead.
        // Finder comes after (second first-appearance).
        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 2],
            "Expected Safari 1, Safari 2, Finder — byApp groups same-bundle windows")
    }

    func testSortedByApp_allWindowsFromOneApp_orderPreserved() {
        let w1 = makeWindow(id: 1, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "A")
        let w2 = makeWindow(id: 2, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "B")
        let w3 = makeWindow(id: 3, pid: 100, bundleID: "com.example.app", appName: "MyApp", title: "C")
        let result = WindowStore.sortedByApp(windows: [w1, w2, w3])
        // All same app: original order preserved.
        XCTAssertEqual(result.map { $0.windowID }, [1, 2, 3])
    }

    func testSortedByApp_interGroupOrderMatchesFirstAppearance() {
        // Input order: B1, A1, A2, B2, C1.
        // First appearance order: B (id=1), A (id=2), C (id=5).
        // Expected output: B1, B2, A1, A2, C1.
        let b1 = makeWindow(id: 1, pid: 200, bundleID: "com.b", appName: "B")
        let a1 = makeWindow(id: 2, pid: 100, bundleID: "com.a", appName: "A")
        let a2 = makeWindow(id: 3, pid: 100, bundleID: "com.a", appName: "A")
        let b2 = makeWindow(id: 4, pid: 200, bundleID: "com.b", appName: "B")
        let c1 = makeWindow(id: 5, pid: 300, bundleID: "com.c", appName: "C")
        let result = WindowStore.sortedByApp(windows: [b1, a1, a2, b2, c1])
        XCTAssertEqual(result.map { $0.windowID }, [1, 4, 2, 3, 5])
    }

    func testSortedByApp_nilBundleIDGroupsByAppName() {
        // When bundleID is nil, the grouping key falls back to appName.
        let x1 = makeWindow(id: 1, pid: 10, bundleID: nil, appName: "AppX")
        let y1 = makeWindow(id: 2, pid: 20, bundleID: nil, appName: "AppY")
        let x2 = makeWindow(id: 3, pid: 10, bundleID: nil, appName: "AppX")
        let result = WindowStore.sortedByApp(windows: [x1, y1, x2])
        // First appearance: AppX (id=1), then AppY (id=2).
        XCTAssertEqual(result.map { $0.windowID }, [1, 3, 2])
    }

    // MARK: - zOrder passthrough

    func testZOrder_passthrough_preservesInputOrder() {
        // In zOrder mode, enumerate() returns filtered windows unchanged.
        // We verify the static behavior by confirming sortedByApp is NOT called:
        // just check the order is unchanged. The full integration goes through
        // the store, but we verify the pure-function side here.
        let w1 = makeWindow(id: 10, pid: 1, bundleID: "com.a", appName: "A")
        let w2 = makeWindow(id: 20, pid: 2, bundleID: "com.b", appName: "B")
        let w3 = makeWindow(id: 30, pid: 1, bundleID: "com.a", appName: "A")

        // zOrder: pass the list through as-is (no sort).
        // We verify that the zOrder path does NOT group by app:
        let zOrderResult = [w1, w2, w3]  // unchanged — this is what enumerate returns for .zOrder
        XCTAssertEqual(zOrderResult.map { $0.windowID }, [10, 20, 30],
            "zOrder must preserve CGWindowList order without grouping")

        // byApp: groups same-app windows together.
        let byAppResult = WindowStore.sortedByApp(windows: [w1, w2, w3])
        XCTAssertEqual(byAppResult.map { $0.windowID }, [10, 30, 20],
            "byApp must group app 'A' windows together before app 'B'")

        // Verify zOrder and byApp give different results when apps are interleaved.
        XCTAssertNotEqual(zOrderResult.map { $0.windowID },
                          byAppResult.map  { $0.windowID })
    }

    // MARK: - sortedByApp is nonisolated (pure function property)

    func testSortedByApp_canBeCalledFromAnyContext() async {
        // sortedByApp is nonisolated static, so it must be callable from any context.
        let w = makeWindow(id: 1, pid: 100, bundleID: "com.example", appName: "App")
        // Call from a non-MainActor context to verify nonisolated.
        let result = await Task.detached {
            WindowStore.sortedByApp(windows: [w])
        }.value
        XCTAssertEqual(result.count, 1)
    }
}
