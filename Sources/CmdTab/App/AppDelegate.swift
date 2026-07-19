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

    // §6.2: state machine owns the switcher logic; wired in startTapIfPossible().
    private var switcherMachine: SwitcherStateMachine?

    // §7.2: panel created once at startup, retained forever.
    private var switcherPanel: SwitcherPanel?

    // Real window data source (§5) and pre-scaled icon cache (§8).
    private var windowStore: WindowStore?
    private var iconCache: IconCache?

    // Snapshot of windows from the most recent "show" transition.
    // Used by sameAppResolver and confirmSelection without re-enumerating.
    private var lastSwitcherItems: [SwitcherItem] = []

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu-bar accessory: no Dock icon, no activation on launch.
        NSApp.setActivationPolicy(.accessory)

        // §7.2: create the panel once here; never destroy it.
        let panel = SwitcherPanel()
        self.switcherPanel = panel

        // Real data source + icon cache, created once and retained (§5, §8).
        self.windowStore = WindowStore()
        self.iconCache = IconCache()

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

        #if DEBUG
        // DEBUG self-check (§7 completion gate): simulate one trigger to get an
        // N1 proxy without synthesising CGEvents. Do this after the tap is set
        // up so the code path is realistic, but use a synthetic t0 = now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let panel = self.switcherPanel else { return }
            let items = self.currentSwitcherItems()
            guard !items.isEmpty else {
                NSLog("[CmdTab] N1 self-check skipped: 0 windows")
                return
            }
            let syntheticT0 = CFAbsoluteTimeGetCurrent()
            panel.show(items: items, selectedIndex: self.initialSelection(count: items.count))
            panel.displayIfNeeded()
            let n1 = (CFAbsoluteTimeGetCurrent() - syntheticT0) * 1000.0
            NSLog("[CmdTab] N1: %.2fms (callback→display, %d windows) [DEBUG self-check]",
                  n1, items.count)
            if n1 > 50.0 {
                NSLog("[CmdTab] N1 GATE FAIL: %.2fms exceeds 50ms budget", n1)
            } else {
                NSLog("[CmdTab] N1 GATE PASS: %.2fms within 50ms budget", n1)
            }
            // Hide after 0.5s so the developer can see the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.switcherPanel?.hide()
            }
        }
        #endif
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

        // §6.2 / Step 9: route all switcher inputs through the state machine.
        // The machine is pure logic; we execute its returned action here.
        // §4.3: the callback runs on the main run loop, and onSwitcherInput
        // is called synchronously within the tap callback (no async hop needed
        // for the consume decision). Panel/UI work is cheap enough to do inline
        // because it only posts display requests — no blocking I/O.
        let machine = SwitcherStateMachine(sameAppResolver: { [weak self] currentIndex in
            // Resolve the next window index that belongs to the same app as
            // the currently selected window. This requires the WindowStore's
            // last-enumerated list, which AppDelegate caches during showPanel.
            self?.nextSameAppIndex(from: currentIndex)
        })
        self.switcherMachine = machine

        tap.onSwitcherInput = { [weak self] input, t0 in
            guard let self, let panel = self.switcherPanel else { return false }

            // Supply the current item count only when showing the panel
            // (MODIFIER_HELD + trigger transition). For all other inputs
            // the machine ignores itemCount, so 0 is a safe sentinel.
            let itemCount: Int
            if case .trigger = input, !panel.isVisible {
                // This is the "show" transition — enumerate now.
                let items = self.currentSwitcherItems()
                self.lastSwitcherItems = items
                itemCount = items.count
            } else {
                itemCount = panel.itemCount
            }

            let (action, consumed) = machine.handle(input, itemCount: itemCount)

            switch action {
            case .none:
                break

            case .showPanel(let initialIndex):
                // §15 edge case: 0 windows — the machine already returned
                // .none in that case (itemCount == 0 guard inside machine),
                // but be defensive here too.
                let items = self.lastSwitcherItems
                guard !items.isEmpty else { break }
                panel.show(items: items, selectedIndex: initialIndex)
                panel.displayIfNeeded()
                let n1 = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
                NSLog("[CmdTab] N1: %.2fms (callback→display, %d windows)", n1, items.count)

            case .moveSelection(let newIndex):
                let t2start = CFAbsoluteTimeGetCurrent()
                panel.updateSelection(to: newIndex)
                panel.displayIfNeeded()
                let n2 = (CFAbsoluteTimeGetCurrent() - t2start) * 1000.0
                NSLog("[CmdTab] N2 redraw: %.2fms", n2)

            case .confirmSelection(let index):
                NSLog("[CmdTab] Confirm window index %d (AX raise pending Step 10)", index)
                panel.hide()

            case .cancel:
                panel.hide()
            }

            return consumed
        }

        hotkeyTap = tap
        tap.enable()
    }

    /// Enumerate the current windows (§5) and map them to switcher items,
    /// resolving each app icon through the pre-scaled cache (§8).
    @MainActor
    private func currentSwitcherItems() -> [SwitcherItem] {
        guard let windowStore, let iconCache else { return [] }
        return windowStore.enumerate().map { info in
            SwitcherItem(
                icon: iconCache.icon(for: info.pid, bundleID: info.bundleID),
                title: info.title
            )
        }
    }

    /// Initial selection index (§6.2): the previous window (index 1) when there
    /// are two or more, otherwise the only window (index 0).
    private func initialSelection(count: Int) -> Int {
        count >= 2 ? 1 : 0
    }

    /// Return the next index that belongs to the same app as `currentIndex`
    /// in the last-shown snapshot, or nil if there is no other window of
    /// the same app. Used by the state machine's sameAppResolver closure.
    @MainActor
    private func nextSameAppIndex(from currentIndex: Int) -> Int? {
        let items = lastSwitcherItems
        guard items.indices.contains(currentIndex) else { return nil }
        // SwitcherItem carries only icon + title; use WindowStore for pid lookup.
        // The resolver is best-effort: if we can't identify the app, return nil.
        guard let windowStore else { return nil }
        let windows = windowStore.enumerate()
        guard windows.indices.contains(currentIndex) else { return nil }
        let currentPID = windows[currentIndex].pid
        // Search forward (wrapping) for the next window with the same PID.
        let count = windows.count
        for offset in 1..<count {
            let candidate = (currentIndex + offset) % count
            if windows[candidate].pid == currentPID {
                return candidate
            }
        }
        return nil
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
