// IconCache.swift
// Cache app icons, resized once at store-time so draw() never pays for
// scaling at runtime.
//
// Note: the original spec called for 20×20 icons for 28pt rows. The design
// uses a horizontal tile layout with 76pt tiles and 60pt icons
// (SwitcherLayout.iconSize), so icons are cached at 60×60 instead — the stored
// image matches the drawn size exactly.

import AppKit
import Foundation
import UniformTypeIdentifiers

final class IconCache {

    // Cache key is bundleID when available; falls back to "pid:<pid>" for
    // processes that have no bundle (e.g. command-line tools).
    private var cache: [String: NSImage] = [:]

    // MARK: - Lifecycle

    init() {
        // Evict entries when an app terminates so stale icons don't accumulate.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    /// Return a cached, pre-scaled icon for the given process.
    ///
    /// - Parameters:
    ///   - pid: The process identifier of the running application.
    ///   - bundleID: The bundle identifier, if available.  Used as the cache key.
    /// - Returns: A 60×60 NSImage.  Never nil — falls back to the generic
    ///   application bundle icon when the process icon cannot be retrieved.
    func icon(for pid: pid_t, bundleID: String?) -> NSImage {
        let key = cacheKey(pid: pid, bundleID: bundleID)
        if let cached = cache[key] {
            return cached
        }
        let image = resolveIcon(for: pid)
        let sized = resize(image, to: IconCache.targetSize)
        cache[key] = sized
        return sized
    }

    // MARK: - Private helpers

    /// The target edge length for cached icons, matching SwitcherLayout.iconSize.
    static let targetSize: CGFloat = 60

    private func cacheKey(pid: pid_t, bundleID: String?) -> String {
        bundleID ?? "pid:\(pid)"
    }

    /// Retrieve the raw icon from NSRunningApplication, falling back to the
    /// generic application bundle icon provided by NSWorkspace.
    private func resolveIcon(for pid: pid_t) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid),
            let icon = app.icon
        {
            return icon
        }
        // Fallback: generic app icon that NSWorkspace provides for any .app bundle.
        return NSWorkspace.shared.icon(for: .application)
    }

    /// Draw `source` into a new `size × size` bitmap, returning the result.
    /// This is done once at cache-fill time; subsequent draws are a plain blit.
    private func resize(_ source: NSImage, to edge: CGFloat) -> NSImage {
        let targetSize = NSSize(width: edge, height: edge)
        return NSImage(size: targetSize, flipped: false) { bounds in
            source.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
            return true
        }
    }

    // MARK: - Eviction

    @objc private func appDidTerminate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        // Remove by bundleID if present, and also by pid-keyed entry.
        if let bid = app.bundleIdentifier {
            cache.removeValue(forKey: bid)
        }
        cache.removeValue(forKey: "pid:\(app.processIdentifier)")
    }
}
