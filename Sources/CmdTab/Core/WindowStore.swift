import AppKit
import CoreGraphics
import Foundation

// WindowStore enumerates on-screen windows via a single CGWindowListCopyWindowInfo
// call and applies the filters specified in §5.3 of the kickoff spec.
//
// Testability: the heavy lifting (raw dict array → [WindowInfo]) lives in the
// static `filterAndBuild` method which accepts [[String: Any]] so unit tests
// can supply hand-built fixtures without TCC permissions.
// The MRU pure helpers (sortedByMRU, movedToFront) are also static so tests
// can exercise them without any AppKit or TCC calls.
//
// Concurrency: the class is @MainActor because all callers (AppDelegate, the
// NSWorkspace notification handler) run on the main thread. This satisfies Swift
// 6 strict concurrency without requiring Sendable conformances on NSWorkspace
// observation internals.
@MainActor
final class WindowStore {

    // Bundle IDs to exclude from enumeration results.
    // Live-updatable: AppDelegate updates this from Settings on every change.
    // MRU state is preserved across updates (mruOrder is NOT cleared).
    var excludedBundleIDs: Set<String>

    // Per-instance pid → bundleID cache.  Avoids repeated NSRunningApplication
    // lookups across consecutive enumerate() calls.
    private var bundleIDCache: [pid_t: String?] = [:]

    // §5.5: persistent MRU ordering for the lifetime of the process.
    // Index 0 = most recently used window.
    // Never exceeds mruCap entries; tail entries are evicted when the cap is hit.
    private var mruOrder: [CGWindowID] = []
    private let mruCap = 200

    init(excludedBundleIDs: Set<String> = []) {
        self.excludedBundleIDs = excludedBundleIDs
        subscribeToWorkspaceActivations()
    }

    // MARK: - Public interface

