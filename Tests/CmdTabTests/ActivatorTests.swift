// ActivatorTests.swift
// Unit-tests for the pure Activator.matchWindow decision function (§9.2).
// No AX / AppKit / TCC permissions required — all inputs are plain values.

import XCTest
@testable import CmdTab

final class ActivatorTests: XCTestCase {

    // MARK: - Helpers

    private typealias Candidate = (title: String, bounds: CGRect)

    private func rect(_ x: CGFloat, _ y: CGFloat,
                      _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Title-match strategy

    /// Exactly one candidate with a matching title → returns that index.
    func testExactSingleTitleMatch() {
        let candidates: [Candidate] = [
            (title: "Finder",   bounds: rect(100, 100, 800, 600)),
            (title: "Terminal", bounds: rect(200, 200, 800, 600)),
            (title: "Xcode",    bounds: rect(300, 300, 800, 600)),
        ]
        let result = Activator.matchWindow(
            title: "Terminal", bounds: rect(0, 0, 1, 1), candidates: candidates)
        XCTAssertEqual(result, 1)
    }

    /// Two candidates with identical titles → fall through to bounds.
    func testMultipleIdenticalTitlesFallsThroughToBoundsAndMatches() {
        let target = rect(100, 200, 800, 600)
        let other  = rect(900, 200, 800, 600)
        let candidates: [Candidate] = [
            (title: "Untitled", bounds: other),
            (title: "Untitled", bounds: target),
        ]
        // Pass the target bounds: should pick index 1.
        let result = Activator.matchWindow(
            title: "Untitled", bounds: target, candidates: candidates)
        XCTAssertEqual(result, 1)
    }

    /// Zero candidates matching the title → fall through to bounds.
    func testZeroTitleMatchesFallsThroughToBounds() {
        let target = rect(50, 50, 1280, 720)
        let candidates: [Candidate] = [
            (title: "Safari",  bounds: target),
            (title: "Preview", bounds: rect(0, 0, 400, 300)),
        ]
        // Title doesn't match any candidate; bounds match index 0.
        let result = Activator.matchWindow(
            title: "DoesNotExist", bounds: target, candidates: candidates)
        XCTAssertEqual(result, 0)
    }

    // MARK: - Empty title falls through to bounds

    /// Empty title skips title-matching entirely and uses bounds.
    func testEmptyTitleSkipsTitleMatchAndUsesBounds() {
        let target = rect(10, 20, 640, 480)
        let candidates: [Candidate] = [
            (title: "App",      bounds: rect(200, 200, 640, 480)),
            (title: "App",      bounds: target),
        ]
        let result = Activator.matchWindow(
            title: "", bounds: target, candidates: candidates)
        XCTAssertEqual(result, 1)
    }

    // MARK: - Bounds tolerance boundary

    /// Offset of exactly 0 on every dimension → match.
    func testBoundsExactMatchAccepted() {
        let b = rect(100, 200, 800, 600)
        let candidates: [Candidate] = [(title: "X", bounds: b)]
        let result = Activator.matchWindow(
            title: "", bounds: b, candidates: candidates)
        XCTAssertEqual(result, 0)
    }

    /// Offset of 1.9pt on x (< 2.0) → still within tolerance → match.
    func testBoundsOffset1point9Matches() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100 + 1.9, 200, 800, 600)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertEqual(result, 0)
    }

    /// Offset of exactly 2.0pt on x → at the boundary → match (≤ 2.0).
    func testBoundsOffset2point0Matches() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100 + 2.0, 200, 800, 600)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertEqual(result, 0)
    }

    /// Offset of 2.1pt on x (> 2.0) → outside tolerance → no match.
    func testBoundsOffset2point1DoesNotMatch() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100 + 2.1, 200, 800, 600)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertNil(result)
    }

    /// Offset just outside 2pt tolerance on y → no match.
    func testBoundsYOffsetOutsideToleranceDoesNotMatch() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100, 200 + 2.1, 800, 600)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertNil(result)
    }

    /// Offset just outside 2pt tolerance on width → no match.
    func testBoundsWidthOffsetOutsideToleranceDoesNotMatch() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100, 200, 800 + 2.1, 600)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertNil(result)
    }

    /// Offset just outside 2pt tolerance on height → no match.
    func testBoundsHeightOffsetOutsideToleranceDoesNotMatch() {
        let base = rect(100, 200, 800, 600)
        let shifted = rect(100, 200, 800, 600 + 2.1)
        let candidates: [Candidate] = [(title: "X", bounds: shifted)]
        let result = Activator.matchWindow(
            title: "", bounds: base, candidates: candidates)
        XCTAssertNil(result)
    }

    // MARK: - No candidates match → nil (fallback)

    /// No candidate matches title or bounds → nil.
    func testNoCandidateMatchReturnsNil() {
        let candidates: [Candidate] = [
            (title: "A", bounds: rect(0,   0,   100, 100)),
            (title: "B", bounds: rect(200, 200, 100, 100)),
        ]
        let result = Activator.matchWindow(
            title: "Z", bounds: rect(500, 500, 800, 600), candidates: candidates)
        XCTAssertNil(result)
    }

    /// Empty candidates array → nil.
    func testEmptyCandidatesReturnsNil() {
        let result = Activator.matchWindow(
            title: "Anything", bounds: rect(0, 0, 800, 600), candidates: [])
        XCTAssertNil(result)
    }

    // MARK: - Bounds disambiguation with multiple title matches

    /// Three candidates, two share the title; the one within bounds is chosen.
    func testBoundsDisambiguatesWhenTwoTitleMatchesBothCandidates() {
        let target  = rect(100, 100, 800, 600)
        let farAway = rect(999, 999, 800, 600)
        let candidates: [Candidate] = [
            (title: "Doc", bounds: farAway),
            (title: "Doc", bounds: target),
            (title: "Other", bounds: rect(0, 0, 100, 100)),
        ]
        let result = Activator.matchWindow(
            title: "Doc", bounds: target, candidates: candidates)
        XCTAssertEqual(result, 1)
    }

    /// Two candidates with identical title AND both within 2pt of the same
    /// target bounds → ambiguous → nil (cannot pick one safely).
    func testAmbiguousBoundsMatchReturnsNil() {
        let b1 = rect(100, 100, 800, 600)
        let b2 = rect(101, 100, 800, 600)   // within 2pt of b1 (and of target)
        let target = b1
        let candidates: [Candidate] = [
            (title: "Doc", bounds: b1),
            (title: "Doc", bounds: b2),
        ]
        let result = Activator.matchWindow(
            title: "Doc", bounds: target, candidates: candidates)
        // Both b1 and b2 are within 2pt of target → bounds match is also ambiguous.
        XCTAssertNil(result)
    }
}
