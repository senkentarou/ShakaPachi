import AppKit

// NSApplicationDelegate callbacks are called on the main thread by the
// framework. We annotate each method with @MainActor explicitly so Swift 6
// strict concurrency can verify this without requiring the class-level
// annotation (which would make the init @MainActor and break top-level code).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: OnboardingWindow?
    private var hotkeyTap: HotkeyTap?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar accessory: no Dock icon, no activation on launch.
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        // N5 timing measurement: run enumerate() 10 times and log min/median/max.
        // This requires the app to be launched as a signed .app bundle so that
        // screen recording TCC permission is active and kCGWindowName is populated.
        measureWindowStoreN5()
        #endif

        let pm = PermissionManager()
        self.permissionManager = pm

        let sc = StatusItemController(permissionManager: pm)
        self.statusItemController = sc

        // Menu toggle drives the tap lifecycle (also the recovery path after
        // an emergency stop or deadman fire).
        sc.onToggleTap = { [weak self] enable in
            guard let tap = self?.hotkeyTap else { return }
            if enable {
                tap.enable()
            } else {
                tap.disable(reason: "メニューから無効化")
            }
        }

        // Check permissions and show onboarding if any are missing.
        if !pm.allPermissionsGranted() {
            let ow = OnboardingWindow(permissionManager: pm) { [weak self] in
                self?.statusItemController?.updatePermissionWarning()
                // Start the tap the moment both permissions turn granted.
                self?.startTapIfPossible()
            }
            self.onboardingWindow = ow
            ow.show()
            NSLog("[CmdTab] Permissions missing — showing onboarding. " +
                  "Accessibility: %@  ScreenRecording: %@",
                  pm.accessibilityStatus() == .granted ? "granted" : "denied",
                  pm.screenRecordingStatus() == .granted ? "granted" : "denied")
        } else {
            NSLog("[CmdTab] All permissions granted — normal startup.")
            startTapIfPossible()
        }
    }

    @MainActor
    private func startTapIfPossible() {
        guard hotkeyTap == nil,
              permissionManager?.allPermissionsGranted() == true else { return }
        let tap = HotkeyTap()
        tap.onStateChange = { [weak self] state in
            switch state {
            case .active:
                self?.statusItemController?.updateTapState(enabled: true, reason: nil)
            case .stopped(let reason):
                self?.statusItemController?.updateTapState(enabled: false, reason: reason)
            }
        }
        hotkeyTap = tap
        tap.enable()
    }

    // Prevent AppKit from quitting the process when all windows close.
    // As a menu-bar accessory the app has no main window, so this callback
    // would otherwise trigger immediately and exit the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // §4.6: tear the tap down so modifier keys are not left in a stuck
        // state after the process exits.
        hotkeyTap?.disable(reason: "アプリ終了")
    }

    #if DEBUG
    // Measure WindowStore.enumerate() 10 times and log each result plus
    // min/median/max so the N5 gate (≤5ms) can be verified from the system log.
    @MainActor
    private func measureWindowStoreN5() {
        let store = WindowStore()
        let runs = 10
        var durations: [Double] = []
        var windowCount = 0
        for i in 1...runs {
            let start = Date()
            let windows = store.enumerate()
            let elapsed = Date().timeIntervalSince(start) * 1000.0
            durations.append(elapsed)
            windowCount = windows.count
            NSLog("[CmdTab] N5 run %d: %.2fms  windows=%d", i, elapsed, windows.count)
        }
        let sorted = durations.sorted()
        let minMs = sorted.first ?? 0
        let maxMs = sorted.last ?? 0
        let medianMs: Double = {
            let mid = sorted.count / 2
            if sorted.count % 2 == 0 {
                return (sorted[mid - 1] + sorted[mid]) / 2.0
            }
            return sorted[mid]
        }()
        NSLog("[CmdTab] N5 summary: min=%.2fms median=%.2fms max=%.2fms windows=%d",
              minMs, medianMs, maxMs, windowCount)
        if medianMs > 5.0 {
            NSLog("[CmdTab] N5 GATE FAIL: median %.2fms exceeds 5ms budget", medianMs)
        } else {
            NSLog("[CmdTab] N5 GATE PASS: median %.2fms within 5ms budget", medianMs)
        }
    }
    #endif
}
