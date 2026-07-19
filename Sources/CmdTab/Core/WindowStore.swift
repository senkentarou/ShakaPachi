import AppKit
import CoreGraphics
import Foundation

// WindowStore enumerates on-screen windows via a single CGWindowListCopyWindowInfo
// call and applies the filters specified in §5.3 of the kickoff spec.
//
// Testability: the heavy lifting (raw dict array → [WindowInfo]) lives in the
// static `filterAndBuild` method which accepts [[String: Any]] so unit tests
// can supply hand-built fixtures without TCC permissions.
final class WindowStore {

    // Bundle IDs to exclude from enumeration results.
    // Populated from Settings in a later step; empty by default.
    let excludedBundleIDs: Set<String>

    // Per-instance pid → bundleID cache.  Avoids repeated NSRunningApplication
    // lookups across consecutive enumerate() calls.
    private var bundleIDCache: [pid_t: String?] = [:]

    init(excludedBundleIDs: Set<String> = []) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    // MARK: - Public interface

    /// Enumerate on-screen windows and return filtered, title-resolved results.
    ///
    /// - Parameter currentSpaceOnly: When `true` (default) only windows on the
    ///   current Space are included (.optionOnScreenOnly). Pass `false` to use
    ///   .optionAll and include every space.
    func enumerate(currentSpaceOnly: Bool = true) -> [WindowInfo] {
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
        return WindowStore.filterAndBuild(
            rawList: rawList,
            selfPID: getpid(),
            excludedBundleIDs: excludedBundleIDs,
            bundleIDResolver: { [weak self] pid in self?.resolvedBundleID(for: pid) }
        )
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
    static func filterAndBuild(
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
    private static func windowInfo(
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
    static func applyDuplicateSuffixes(to windows: [WindowInfo]) -> [WindowInfo] {
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
