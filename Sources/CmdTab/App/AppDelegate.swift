import AppKit

// NSApplicationDelegate callbacks are called on the main thread by the
// framework. We annotate each method with @MainActor explicitly so Swift 6
// strict concurrency can verify this without requiring the class-level
// annotation (which would make the init @MainActor and break top-level code).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: OnboardingWindow?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar accessory: no Dock icon, no activation on launch.
        NSApp.setActivationPolicy(.accessory)

        let pm = PermissionManager()
        self.permissionManager = pm

        let sc = StatusItemController(permissionManager: pm)
        self.statusItemController = sc

        // Check permissions and show onboarding if any are missing.
        if !pm.allPermissionsGranted() {
            let ow = OnboardingWindow(permissionManager: pm)
            self.onboardingWindow = ow
            ow.show()
            NSLog("[CmdTab] Permissions missing — showing onboarding. " +
                  "Accessibility: %@  ScreenRecording: %@",
                  pm.accessibilityStatus() == .granted ? "granted" : "denied",
                  pm.screenRecordingStatus() == .granted ? "granted" : "denied")
        } else {
            NSLog("[CmdTab] All permissions granted — normal startup.")
        }
    }

    // Prevent AppKit from quitting the process when all windows close.
    // As a menu-bar accessory the app has no main window, so this callback
    // would otherwise trigger immediately and exit the process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        // Reserved for Step 5: disable event tap so modifier keys are not
        // left in a stuck state after the process exits.
    }
}