    /// Enumerate on-screen windows and return filtered, title-resolved results
    /// sorted according to the given `sortMode`.
    ///
    /// - Parameters:
    ///   - currentSpaceOnly: When `true` (default) only windows on the current
    ///     Space are included (.optionOnScreenOnly). Pass `false` to use
    ///     .optionAll and include every space.
    ///   - sortMode: How the result list is ordered. Defaults to `.mru`.
    func enumerate(currentSpaceOnly: Bool = true, sortMode: SortMode = .mru) -> [WindowInfo] {
        let option: CGWindowListOption = currentSpaceOnly
            ? .optionOnScreenOnly
            : CGWindowListOption(rawValue:
                CGWindowListOption.optionAll.rawValue |
                CGWindowListOption.optionOnScreenOnly.rawValue)
        // Single CGWindowListCopyWindowInfo call as per §5.1.
        guard let rawList = CGWindowListCopyWindowInfo(option, kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let filtered = WindowStore.filterAndBuild(
            rawList: rawList,
            selfPID: getpid(),
            excludedBundleIDs: excludedBundleIDs,
            bundleIDResolver: { [weak self] pid in self?.resolvedBundleID(for: pid) }
        )

        switch sortMode {
        case .mru:
            // §5.5: sort by mruOrder; unknowns appended in z-order at the end.
            let sortedIDs = WindowStore.sortedByMRU(
                windowIDs: filtered.map { $0.windowID },
                mruOrder: mruOrder
            )
            let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.windowID, $0) })
            return sortedIDs.compactMap { byID[$0] }
        case .zOrder:
            // Raw CGWindowList order — no MRU sort applied.
            return filtered
        case .byApp:
            // Group windows by app (stable sort by bundleID/appName),
            // keeping MRU order within each group.
            let sortedByMRU = {
                let sortedIDs = WindowStore.sortedByMRU(
                    windowIDs: filtered.map { $0.windowID },
                    mruOrder: mruOrder
                )
                let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.windowID, $0) })
                return sortedIDs.compactMap { byID[$0] }
            }()
            return WindowStore.sortedByApp(windows: sortedByMRU)
        }
    }

    /// Record that `windowID` was just activated (switcher confirmed).
    /// Moves the ID to the front of `mruOrder` (§5.5).
    /// Call this immediately after `Activator.activate()` on `.confirmSelection`.
    func recordActivation(_ windowID: CGWindowID) {
        mruOrder = WindowStore.movedToFront(windowID, in: mruOrder, cap: mruCap)
    }

    // MARK: - NSWorkspace activation observation (§5.5)

    /// Subscribe to NSWorkspace app-activation events so that windows brought
    /// to the front by means other than the switcher are also tracked.
    private func subscribeToWorkspaceActivations() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main          // always main — safe to mutate mruOrder directly
        ) { [weak self] notification in
            // Use Task { @MainActor in … } to re-enter the MainActor-isolated
            // context from the NotificationCenter closure, which itself arrives
            // on .main OperationQueue but is not automatically @MainActor under
            // Swift 6 strict concurrency.
            Task { @MainActor [weak self] in
                self?.handleAppActivation(notification: notification)
            }
        }
    }

    /// Handle a didActivateApplicationNotification: find the frontmost on-screen
    /// window for the newly activated app's pid and move it to the front of mruOrder.
    private func handleAppActivation(notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        let activatedPID = app.processIdentifier

        // Lightweight CGWindowList query to find the frontmost window of the
        // activated app.  We query on-screen-only (current space) so z-order
        // reflects the visible stack.  Using a fresh query rather than the last
        // enumerate snapshot avoids stale data when the user switches apps
        // between switcher invocations.
        guard let rawList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return }

        // The first entry whose ownerPID matches and that passes the basic
        // layer/alpha/size filters is the frontmost window.
        for dict in rawList {
            guard let pidNum = dict[kCGWindowOwnerPID as String] as? Int32,
                  pid_t(pidNum) == activatedPID else { continue }
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let alpha = dict[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let wid = dict[kCGWindowNumber as String] as? CGWindowID else { continue }
            mruOrder = WindowStore.movedToFront(wid, in: mruOrder, cap: mruCap)
            return
        }
        // If no on-screen window was found for the pid (e.g. all minimized),
        // do nothing — the mruOrder stays as-is.
    }

    // MARK: - Bundle ID cache

    /// Resolve bundleID for a pid, consulting the in-instance cache first.
    private func resolvedBundleID(for pid: pid_t) -> String? {
        if let cached = bundleIDCache[pid] {
            return cached
        }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundleIDCache[pid] = id
        return id
    }

    // MARK: - Pure sort helpers (unit-testable without AppKit/CGWindowList)

    /// Return windows grouped by app (stable sort by bundleID then appName),
    /// preserving the relative order of windows within each group.
    ///
    /// The group order is determined by the first window encountered for each
    /// app in the input sequence (which is MRU-sorted when called from enumerate).
    /// This means the app that was most recently used appears first.
    ///
    /// - Parameter windows: The input window list (pre-sorted by MRU or z-order).
    /// - Returns: The same windows reordered so all windows of each app are
    ///   contiguous, with inter-app order matching the first appearance of each app.
    nonisolated static func sortedByApp(windows: [WindowInfo]) -> [WindowInfo] {
        // Build the ordered list of unique app keys (bundleID if available, else appName).
        var appOrder: [String] = []
        var seenApps: Set<String> = []
        var grouped: [String: [WindowInfo]] = [:]

        for window in windows {
            let key = window.bundleID ?? window.appName
            if !seenApps.contains(key) {
                seenApps.insert(key)
                appOrder.append(key)
            }
            grouped[key, default: []].append(window)
        }

        // Flatten in app-first-appearance order.
        return appOrder.flatMap { grouped[$0] ?? [] }
    }

    // MARK: - Pure MRU helpers (unit-testable without AppKit/CGWindowList)

    /// Return window IDs sorted by MRU order.
    ///
    /// IDs that appear in `mruOrder` come first, in mruOrder sequence.
    /// IDs not in `mruOrder` are appended at the end in the order they appear
    /// in `windowIDs` (i.e. z-order as returned by CGWindowList).
    ///
    /// - Parameters:
    ///   - windowIDs: The IDs of on-screen windows in z-order.
    ///   - mruOrder: The current MRU sequence (index 0 = most recently used).
    /// - Returns: The same IDs reordered by MRU, then z-order for unknowns.
    nonisolated static func sortedByMRU(
        windowIDs: [CGWindowID],
        mruOrder: [CGWindowID]
    ) -> [CGWindowID] {
        guard !mruOrder.isEmpty else { return windowIDs }
        let windowSet = Set(windowIDs)
        // Build the known-first portion: only IDs that exist in windowIDs,
        // preserving their relative MRU sequence.
        var result: [CGWindowID] = mruOrder.filter { windowSet.contains($0) }
        // Append unknowns in z-order (i.e., the order they appeared in windowIDs).
        let knownSet = Set(result)
        for id in windowIDs where !knownSet.contains(id) {
            result.append(id)
        }
        return result
    }

    /// Return a new order array with `id` moved (or inserted) at the front.
    ///
    /// If `id` already appears in `order`, it is removed first so there are
    /// no duplicates.  The result is then trimmed to at most `cap` entries by
    /// dropping from the tail (oldest entries).
    ///
    /// - Parameters:
    ///   - id: The window ID to promote to the front.
    ///   - order: The current MRU array (index 0 = most recently used).
    ///   - cap: Maximum number of entries to retain.
    /// - Returns: A new array with `id` at index 0, deduplicated, capped at `cap`.
    nonisolated static func movedToFront(
        _ id: CGWindowID,
        in order: [CGWindowID],
        cap: Int
    ) -> [CGWindowID] {
        // Remove any existing occurrence to avoid duplicates.
        var updated = order.filter { $0 != id }
        updated.insert(id, at: 0)
        // Evict from the tail when the cap is exceeded.
        if updated.count > cap {
            updated = Array(updated.prefix(cap))
        }
        return updated
    }

    // MARK: - Pure transformation (testable without TCC)

    /// Convert raw CGWindowList dictionaries into filtered, title-resolved WindowInfo
    /// values.  This static method is intentionally free of AppKit / TCC calls so
    /// that unit tests can invoke it with hand-built fixtures.
    ///
    /// - Parameters:
    ///   - rawList: The array returned by CGWindowListCopyWindowInfo.
    ///   - selfPID: The PID of the current process (filter §5.3-4).
    ///   - excludedBundleIDs: Bundle IDs that should be omitted.
    ///   - bundleIDResolver: Closure that maps a pid_t to an optional bundle ID.
    ///     Injected so tests can provide a pure lookup without NSRunningApplication.
    nonisolated static func filterAndBuild(
        rawList: [[String: Any]],
        selfPID: pid_t,
        excludedBundleIDs: Set<String>,
        bundleIDResolver: (pid_t) -> String?
    ) -> [WindowInfo] {

        // Phase 1: filter and convert raw dicts to partially-built WindowInfo values
        // (title field holds the raw kCGWindowName / owner-name fallback at this stage;
        // duplicate suffixes are applied in phase 2).
        var candidates: [WindowInfo] = []
        for dict in rawList {
            guard let info = windowInfo(
                from: dict,
                selfPID: selfPID,
                excludedBundleIDs: excludedBundleIDs,
                bundleIDResolver: bundleIDResolver
            ) else { continue }
            candidates.append(info)
        }

        // Phase 2: apply duplicate-title suffixes in enumeration order (§5.4).
        return applyDuplicateSuffixes(to: candidates)
    }

    // MARK: - Internal helpers

    /// Attempt to build a WindowInfo from a single CGWindowList dictionary,
    /// returning nil if any filter condition (§5.3) rejects it.
    nonisolated private static func windowInfo(
        from dict: [String: Any],
        selfPID: pid_t,
        excludedBundleIDs: Set<String>,
        bundleIDResolver: (pid_t) -> String?
    ) -> WindowInfo? {

        // §5.3-1: layer must be 0 (normal application windows only).
        guard let layer = dict[kCGWindowLayer as String] as? Int,
              layer == 0 else { return nil }

        // §5.3-2: window must be visible (alpha > 0).
        guard let alpha = dict[kCGWindowAlpha as String] as? Double,
              alpha > 0 else { return nil }

        // §5.3-3: bounds must be at least 40×40.
        guard let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 40, bounds.height >= 40 else { return nil }

        // §5.3-4: exclude own process.
        guard let pidNum = dict[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        let pid = pid_t(pidNum)
        guard pid != selfPID else { return nil }

        // §5.3-6: kCGWindowStoreType must be present and non-zero.
        guard let storeType = dict[kCGWindowStoreType as String] as? Int,
              storeType != 0 else { return nil }

        // Resolve bundle ID (may be nil — not all processes have a bundle ID).
        let bundleID = bundleIDResolver(pid)

        // §5.3-5: exclude explicitly listed bundle IDs.
        if let bid = bundleID, excludedBundleIDs.contains(bid) { return nil }

        // Window ID.
        guard let wid = dict[kCGWindowNumber as String] as? CGWindowID else { return nil }

        // App name (owner name).
        let appName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"

        // §5.4: title fallback — use kCGWindowName if non-empty, else app name.
        let rawTitle = dict[kCGWindowName as String] as? String ?? ""
        let title = rawTitle.isEmpty ? appName : rawTitle

        return WindowInfo(
            windowID: wid,
            pid: pid,
            bundleID: bundleID,
            appName: appName,
            title: title,
            bounds: bounds
        )
    }

    /// Apply duplicate-title suffixes to a list of WindowInfo values.
    ///
    /// Windows that share the same title string receive " (2)", " (3)", … suffixes
    /// in enumeration order (§5.4).  The first occurrence keeps the original title.
    nonisolated static func applyDuplicateSuffixes(to windows: [WindowInfo]) -> [WindowInfo] {
        // Count how many times each title has already been emitted.
        var seen: [String: Int] = [:]
        return windows.map { info in
            let base = info.title
            let count = seen[base, default: 0]
            seen[base] = count + 1
            if count == 0 {
                return info
            }
            // Rebuild with the suffix.  We copy all fields except title.
            return WindowInfo(
                windowID: info.windowID,
                pid: info.pid,
                bundleID: info.bundleID,
                appName: info.appName,
                title: "\(base) (\(count + 1))",
                bounds: info.bounds
            )
        }
    }
}
