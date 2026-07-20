// Activator.swift
// §9: Raise a specific window via the Accessibility API.
//
// The CGWindowID↔AXUIElement mapping is inherently ambiguous (no public
// direct-lookup API exists). The matching logic tries title first, then bounds
// within a 2-point tolerance, and falls back to app-only activation when
// neither produces a single confident match.
//
// Threading (§9.4): AX calls are synchronous IPC. They must not run inside the
// event-tap callback (§4.3). The state machine wires the confirm action through
// the main queue (onSwitcherInput runs on the main run loop), so activate() is
// effectively always called on the main thread. The mandatory 50ms messaging
// timeout (§9.3) bounds the worst-case block to ~50ms per AX call, which is
// acceptable for v1 on the main thread. A dedicated background serial queue
// would avoid any main-thread delay but would require marshalling the
// panel.hide() back to main, complicating the control flow without a
// measurable user benefit given the 50ms cap.

import AppKit
import ApplicationServices

@MainActor
final class Activator {

    // MARK: - Public entry point

    /// Raise `window` to the front using the Accessibility API (§9.1).
    func activate(_ window: WindowInfo) {
        let pid = window.pid

        // Step 1 (§9.1): activate the app first so it is at least frontmost
        // even if the specific-window raise below falls back to app-only.
        // On macOS 14+ the deprecated `options:` parameter is omitted.
        NSRunningApplication(processIdentifier: pid)?.activate()

        // Step 2 (§9.1): create an AX element for the app.
        let appElement = AXUIElementCreateApplication(pid)

        // Step 3 (§9.3): set the messaging timeout BEFORE any attribute read.
        // This prevents an unresponsive app from freezing the switcher UI.
        AXUIElementSetMessagingTimeout(appElement, 0.05)

        // Step 4 (§9.1): copy the array of window AX elements.
        var rawValue: CFTypeRef?
        let attrResult = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard attrResult == .success,
              let axWindows = rawValue as? [AXUIElement],
              !axWindows.isEmpty else {
            NSLog("[CmdTab] Activate: fallback – app activate only " +
                  "(failed to read kAXWindowsAttribute, pid %d)", pid)
            return
        }

        // Marshal AX attributes into plain values for the pure decision.
        var candidates: [(title: String, bounds: CGRect)] = []
        for axWin in axWindows {
            let title = axTitle(of: axWin)
            let bounds = axBounds(of: axWin)
            candidates.append((title: title, bounds: bounds))
        }

        // Step 5 (§9.2): identify the target window using the pure matcher.
        guard let matchedIndex = Activator.matchWindow(
            title: window.title,
            bounds: window.bounds,
            candidates: candidates
        ) else {
            // Step 5c fallback (§9.2): app activation already done in step 1.
            NSLog("[CmdTab] Activate: fallback – app activate only " +
                  "(ambiguous or no match, pid %d)", pid)
            return
        }

        let targetWin = axWindows[matchedIndex]

        // Determine which strategy was used (for log clarity).
        let strategy: String
        let titleNonEmpty = !window.title.isEmpty
        if titleNonEmpty {
            let titleMatches = candidates.filter { $0.title == window.title }
            strategy = titleMatches.count == 1 ? "title" : "bounds"
        } else {
            strategy = "bounds"
        }

        // Step 5 (§9.1): raise and make main.
        AXUIElementPerformAction(targetWin, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(targetWin,
                                     kAXMainAttribute as CFString,
                                     kCFBooleanTrue)

        NSLog("[CmdTab] Activate: raised window by %@ match (pid %d)",
              strategy, pid)
    }

    // MARK: - Pure decision (§9.2, testable)

    /// Identify the best candidate index from a list of (title, bounds) pairs.
    ///
    /// Matching priority (§9.2):
    /// 1. Exactly one candidate whose title matches `title` (when title is non-empty).
    /// 2. If title is empty, or 0/multiple title matches: pick the candidate whose
    ///    bounds are within a 2-point tolerance on every dimension.
    /// 3. If still ambiguous or no match: return nil → fallback to app-only.
    ///
    /// This function is deliberately pure (no AX / AppKit calls) so it can be
    /// exhaustively unit-tested without TCC permissions (§0 UI/logic separation).
    ///
    /// - Parameters:
    ///   - title: The title from `WindowInfo` (may be empty; includes duplicate
    ///     suffixes from WindowStore if applicable).
    ///   - bounds: The `CGRect` bounds from `WindowInfo` (CGWindowList coords,
    ///     top-left origin in global screen space).
    ///   - candidates: AX-read attributes marshalled to plain values.
    /// - Returns: The index of the matched candidate, or nil when no confident
    ///   match can be made.
    nonisolated static func matchWindow(
        title: String,
        bounds: CGRect,
        candidates: [(title: String, bounds: CGRect)]
    ) -> Int? {

        // Step 5a (§9.2): title match when title is non-empty.
        if !title.isEmpty {
            let titleMatches = candidates.indices.filter { candidates[$0].title == title }
            if titleMatches.count == 1 {
                return titleMatches[0]
            }
            // Fall through to bounds when 0 or multiple title matches.
        }

        // Step 5b (§9.2): bounds match within 2pt tolerance.
        // AX kAXPosition reports the top-left corner in global screen coordinates,
        // which matches CGWindowList bounds — both use the same coordinate origin.
        let tolerance: CGFloat = 2.0
        let boundsMatches = candidates.indices.filter { i in
            let c = candidates[i].bounds
            return abs(c.origin.x - bounds.origin.x) <= tolerance &&
                   abs(c.origin.y - bounds.origin.y) <= tolerance &&
                   abs(c.width    - bounds.width)    <= tolerance &&
                   abs(c.height   - bounds.height)   <= tolerance
        }
        if boundsMatches.count == 1 {
            return boundsMatches[0]
        }

        // Step 5c (§9.2): ambiguous or no match — return nil for fallback.
        return nil
    }

    // MARK: - AX attribute marshalling (impure; stays outside the pure matcher)

    /// Read `kAXTitleAttribute` from an AX window element, returning "" on failure.
    private func axTitle(of element: AXUIElement) -> String {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXTitleAttribute as CFString, &raw) == .success,
              let title = raw as? String else {
            return ""
        }
        return title
    }

    /// Reconstruct a `CGRect` from `kAXPositionAttribute` + `kAXSizeAttribute`.
    ///
    /// Both attributes carry `AXValue` wrappers around `CGPoint`/`CGSize`.
    /// Returns `.zero` when either attribute is unavailable.
    private func axBounds(of element: AXUIElement) -> CGRect {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRaw) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &sizeRaw) == .success else {
            return .zero
        }

        guard let posValue = posRaw,
              let sizeValue = sizeRaw else {
            return .zero
        }

        var point = CGPoint.zero
        var size = CGSize.zero

        // AXValueGetValue extracts the typed value from the AXValue wrapper.
        // The cast to AXValue is safe: AXUIElementCopyAttributeValue returns
        // CFTypeRef, and position/size attributes always carry AXValue instances.
        let posAX = posValue as! AXValue   // swiftlint:disable:this force_cast
        let sizeAX = sizeValue as! AXValue // swiftlint:disable:this force_cast
        AXValueGetValue(posAX, .cgPoint, &point)
        AXValueGetValue(sizeAX, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }
}
