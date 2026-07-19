import CoreGraphics
import Foundation

// WindowInfo is the pure value model for a single on-screen window.
// All fields are resolved at enumeration time; the UI layer consumes this
// struct directly without touching CGWindowList or NSRunningApplication.
struct WindowInfo: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// Display title with fallback and duplicate-suffix already applied.
    let title: String
    let bounds: CGRect
}
