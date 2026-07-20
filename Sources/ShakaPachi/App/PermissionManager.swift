// PermissionManager.swift
// Checks and requests the two permissions ShakaPachi requires:
//   - Accessibility  (AXIsProcessTrusted / AXIsProcessTrustedWithOptions)
//   - Screen Recording (CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess)

import AppKit
import ApplicationServices

// MARK: - Permission status

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
}

// MARK: - PermissionManager

/// Checks and requests macOS permissions required by ShakaPachi.
/// All methods run on the main thread (@MainActor).
@MainActor
public final class PermissionManager {

    // Deep links to System Settings panels.
    static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    static let screenRecordingURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    // MARK: Status checks

    /// Returns the current accessibility permission status.
    /// Does NOT prompt — use requestAccessibility() for that.
    public func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Returns the current screen-recording permission status.
    /// Does NOT prompt — safe to call at any time.
    public func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Returns true when both permissions are granted.
    public func allPermissionsGranted() -> Bool {
        accessibilityStatus() == .granted && screenRecordingStatus() == .granted
    }

    // MARK: Permission requests (only on explicit user action)

    /// Prompts the user for accessibility permission.
    /// Only call in response to a direct user action (button tap), not at startup.
    public func requestAccessibility() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    /// Requests screen-recording permission.
    /// Note: takes effect only after process restart.
    public func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Open System Settings

    public func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilityURL)
    }

    public func openScreenRecordingSettings() {
        NSWorkspace.shared.open(Self.screenRecordingURL)
    }

    // MARK: Restart (for screen-recording grant)

    /// Re-launches the app so screen-recording permission takes effect.
    /// Opens a new instance via /usr/bin/open, then terminates self.
    public func relaunchApp() {
        guard let bundlePath = Bundle.main.bundlePath
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return }

        let url = URL(string: "file://\(bundlePath)")!
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }

        // Give the new instance a moment to start, then exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
